/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 自研必要性证明：官方 mac-capture 的回调与合成处于同一进程。ReplayKit 在
 * 独立扩展内运行。视频复用 IOSurface Mach 端口，PCM 复用 App Group 共享页。
 * 官方模块没有广播扩展的跨进程端口接收入口。 */

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <obs-ios.h>
#include <obs.h>
#include <util/platform.h>
#import <IOSurface/IOSurfaceRef.h>
#include "../BroadcastUploadExtension/BroadcastIPC.h"

void obs_app_privileged_screen_job(bool running);

static dispatch_queue_t inbox;
static dispatch_source_t listener, receiver, surface_receiver;
static int receiver_fd = -1;
static obs_ios_screen_frame_cb frame_callback;
static obs_ios_screen_audio_cb audio_callback;
static void *capture_context;

/* Keep the producer's surface out of its pool until the last CVPixelBuffer/GPU reference ends. */
@interface OBSSurfaceLease : NSObject {
@public
	IOSurfaceRef surface;
}
@end
@implementation OBSSurfaceLease
- (void)dealloc
{
	IOSurfaceDecrementUseCount(surface);
	CFRelease(surface);
}
@end

static void release_frame(struct BroadcastFrame *frame, size_t length)
{
	atomic_store_explicit(&frame->state, SlotFree, memory_order_release);
	munmap(frame, length);
}

static void release_bytes(void *context, const void *bytes)
{
	struct BroadcastFrame *frame = context;
	release_frame(frame, frame->capacity);
}

static void release_planes(void *context, const void *bytes, size_t length, size_t count, const void *planes[])
{
	release_bytes(context, bytes);
}

static void set_attachments(CVPixelBufferRef pixel, const struct BroadcastFrame *frame)
{
	if (frame->orientation >= 1 && frame->orientation <= 8)
		CVBufferSetAttachment(pixel, OBS_BROADCAST_ORIENTATION, (__bridge CFNumberRef)@(frame->orientation),
				      kCVAttachmentMode_ShouldPropagate);
	CFStringRef matrix = frame->matrix == Color601 ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 :
		frame->matrix == Color2020 ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2;
	if (frame->matrix)
		CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, matrix, kCVAttachmentMode_ShouldPropagate);
	CFStringRef primaries = frame->primaries == ColorP3 ? kCVImageBufferColorPrimaries_P3_D65 :
		frame->primaries == Color2020 ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2;
	if (frame->primaries)
		CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, primaries, kCVAttachmentMode_ShouldPropagate);
	CFStringRef transfer = frame->transfer == ColorPQ ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ :
		frame->transfer == ColorHLG ? kCVImageBufferTransferFunction_ITU_R_2100_HLG :
					    kCVImageBufferTransferFunction_ITU_R_709_2;
	if (frame->transfer)
		CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, transfer, kCVAttachmentMode_ShouldPropagate);
}

