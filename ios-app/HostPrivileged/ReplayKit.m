/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 自研必要性证明：官方 mac-capture 的回调与合成处于同一进程。ReplayKit 在
 * 独立扩展内运行。这里使用 App Group 共享页和 CoreVideo 释放回调接入 libobs。 */

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <obs-ios.h>
#include <obs.h>
#include <util/platform.h>
#include "../BroadcastUploadExtension/BroadcastIPC.h"

static dispatch_queue_t inbox;
static dispatch_source_t listener, receiver;
static int receiver_fd = -1;
static obs_ios_screen_frame_cb frame_callback;
static obs_ios_screen_audio_cb audio_callback;
static void *capture_context;

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
	return pixel;
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
	frame_callback(capture_context, NULL, 0);
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
