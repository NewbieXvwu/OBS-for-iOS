/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 自研必要性证明：OBS 桌面前端没有 iOS 沙盒能力入口；Android 宿主的权限、
 * 路径和任务接口依赖 Android。这里把 iOS 系统授权与原版模块加载和子进程接口相连。 */

#import <BackgroundTasks/BackgroundTasks.h>
#import <AVFAudio/AVFAudio.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdatomic.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <obs-ios.h>
#include <obs.h>
#include <obs-frontend-api.h>
#include <util/bmem.h>
#include <util/platform.h>

#if !TARGET_OS_SIMULATOR
bool obs_ios_screen_available(void);
bool obs_ios_start_authorized_screen(obs_ios_screen_frame_cb, void *);
void obs_ios_stop_authorized_screen(void *);
#endif
bool obs_ios_replaykit_available(void);
bool obs_ios_start_replaykit(obs_ios_screen_frame_cb, obs_ios_screen_audio_cb, void *);
void obs_ios_stop_replaykit(void *);

static _Atomic(uint32_t) capabilities;
static const char public_directory[] = "/var/mobile/Media/OBS";
static NSString *const plugins_directory = @"/var/jb/Library/OBS/Plugins";
static NSString *const gpu_entitlement = @"com.apple.developer.background-tasks.continued-processing.gpu";
static BGTask *background_task;
static NSString *background_identifier;
static bool background_task_registered;
static bool output_running, screen_running;
static AVAudioEngine *keepalive_audio;
static AVAudioSourceNode *silence;
static id process_assertion;
static _Atomic(bool) assertion_active;
static uint64_t assertion_generation;
extern char **environ;

/* ABI from Apple's WebKit AssertionServicesSPI.h; resolve the class at runtime only. */
@protocol OBSProcessAssertion <NSObject>
- (instancetype)initWithPID:(pid_t)pid flags:(uint32_t)flags reason:(uint32_t)reason
	name:(NSString *)name withHandler:(void (^)(BOOL))handler;
- (void)setInvalidationHandler:(void (^)(void))handler;
- (void)invalidate;
@end

static Class assertion_class(void)
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		dlopen("/System/Library/PrivateFrameworks/AssertionServices.framework/AssertionServices", RTLD_LAZY | RTLD_LOCAL);
	});
	Class cls = NSClassFromString(@"BKSProcessAssertion");
	return [cls instancesRespondToSelector:@selector(initWithPID:flags:reason:name:withHandler:)] &&
	       [cls instancesRespondToSelector:@selector(invalidate)] &&
	       [cls instancesRespondToSelector:@selector(setInvalidationHandler:)] ? cls : Nil;
}

static bool has_entitlement(NSString *name)
{
	typedef CFTypeRef (*TaskCreate)(CFAllocatorRef);
	typedef CFTypeRef (*TaskEntitlement)(CFTypeRef, CFStringRef, CFErrorRef *);
	TaskCreate create = (TaskCreate)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
	TaskEntitlement read = (TaskEntitlement)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
	if (!create || !read)
		return false;
	CFTypeRef task = create(kCFAllocatorDefault);
	if (!task)
		return false;
	CFTypeRef value = read(task, (__bridge CFStringRef)name, NULL);
	bool granted = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
	if (value)
		CFRelease(value);
	CFRelease(task);
	return granted;
}

static uint32_t get_capabilities(void)
{
	return atomic_load_explicit(&capabilities, memory_order_relaxed);
}

static bool start_screen_capture(obs_ios_screen_frame_cb frame, obs_ios_screen_audio_cb audio, void *context)
{
	if (get_capabilities() & OBS_IOS_CAP_REPLAYKIT)
		return obs_ios_start_replaykit(frame, audio, context);
#if TARGET_OS_SIMULATOR
	return false;
#else
	return obs_ios_start_authorized_screen(frame, context);
#endif
}

static void stop_screen_capture(void *context)
{
	if (get_capabilities() & OBS_IOS_CAP_REPLAYKIT)
		obs_ios_stop_replaykit(context);
#if !TARGET_OS_SIMULATOR
	else
		obs_ios_stop_authorized_screen(context);
#endif
}