static CVPixelBufferRef make_pixel(struct BroadcastFrame *frame, uint8_t *bytes)
{
	const size_t width = frame->width, height = frame->height;
	if (!width || !height || width > 8192 || height > 8192)
		return NULL;
	CVPixelBufferRef pixel = NULL;
	if (frame->format == kCVPixelFormatType_32BGRA) {
		if (frame->stride[0] < width * 4 || frame->size[1] || frame->size[0] != frame->stride[0] * height)
			return NULL;
		CVPixelBufferCreateWithBytes(NULL, width, height, frame->format, bytes, frame->stride[0],
					     release_bytes, frame, NULL, &pixel);
	} else {
		const bool wide = frame->format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
				  frame->format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
		if (!wide && frame->format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
		    frame->format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
			return NULL;
		size_t widths[] = {width, (width + 1) / 2};
		size_t heights[] = {height, (height + 1) / 2};
		size_t strides[] = {frame->stride[0], frame->stride[1]};
		const size_t step = wide ? 2 : 1;
		if (strides[0] < widths[0] * step || strides[1] < widths[1] * step * 2 ||
		    frame->size[0] != strides[0] * heights[0] || frame->size[1] != strides[1] * heights[1])
			return NULL;
		void *planes[] = {bytes, bytes + frame->size[0]};
		CVPixelBufferCreateWithPlanarBytes(NULL, width, height, frame->format, bytes,
			(size_t)frame->size[0] + frame->size[1], 2, planes, widths, heights, strides,
			release_planes, frame, NULL, &pixel);
	}
	if (!pixel)
		return NULL;
	set_attachments(pixel, frame);
	return pixel;
}

static void read_surface(struct BroadcastSurfaceMessage *message)
{
	IOSurfaceRef surface = IOSurfaceLookupFromMachPort(message->surface.name);
	if (!surface)
		return;
	CVPixelBufferRef pixel = NULL;
	if (IOSurfaceGetWidth(surface) && IOSurfaceGetHeight(surface) &&
	    IOSurfaceGetWidth(surface) <= 8192 && IOSurfaceGetHeight(surface) <= 8192 &&
	    CVPixelBufferCreateWithIOSurface(NULL, surface, NULL, &pixel) == kCVReturnSuccess) {
		OBSSurfaceLease *lease = [OBSSurfaceLease new];
		lease->surface = (IOSurfaceRef)CFRetain(surface);
		IOSurfaceIncrementUseCount(surface);
		CVBufferSetAttachment(pixel, CFSTR("OBSSurfaceLease"), (__bridge CFTypeRef)lease, kCVAttachmentMode_ShouldNotPropagate);
		set_attachments(pixel, &message->frame);
		frame_callback(capture_context, pixel, message->frame.timestamp ?: os_gettime_ns());
		CVPixelBufferRelease(pixel);
	}
	CFRelease(surface);
}

static void receive_surfaces(mach_port_t port, bool discard)
{
	for (;;) {
		struct { struct BroadcastSurfaceMessage message; mach_msg_max_trailer_t trailer; } packet = {0};
		mach_msg_header_t *header = &packet.message.header;
		kern_return_t result = mach_msg(header, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
			0, sizeof(packet), port, 0, MACH_PORT_NULL);
		if (result == MACH_RCV_TOO_LARGE) {
			/* Without MACH_RCV_LARGE the kernel destroys the oversized message and its rights. */
			continue;
		}
		if (result != KERN_SUCCESS)
			return;
		if (!discard && receiver && frame_callback && header->msgh_id == OBS_BROADCAST_MACH_FRAME &&
		    header->msgh_size == sizeof(packet.message) && (header->msgh_bits & MACH_MSGH_BITS_COMPLEX) &&
		    packet.message.body.msgh_descriptor_count == 1 && packet.message.surface.type == MACH_MSG_PORT_DESCRIPTOR &&
		    packet.message.surface.disposition == MACH_MSG_TYPE_PORT_SEND && MACH_PORT_VALID(packet.message.surface.name)) {
			read_surface(&packet.message);
			mach_port_deallocate(mach_task_self(), packet.message.surface.name);
			packet.message.surface.name = MACH_PORT_NULL;
		}
		/* Rejected complex messages also relinquish all transferred rights. */
		mach_msg_destroy(header);
	}
}

static void start_surface_receiver(void)
{
	BroadcastBootstrapPort check_in = (BroadcastBootstrapPort)dlsym(RTLD_DEFAULT, "bootstrap_check_in");
	BroadcastBootstrapRegister register_port = (BroadcastBootstrapRegister)dlsym(RTLD_DEFAULT, "bootstrap_register");
	mach_port_t bootstrap = MACH_PORT_NULL, port = MACH_PORT_NULL;
	if (task_get_bootstrap_port(mach_task_self(), &bootstrap) != KERN_SUCCESS)
		return;
	kern_return_t result = check_in ? check_in(bootstrap, OBS_BROADCAST_MACH_SERVICE, &port) : KERN_FAILURE;
	if (result != KERN_SUCCESS && register_port &&
	    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) == KERN_SUCCESS) {
		result = mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
		if (result == KERN_SUCCESS) {
			result = register_port(bootstrap, OBS_BROADCAST_MACH_SERVICE, port);
			mach_port_deallocate(mach_task_self(), port);
		}
	}
	mach_port_deallocate(mach_task_self(), bootstrap);
	if (result != KERN_SUCCESS) {
		if (MACH_PORT_VALID(port))
			mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
		blog(LOG_INFO, "[iOS broadcast] Mach registration unavailable: %s", mach_error_string(result));
		return;
	}
	const mach_port_limits_t limits = {.mpl_qlimit = 1};
	mach_port_set_attributes(mach_task_self(), port, MACH_PORT_LIMITS_INFO,
		(mach_port_info_t)&limits, MACH_PORT_LIMITS_INFO_COUNT);
	surface_receiver = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, port, 0, inbox);
	dispatch_source_set_event_handler(surface_receiver, ^{ @autoreleasepool { receive_surfaces(port, false); } });
	dispatch_source_set_cancel_handler(surface_receiver, ^{
		mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
	});
	dispatch_activate(surface_receiver);
	blog(LOG_INFO, "[iOS broadcast] IOSurface Mach receiver ready");
}

