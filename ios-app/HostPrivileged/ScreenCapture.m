/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 自研必要性证明：OBS 的 macOS ScreenCaptureKit 源依赖桌面显示器枚举和
 * 过滤器构造器，iOS SDK 只通过系统选择器取得授权的内容过滤器。这里适配
 * 该选择器和异步回调，将原有 CVPixelBuffer 原样交给 libobs 宿主总线。 */

#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <obs-ios.h>
#include <util/platform.h>

API_AVAILABLE(ios(27.0))
@interface OBSAuthorizedScreen : NSObject <SCContentSharingPickerObserver, SCStreamDelegate, SCStreamOutput> {
@public
	obs_ios_screen_frame_cb callback;
	void *context;
}
@property(nonatomic, strong) SCStream *stream;
@property(nonatomic, strong) dispatch_queue_t frames;
- (void)present;
- (void)end;
@end

static NSObject *screen_lock;
static id active_screen;

API_AVAILABLE(ios(27.0))
static void stop_screen(OBSAuthorizedScreen *capture)
{
	@synchronized (screen_lock) {
		if (!capture || active_screen != capture)
			return;
		if (capture->callback)
			capture->callback(capture->context, NULL, 0);
		capture->callback = NULL;
		active_screen = nil;
		dispatch_async(dispatch_get_main_queue(), ^{ [capture end]; });
	}
}

API_AVAILABLE(ios(27.0))
@implementation OBSAuthorizedScreen
- (void)present
{
	@synchronized (screen_lock) {
		if (active_screen != self)
			return;
	}
	SCContentSharingPicker *picker = SCContentSharingPicker.sharedPicker;
	[picker addObserver:self];
	picker.active = YES;
	[picker present];
}

- (void)end
{
	[SCContentSharingPicker.sharedPicker removeObserver:self];
	SCContentSharingPicker.sharedPicker.active = NO;
	SCStream *stream;
	@synchronized (screen_lock) {
		stream = _stream;
		_stream = nil;
	}
	[stream stopCaptureWithCompletionHandler:nil];
}

- (void)contentSharingPicker:(SCContentSharingPicker *)picker didCancelForStream:(SCStream *)stream
{
	stop_screen(self);
}

- (void)contentSharingPickerStartDidFailWithError:(NSError *)error
{
	blog(LOG_WARNING, "[ios-screen] %s", error.localizedDescription.UTF8String);
	stop_screen(self);
}

- (void)contentSharingPicker:(SCContentSharingPicker *)picker
	didUpdateWithFilter:(SCContentFilter *)filter forStream:(SCStream *)updated
{
	dispatch_async(dispatch_get_main_queue(), ^{
		SCStreamConfiguration *configuration = [SCStreamConfiguration new];
		SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:self];
		SCStream *previous;
		@synchronized (screen_lock) {
			if (active_screen != self)
				return;
			previous = self.stream;
			self.stream = stream;
		}
		[previous stopCaptureWithCompletionHandler:nil];
		NSError *error = nil;
		if (![stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.frames error:&error]) {
			[self stream:stream didStopWithError:error];
			return;
		}
		[stream startCaptureWithCompletionHandler:^(NSError *startError) {
			if (startError)
				[self stream:stream didStopWithError:startError];
		}];
	});
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error
{
	@synchronized (screen_lock) {
		if (active_screen != self || stream != _stream)
			return;
		if (error)
			blog(LOG_WARNING, "[ios-screen] %s", error.localizedDescription.UTF8String);
		stop_screen(self);
	}
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample
	ofType:(SCStreamOutputType)type
{
	if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample) || !CMSampleBufferDataIsReady(sample))
		return;
	CVPixelBufferRef frame = CMSampleBufferGetImageBuffer(sample);
	if (!frame)
		return;
	CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sample);
	uint64_t nanos = CMTIME_IS_NUMERIC(timestamp) && timestamp.value >= 0
		? (uint64_t)CMTimeConvertScale(timestamp, 1000000000, kCMTimeRoundingMethod_Default).value
		: os_gettime_ns();
	@synchronized (screen_lock) {
		if (active_screen == self && stream == _stream && callback)
			callback(context, frame, nanos);
	}
}
@end

bool obs_ios_screen_available(void)
{
	if (@available(iOS 27.0, *)) {
		if (NSClassFromString(@"SCContentSharingPicker") && NSClassFromString(@"SCStream")) {
			screen_lock = [NSObject new];
			return SCContentSharingPicker.sharedPicker.available;
		}
	}
	return false;
}

bool obs_ios_start_authorized_screen(obs_ios_screen_frame_cb callback, void *context)
{
	if (@available(iOS 27.0, *)) {
		if (!screen_lock || !callback)
			return false;
		OBSAuthorizedScreen *capture = [OBSAuthorizedScreen new];
		@synchronized (screen_lock) {
			if (active_screen)
				return false;
			capture->callback = callback;
			capture->context = context;
			capture.frames = dispatch_queue_create("org.obsproject.ios.screen.frames", DISPATCH_QUEUE_SERIAL);
			active_screen = capture;
			dispatch_async(dispatch_get_main_queue(), ^{ [capture present]; });
		}
		return true;
	}
	return false;
}

void obs_ios_stop_authorized_screen(void *context)
{
	if (@available(iOS 27.0, *)) {
		@synchronized (screen_lock) {
			OBSAuthorizedScreen *capture = active_screen;
			if (capture && capture->context == context)
				stop_screen(capture);
		}
	}
}