static const char *recording_directory(void)
{
	return get_capabilities() & OBS_IOS_CAP_PUBLIC_STORAGE ? public_directory : NULL;
}

static void load_plugins(void)
{
	if (!(get_capabilities() & OBS_IOS_CAP_DYNAMIC_PLUGIN))
		return;
	NSString *custom = [NSUserDefaults.standardUserDefaults stringForKey:@"OBS.PluginDirectory"];
	NSSet<NSString *> *directories = custom.length ? [NSSet setWithArray:@[plugins_directory, custom]] :
						       [NSSet setWithObject:plugins_directory];
	for (NSString *directory in directories) {
		NSArray<NSURL *> *entries = [NSFileManager.defaultManager
			contentsOfDirectoryAtURL:[NSURL fileURLWithPath:directory isDirectory:YES]
			includingPropertiesForKeys:@[NSURLIsRegularFileKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL];
		for (NSURL *file in entries) {
			if (![file.pathExtension isEqualToString:@"dylib"])
				continue;
			NSNumber *regular = nil;
			[file getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL];
			NSString *name = file.URLByDeletingPathExtension.lastPathComponent;
			if (!regular.boolValue || obs_get_module(name.UTF8String))
				continue;
			NSURL *data = [file.URLByDeletingLastPathComponent URLByAppendingPathComponent:name isDirectory:YES];
			obs_module_t *module = NULL;
			const int result = obs_open_module(&module, file.fileSystemRepresentation, data.fileSystemRepresentation);
			if (result == MODULE_SUCCESS)
				obs_init_module(module);
			else
				blog(LOG_WARNING, "[iOS host] %s: %d", file.lastPathComponent.UTF8String, result);
		}
	}
}

static void probe_muxer(void)
{
	char *path = os_get_executable_path_ptr("obs-ffmpeg-mux");
	if (!path || access(path, X_OK) != 0) {
		bfree(path);
		return;
	}
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		char *arguments[] = {path, "--ios-probe", NULL};
		pid_t pid;
		if (posix_spawn(&pid, path, NULL, NULL, arguments, environ) == 0) {
			int status = 0;
			pid_t waited;
			do {
				waited = waitpid(pid, &status, 0);
			} while (waited < 0 && errno == EINTR);
			if (waited == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0)
				atomic_fetch_or_explicit(&capabilities, OBS_IOS_CAP_SPAWN_MUXER, memory_order_relaxed);
		}
		bfree(path);
	});
}

static bool keepalive(bool enabled)
{
	return enabled && (output_running || screen_running) &&
		(background_task != nil || atomic_load_explicit(&assertion_active, memory_order_relaxed));
}

static void suspend_if_needed(void)
{
	if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive && !keepalive(true))
		obs_ios_set_video_suspended(true);
}

static void start_keepalive_audio(void)
{
	AVAudioSession *session = AVAudioSession.sharedInstance;
	NSError *error = nil;
	/* The microphone owns PlayAndRecord. Preserve that category and its input route. */
	if ((![session.category isEqualToString:AVAudioSessionCategoryPlayAndRecord] &&
	     ![session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error]) ||
	    ![session setActive:YES error:&error]) {
		blog(LOG_WARNING, "[iOS host] Background audio: %s", error.localizedDescription.UTF8String);
		return;
	}
	if (!keepalive_audio) {
		keepalive_audio = [AVAudioEngine new];
		AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1];
		silence = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:
			^OSStatus(BOOL *is_silence, const AudioTimeStamp *time, AVAudioFrameCount frames, AudioBufferList *buffers) {
				*is_silence = YES;
				for (UInt32 i = 0; i < buffers->mNumberBuffers; i++)
					memset(buffers->mBuffers[i].mData, 0, buffers->mBuffers[i].mDataByteSize);
				return noErr;
			}];
		[keepalive_audio attachNode:silence];
		[keepalive_audio connect:silence to:keepalive_audio.mainMixerNode format:format];
	}
	if (!keepalive_audio.running && ![keepalive_audio startAndReturnError:&error])
		blog(LOG_WARNING, "[iOS host] Background audio: %s", error.localizedDescription.UTF8String);
}