static void output_audio(const struct BroadcastFrame *frame, uint8_t *bytes, uint64_t timestamp)
{
	if (!audio_callback || !frame->samples || !frame->channels || frame->channels > 2 ||
	    frame->rate < 8000 || frame->rate > 192000 || frame->format < PCMInt16 || frame->format > PCMFloat32)
		return;
	const bool planar = frame->size[1] != 0;
	const size_t length = (size_t)frame->samples * (frame->format == PCMInt16 ? 2 : 4);
	if (frame->size[0] != length * (planar ? 1 : frame->channels) ||
	    (planar && (frame->channels != 2 || frame->size[1] != length)))
		return;
	const enum audio_format interleaved[] = {AUDIO_FORMAT_16BIT, AUDIO_FORMAT_32BIT, AUDIO_FORMAT_FLOAT};
	const enum audio_format separate[] = {AUDIO_FORMAT_16BIT_PLANAR, AUDIO_FORMAT_32BIT_PLANAR,
					      AUDIO_FORMAT_FLOAT_PLANAR};
	const struct obs_source_audio audio = {
		.data = {bytes, planar ? bytes + frame->size[0] : NULL},
		.frames = frame->samples,
		.speakers = frame->channels == 1 ? SPEAKERS_MONO : SPEAKERS_STEREO,
		.format = planar ? separate[frame->format - 1] : interleaved[frame->format - 1],
		.samples_per_sec = frame->rate,
		.timestamp = timestamp,
	};
	audio_callback(capture_context, &audio);
}

static void read_frame(int fd, uint8_t type)
{
	const size_t page = getpagesize();
	struct stat status;
	struct BroadcastFrame *frame = MAP_FAILED;
	size_t length = 0;
	if (fstat(fd, &status) == 0 && S_ISREG(status.st_mode) && status.st_size >= (off_t)page &&
	    status.st_size <= (off_t)(page + BroadcastMaxBytes)) {
		length = (size_t)status.st_size;
		frame = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	}
	close(fd);
	if (frame == MAP_FAILED)
		return;
	if (atomic_load_explicit(&frame->state, memory_order_acquire) != SlotReady) {
		munmap(frame, length);
		return;
	}
	if (frame->capacity == length && (size_t)frame->size[0] + frame->size[1] <= length - page) {
		uint8_t *bytes = (uint8_t *)frame + page;
		uint64_t timestamp = frame->timestamp ?: os_gettime_ns();
		if (type == BroadcastVideo) {
			CVPixelBufferRef pixel = make_pixel(frame, bytes);
			if (pixel) {
				frame_callback(capture_context, pixel, timestamp);
				CVPixelBufferRelease(pixel);
				return;
			}
		} else if (type == BroadcastAudio) {
			output_audio(frame, bytes, timestamp);
		}
	}
	release_frame(frame, length);
}

static void stop_receiver(void)
{
	if (!receiver)
		return;
	dispatch_source_cancel(receiver);
	receiver = nil;
	receiver_fd = -1;
	if (surface_receiver)
		receive_surfaces((mach_port_t)dispatch_source_get_handle(surface_receiver), true);
	frame_callback(capture_context, NULL, 0);
	obs_app_privileged_screen_job(false);
}

