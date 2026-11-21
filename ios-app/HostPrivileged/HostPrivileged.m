/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 自研必要性证明：OBS 桌面前端没有 iOS 沙盒能力入口；Android 宿主的权限、
 * 路径和任务接口依赖 Android。这里把 iOS 系统授权与原版模块加载和子进程接口相连。 */

#import <BackgroundTasks/BackgroundTasks.h>
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

bool obs_ios_screen_available(void);
bool obs_ios_start_authorized_screen(obs_ios_screen_frame_cb, void *);
void obs_ios_stop_authorized_screen(void *);

static _Atomic(uint32_t) capabilities;
static const char public_directory[] = "/var/mobile/Media/OBS";
static NSString *const plugins_directory = @"/var/jb/Library/OBS/Plugins";
static NSString *const gpu_entitlement = @"com.apple.developer.background-tasks.continued-processing.gpu";
static BGTask *background_task;
static NSString *background_identifier;
extern char **environ;

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
	return enabled && background_task != nil;
}

static void finish_background_task(BGTask *task, bool success)
{
	if (!task || task != background_task)
		return;
	if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
		obs_ios_set_video_suspended(true);
	background_task = nil;
	background_identifier = nil;
	[task setTaskCompletedWithSuccess:success];
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
	if (!(get_capabilities() & OBS_IOS_CAP_BACKGROUND_GPU))
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

void obs_app_install_privileged_host(void)
{
	uint32_t detected = 0;
	if (access("/var/jb", F_OK) == 0 || has_entitlement(@"com.apple.private.cs.disable-library-validation"))
		detected |= OBS_IOS_CAP_DYNAMIC_PLUGIN;
	if (os_mkdirs(public_directory) >= 0 && access(public_directory, W_OK) == 0)
		detected |= OBS_IOS_CAP_PUBLIC_STORAGE;
	if (register_background_task())
		detected |= OBS_IOS_CAP_BACKGROUND_GPU;
	if (obs_ios_screen_available())
		detected |= OBS_IOS_CAP_PRIVATE_SCREEN;
	atomic_store_explicit(&capabilities, detected, memory_order_relaxed);
	const struct obs_ios_host host = {
		.get_capabilities = get_capabilities,
		.set_keepalive = keepalive,
		.start_screen_capture = obs_ios_start_authorized_screen,
		.stop_screen_capture = obs_ios_stop_authorized_screen,
		.get_recording_dir = recording_directory,
		.load_extra_plugins = load_plugins,
	};
	obs_ios_set_host(&host);
	probe_muxer();
}