static void update_process_keepalive(void)
{
	if (!(output_running || screen_running)) {
		assertion_generation++;
		atomic_store_explicit(&assertion_active, false, memory_order_relaxed);
		if (process_assertion)
			blog(LOG_INFO, "[iOS host] Process assertion released");
		[(id<OBSProcessAssertion>)process_assertion invalidate];
		process_assertion = nil;
		[keepalive_audio stop];
		keepalive_audio = nil;
		silence = nil;
		/* AVAudioSession is shared with microphone capture and monitoring; stopping this engine ends our audio activity. */
		suspend_if_needed();
		return;
	}
	start_keepalive_audio();
	if (process_assertion || !has_entitlement(@"com.apple.multitasking.systemappassertions"))
		return;
	Class cls = assertion_class();
	if (!cls)
		return;
	const uint64_t generation = ++assertion_generation;
	/* PreventTaskSuspend | PreventTaskThrottleDown | AllowIdleSleep, FinishTaskUnbounded. */
	process_assertion = [(id<OBSProcessAssertion>)[cls alloc] initWithPID:getpid() flags:7 reason:10004
		name:@"OBS capture and output" withHandler:^(BOOL acquired) {
			dispatch_async(dispatch_get_main_queue(), ^{
				if (generation != assertion_generation)
					return;
				atomic_store_explicit(&assertion_active, acquired, memory_order_relaxed);
				blog(LOG_INFO, "[iOS host] Process assertion %s", acquired ? "acquired" : "denied");
				if (acquired)
					obs_ios_set_video_suspended(false);
				else
					suspend_if_needed();
			});
		}];
	[(id<OBSProcessAssertion>)process_assertion setInvalidationHandler:^{
		dispatch_async(dispatch_get_main_queue(), ^{
			if (generation != assertion_generation)
				return;
			atomic_store_explicit(&assertion_active, false, memory_order_relaxed);
			process_assertion = nil;
			suspend_if_needed();
		});
	}];
}

void obs_app_privileged_screen_job(bool running)
{
	dispatch_async(dispatch_get_main_queue(), ^{
		screen_running = running;
		update_process_keepalive();
	});
}

static void finish_background_task(BGTask *task, bool success)
{
	if (!task || task != background_task)
		return;
	background_task = nil;
	background_identifier = nil;
	[task setTaskCompletedWithSuccess:success];
	suspend_if_needed();
}

static bool register_background_task(void)
{
	if (@available(iOS 26.0, *)) {
		if (!has_entitlement(gpu_entitlement) ||
		    !NSClassFromString(@"BGContinuedProcessingTaskRequest") ||
		    !(BGTaskScheduler.supportedResources & BGContinuedProcessingTaskRequestResourcesGPU))
			return false;
		NSString *identifier = [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".rendering.*"];
		return [BGTaskScheduler.sharedScheduler registerForTaskWithIdentifier:identifier
			usingQueue:dispatch_get_main_queue() launchHandler:^(BGTask *task) {
				if (background_task || ![task.identifier isEqualToString:background_identifier]) {
					[task setTaskCompletedWithSuccess:NO];
					return;
				}
				background_task = task;
				BGContinuedProcessingTask *rendering = (BGContinuedProcessingTask *)task;
				rendering.progress.totalUnitCount = -1;
				__weak BGTask *expired_task = task;
				task.expirationHandler = ^{
					dispatch_async(dispatch_get_main_queue(), ^{
						finish_background_task(expired_task, false);
					});
				};
				if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
					obs_ios_set_video_suspended(false);
			}];
	}
	return false;
}