static void receive(int fd)
{
	while (receiver_fd == fd) {
		uint8_t type;
		struct iovec bytes = {&type, sizeof(type)};
		union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(int))]; } control;
		struct msghdr message = {.msg_iov = &bytes, .msg_iovlen = 1, .msg_control = control.bytes,
					 .msg_controllen = sizeof(control.bytes)};
		const ssize_t count = recvmsg(fd, &message, MSG_DONTWAIT);
		if (count < 0 && errno == EINTR)
			continue;
		if (count != sizeof(type)) {
			if (count >= 0 || errno != EAGAIN)
				stop_receiver();
			return;
		}
		struct cmsghdr *header = CMSG_FIRSTHDR(&message);
		if (header && header->cmsg_type == SCM_RIGHTS && header->cmsg_level == SOL_SOCKET &&
		    header->cmsg_len == CMSG_LEN(sizeof(int))) {
			int slot;
			memcpy(&slot, CMSG_DATA(header), sizeof(slot));
			read_frame(slot, type);
		} else if (type == BroadcastPause) {
			if (surface_receiver)
				receive_surfaces((mach_port_t)dispatch_source_get_handle(surface_receiver), true);
			frame_callback(capture_context, NULL, 0);
		}
	}
}

static bool start_listener(void)
{
	struct sockaddr_un address = {0};
	if (!broadcast_address(&address))
		return false;
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return false;
	unlink(address.sun_path);
	if (fcntl(fd, F_SETFL, O_NONBLOCK) == -1 ||
	    bind(fd, (struct sockaddr *)&address, address.sun_len) != 0 || listen(fd, 1) != 0) {
		close(fd);
		return false;
	}
	listener = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, inbox);
	dispatch_source_set_cancel_handler(listener, ^{ close(fd); });
	dispatch_source_set_event_handler(listener, ^{
		int peer = accept(fd, NULL, NULL);
		if (peer < 0)
			return;
		if (receiver) {
			close(peer);
			return;
		}
		receiver_fd = peer;
		receiver = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, peer, 0, inbox);
		dispatch_source_set_cancel_handler(receiver, ^{ close(peer); });
		dispatch_source_set_event_handler(receiver, ^{ receive(peer); });
		dispatch_activate(receiver);
		obs_app_privileged_screen_job(true);
	});
	dispatch_activate(listener);
	return true;
}

bool obs_ios_replaykit_available(void)
{
	struct sockaddr_un address = {0};
	if (!broadcast_address(&address))
		return false;
	NSURL *extension = [NSBundle.mainBundle.builtInPlugInsURL URLByAppendingPathComponent:@"OBSBroadcast.appex"];
	return extension && [NSFileManager.defaultManager fileExistsAtPath:extension.path];
}

bool obs_ios_start_replaykit(obs_ios_screen_frame_cb frame, obs_ios_screen_audio_cb audio, void *context)
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{ inbox = dispatch_queue_create("org.obsproject.studio.ios.broadcast", DISPATCH_QUEUE_SERIAL); });
	__block bool started = false;
	dispatch_sync(inbox, ^{
		if (!listener && !start_listener())
			return;
		if (receiver && capture_context != context)
			return;
		if (frame_callback && capture_context != context)
			frame_callback(capture_context, NULL, 0);
		frame_callback = frame;
		audio_callback = audio;
		capture_context = context;
		if (!surface_receiver)
			start_surface_receiver();
		started = true;
	});
	return started;
}

void obs_ios_stop_replaykit(void *context)
{
	if (!inbox)
		return;
	dispatch_sync(inbox, ^{
		if (!listener || capture_context != context)
			return;
		stop_receiver();
		if (surface_receiver) {
			dispatch_source_cancel(surface_receiver);
			surface_receiver = nil;
		}
		dispatch_source_cancel(listener);
		listener = nil;
		frame_callback = NULL;
		audio_callback = NULL;
		capture_context = NULL;
		struct sockaddr_un address = {0};
		if (broadcast_address(&address))
			unlink(address.sun_path);
	});
}