void obs_app_privileged_background_job(bool running)
{
	output_running = running;
	update_process_keepalive();
	if (!background_task_registered)
		return;
	if (@available(iOS 26.0, *)) {
		BGTaskScheduler *scheduler = BGTaskScheduler.sharedScheduler;
		if (!running) {
			if (background_task) {
				finish_background_task(background_task, true);
			} else if (background_identifier) {
				[scheduler cancelTaskRequestWithIdentifier:background_identifier];
				background_identifier = nil;
			}
			return;
		}
		if (background_identifier || UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
			return;
		NSString *title = @(obs_frontend_get_locale_string(obs_frontend_streaming_active() ? "Basic.Main.StartStreaming" :
			obs_frontend_recording_active() ? "Basic.Main.StartRecording" : "Basic.Main.StartReplayBuffer"));
		NSString *identifier = [NSString stringWithFormat:@"%@.rendering.%@", NSBundle.mainBundle.bundleIdentifier,
					NSUUID.UUID.UUIDString];
		BGContinuedProcessingTaskRequest *request = [[BGContinuedProcessingTaskRequest alloc]
			initWithIdentifier:identifier title:title subtitle:@"OBS Studio"];
		request.strategy = BGContinuedProcessingTaskRequestSubmissionStrategyFail;
		request.requiredResources = BGContinuedProcessingTaskRequestResourcesGPU;
		NSError *error = nil;
		background_identifier = identifier;
		if (![scheduler submitTaskRequest:request error:&error]) {
			background_identifier = nil;
			blog(LOG_INFO, "[iOS host] %s", error.localizedDescription.UTF8String ?: "Background GPU unavailable");
		}
	}
}

static void output_event(enum obs_frontend_event event, void *context)
{
	switch (event) {
	case OBS_FRONTEND_EVENT_STREAMING_STARTED:
	case OBS_FRONTEND_EVENT_STREAMING_STOPPED:
	case OBS_FRONTEND_EVENT_RECORDING_STARTED:
	case OBS_FRONTEND_EVENT_RECORDING_STOPPED:
	case OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED:
	case OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED:
	case OBS_FRONTEND_EVENT_EXIT:
		dispatch_async(dispatch_get_main_queue(), ^{
			obs_app_privileged_background_job(event != OBS_FRONTEND_EVENT_EXIT &&
				(obs_frontend_streaming_active() || obs_frontend_recording_active() || obs_frontend_replay_buffer_active()));
		});
		break;
	default:
		break;
	}
}

void obs_app_privileged_frontend_ready(void)
{
	obs_frontend_add_event_callback(output_event, NULL);
	NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
	[center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
		usingBlock:^(NSNotification *notification) {
			obs_app_privileged_background_job(output_running);
		}];
	[center addObserverForName:AVAudioEngineConfigurationChangeNotification object:nil queue:NSOperationQueue.mainQueue
		usingBlock:^(NSNotification *notification) {
			if (notification.object == keepalive_audio && (output_running || screen_running))
				start_keepalive_audio();
		}];
	[center addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:NSOperationQueue.mainQueue
		usingBlock:^(NSNotification *notification) {
			if ([notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan)
				[keepalive_audio stop];
			else if (output_running || screen_running)
				start_keepalive_audio();
		}];
}

void obs_app_install_privileged_host(void)
{
	uint32_t detected = 0;
	if (access("/var/jb", F_OK) == 0 || has_entitlement(@"com.apple.private.cs.disable-library-validation"))
		detected |= OBS_IOS_CAP_DYNAMIC_PLUGIN;
	if (os_mkdirs(public_directory) >= 0 && access(public_directory, W_OK) == 0)
		detected |= OBS_IOS_CAP_PUBLIC_STORAGE;
	background_task_registered = register_background_task();
	if (background_task_registered ||
	    (has_entitlement(@"com.apple.multitasking.systemappassertions") && has_entitlement(gpu_entitlement) && assertion_class()))
		detected |= OBS_IOS_CAP_BACKGROUND_GPU;
	if (obs_ios_replaykit_available())
		detected |= OBS_IOS_CAP_PRIVATE_SCREEN | OBS_IOS_CAP_REPLAYKIT;
#if !TARGET_OS_SIMULATOR
	else if (obs_ios_screen_available())
		detected |= OBS_IOS_CAP_PRIVATE_SCREEN;
#endif
	atomic_store_explicit(&capabilities, detected, memory_order_relaxed);
	const struct obs_ios_host host = {
		.get_capabilities = get_capabilities,
		.set_keepalive = keepalive,
		.start_screen_capture = start_screen_capture,
		.stop_screen_capture = stop_screen_capture,
		.get_recording_dir = recording_directory,
		.load_extra_plugins = load_plugins,
	};
	obs_ios_set_host(&host);
	probe_muxer();
}
