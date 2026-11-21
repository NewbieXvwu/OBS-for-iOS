/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 自研必要性证明：官方 mac-capture 消费进程内的 ScreenCaptureKit 帧，无法作为
 * ReplayKit 广播扩展。XPC 的命名监听器要求系统注册服务，ReplayKit 不向宿主
 * 提供扩展连接。这里复用 ReplayKit、CoreMedia 和 App Group 的 Unix 套接字。 */

#import <ReplayKit/ReplayKit.h>
#include <AudioToolbox/AudioToolbox.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include "BroadcastIPC.h"

struct Slot {
	int fd;
	size_t capacity;
	struct BroadcastFrame *frame;
};

@interface OBSSampleHandler : RPBroadcastSampleHandler {
	int connection;
	struct Slot video[2], audio[4];
}
@end

static bool send_slot(int socket_fd, uint8_t type, const struct Slot *slot)
{
	struct iovec bytes = {&type, sizeof(type)};
	union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(int))]; } control = {0};
	struct msghdr message = {.msg_iov = &bytes, .msg_iovlen = 1};
	if (slot) {
		message.msg_control = control.bytes;
		message.msg_controllen = sizeof(control.bytes);
		struct cmsghdr *header = CMSG_FIRSTHDR(&message);
		header->cmsg_len = CMSG_LEN(sizeof(slot->fd));
		header->cmsg_level = SOL_SOCKET;
		header->cmsg_type = SCM_RIGHTS;
		memcpy(CMSG_DATA(header), &slot->fd, sizeof(slot->fd));
	}
	return sendmsg(socket_fd, &message, MSG_DONTWAIT) == sizeof(type);
}

static bool open_slot(struct Slot *slot)
{
	NSURL *url = [broadcast_container() URLByAppendingPathComponent:@"frame.XXXXXXXX"];
	char path[PATH_MAX];
	if (!url || ![url getFileSystemRepresentation:path maxLength:sizeof(path)])
		return false;
	int fd = mkstemp(path);
	if (fd < 0)
		return false;
	unlink(path);
	size_t page = getpagesize();
	if (ftruncate(fd, (off_t)page) == 0) {
		void *map = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
		if (map != MAP_FAILED) {
			slot->fd = fd;
			slot->frame = map;
			slot->capacity = page;
			atomic_init(&slot->frame->state, SlotFree);
			return true;
		}
	}
	close(fd);
	return false;
}

static struct Slot *free_slot(struct Slot *slots, size_t count)
{
	for (size_t i = 0; i < count; i++) {
		if (!slots[i].frame && !open_slot(&slots[i]))
			return NULL;
		if (atomic_load_explicit(&slots[i].frame->state, memory_order_acquire) == SlotFree)
			return &slots[i];
	}
	return NULL;
}

static void close_slots(struct Slot *slots, size_t count)
{
	for (size_t i = 0; i < count; i++) {
		if (!slots[i].frame)
			continue;
		munmap(slots[i].frame, getpagesize());
		close(slots[i].fd);
		slots[i] = (struct Slot){0};
	}
}

static bool write_slot(struct Slot *slot, const void *first, size_t first_size, const void *second, size_t second_size)
{
	if (first_size > BroadcastMaxBytes || second_size > BroadcastMaxBytes - first_size)
		return false;
	const size_t offset = getpagesize();
	const size_t length = offset + first_size + second_size;
	if (length > slot->capacity) {
		if (ftruncate(slot->fd, (off_t)length) != 0)
			return false;
		slot->capacity = length;
	}
	slot->frame->capacity = (uint32_t)slot->capacity;
	// ponytail: copy ReplayKit's borrowed planes into file-backed pages; the receiver maps these pages directly.
	return pwrite(slot->fd, first, first_size, offset) == (ssize_t)first_size &&
	       (!second_size || pwrite(slot->fd, second, second_size, offset + first_size) == (ssize_t)second_size);
}

static uint32_t color(CVPixelBufferRef pixel, CFStringRef key)
{
	NSString *value = CFBridgingRelease(CVBufferCopyAttachment(pixel, key, NULL));
	CFStringRef values[] = {kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVImageBufferColorPrimaries_ITU_R_709_2,
		kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferColorPrimaries_P3_D65,
		kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, kCVImageBufferTransferFunction_ITU_R_2100_HLG};
	for (uint32_t i = 0; i < sizeof(values) / sizeof(*values); i++)
		if ([value isEqualToString:(__bridge NSString *)values[i]])
			return i + 1;
	return 0;
}

static bool copy_video(struct Slot *slot, CMSampleBufferRef sample)
{
	CVPixelBufferRef pixel = CMSampleBufferGetImageBuffer(sample);
	if (!pixel)
		return false;
	const OSType format = CVPixelBufferGetPixelFormatType(pixel);
	const bool packed = format == kCVPixelFormatType_32BGRA;
	if (!packed && format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
	    format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
	    format != kCVPixelFormatType_420YpCbCr10BiPlanarFullRange &&
	    format != kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
		return false;
	if (CVPixelBufferLockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
		return false;
	const size_t stride = packed ? CVPixelBufferGetBytesPerRow(pixel) : CVPixelBufferGetBytesPerRowOfPlane(pixel, 0);
	const size_t height = CVPixelBufferGetHeight(pixel);
	const void *base = packed ? CVPixelBufferGetBaseAddress(pixel) : CVPixelBufferGetBaseAddressOfPlane(pixel, 0);
	const size_t stride_uv = packed ? 0 : CVPixelBufferGetBytesPerRowOfPlane(pixel, 1);
	const size_t uv_bytes = packed ? 0 : stride_uv * CVPixelBufferGetHeightOfPlane(pixel, 1);
	const void *uv = packed ? NULL : CVPixelBufferGetBaseAddressOfPlane(pixel, 1);
	bool written = base && (packed || uv) && write_slot(slot, base, stride * height, uv, uv_bytes);
	CVPixelBufferUnlockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly);
	if (!written)
		return false;
	struct BroadcastFrame *frame = slot->frame;
	frame->format = format;
	frame->width = (uint32_t)CVPixelBufferGetWidth(pixel);
	frame->height = (uint32_t)height;
	frame->stride[0] = (uint32_t)stride;
	frame->stride[1] = (uint32_t)stride_uv;
	frame->size[0] = (uint32_t)(stride * height);
	frame->size[1] = (uint32_t)uv_bytes;
	NSNumber *orientation = (__bridge id)CMGetAttachment(sample, (__bridge CFStringRef)RPVideoSampleOrientationKey, NULL);
	frame->orientation = orientation.intValue;
	frame->matrix = color(pixel, kCVImageBufferYCbCrMatrixKey);
	frame->primaries = color(pixel, kCVImageBufferColorPrimariesKey);
	frame->transfer = color(pixel, kCVImageBufferTransferFunctionKey);
	return true;
}

static bool copy_audio(struct Slot *slot, CMSampleBufferRef sample)
{
	const AudioStreamBasicDescription *format =
		CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample));
	if (!format || format->mFormatID != kAudioFormatLinearPCM || format->mChannelsPerFrame < 1 ||
	    format->mChannelsPerFrame > 2 || !(format->mFormatFlags & kAudioFormatFlagIsPacked) ||
	    (format->mFormatFlags & kAudioFormatFlagIsBigEndian))
		return false;
	const bool floating = format->mFormatFlags & kAudioFormatFlagIsFloat;
	const bool integer = format->mFormatFlags & kAudioFormatFlagIsSignedInteger;
	const uint32_t bits = format->mBitsPerChannel;
	if ((!floating || bits != 32) && (!integer || (bits != 16 && bits != 32)))
		return false;
	struct { AudioBufferList list; AudioBuffer extra; } buffers;
	const uint32_t channels = format->mChannelsPerFrame;
	const bool planar = channels == 2 && (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved);
	const size_t list_size = sizeof(AudioBufferList) + (planar ? sizeof(AudioBuffer) : 0);
	CMBlockBufferRef block = NULL;
	if (CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, NULL, &buffers.list, list_size,
								   NULL, NULL, 0, &block) != noErr)
		return false;
	const AudioBuffer *planes = buffers.list.mBuffers;
	const uint32_t samples = (uint32_t)CMSampleBufferGetNumSamples(sample);
	const size_t bytes = (size_t)samples * (bits / 8) * (planar ? 1 : channels);
	bool written = samples && planes[0].mData && planes[0].mDataByteSize >= bytes &&
		       (!planar || (planes[1].mData && planes[1].mDataByteSize >= bytes)) &&
		       write_slot(slot, planes[0].mData, bytes, planar ? planes[1].mData : NULL, planar ? bytes : 0);
	if (block)
		CFRelease(block);
	if (!written)
		return false;
	struct BroadcastFrame *frame = slot->frame;
	frame->format = floating ? PCMFloat32 : bits == 16 ? PCMInt16 : PCMInt32;
	frame->rate = (uint32_t)format->mSampleRate;
	frame->channels = channels;
	frame->samples = samples;
	frame->size[0] = (uint32_t)bytes;
	frame->size[1] = planar ? (uint32_t)bytes : 0;
	return true;
}

@implementation OBSSampleHandler
- (instancetype)init
{
	self = [super init];
	if (self)
		connection = -1;
	return self;
}

- (void)broadcastStartedWithSetupInfo:(NSDictionary<NSString *, NSObject *> *)setupInfo
{
	struct sockaddr_un address = {0};
	connection = broadcast_address(&address) ? socket(AF_UNIX, SOCK_STREAM, 0) : -1;
	if (connection >= 0) {
		const int enabled = 1;
		setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
		if (connect(connection, (struct sockaddr *)&address, address.sun_len) == 0)
			return;
		[self broadcastFinished];
	}
	[self finishBroadcastWithError:[NSError errorWithDomain:OBS_BROADCAST_ID code:1
		userInfo:@{NSLocalizedDescriptionKey: @"Open the OBS display source before starting a broadcast."}]];
}

- (void)broadcastFinished
{
	if (connection >= 0)
		close(connection);
	connection = -1;
	close_slots(video, sizeof(video) / sizeof(*video));
	close_slots(audio, sizeof(audio) / sizeof(*audio));
}

- (void)broadcastPaused
{
	if (connection >= 0)
		send_slot(connection, BroadcastPause, NULL);
}

- (void)processSampleBuffer:(CMSampleBufferRef)sample withType:(RPSampleBufferType)type
{
	if (connection < 0 || !CMSampleBufferIsValid(sample) || !CMSampleBufferDataIsReady(sample))
		return;
	const bool is_video = type == RPSampleBufferTypeVideo;
	if (!is_video && type != RPSampleBufferTypeAudioApp)
		return;
	char unused;
	const ssize_t status = recv(connection, &unused, 1, MSG_PEEK | MSG_DONTWAIT);
	if (status == 0 || (status < 0 && errno != EAGAIN && errno != EINTR)) {
		[self broadcastFinished];
		[self finishBroadcastWithError:[NSError errorWithDomain:OBS_BROADCAST_ID code:2
			userInfo:@{NSLocalizedDescriptionKey: @"The OBS display source closed."}]];
		return;
	}
	struct Slot *slot = is_video ? free_slot(video, sizeof(video) / sizeof(*video))
				     : free_slot(audio, sizeof(audio) / sizeof(*audio));
	if (!slot || !(is_video ? copy_video(slot, sample) : copy_audio(slot, sample)))
		return;
	CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
	slot->frame->timestamp = CMTIME_IS_NUMERIC(pts) && pts.value >= 0
		? (uint64_t)CMTimeConvertScale(pts, 1000000000, kCMTimeRoundingMethod_Default).value : 0;
	atomic_store_explicit(&slot->frame->state, SlotReady, memory_order_release);
	if (!send_slot(connection, is_video ? BroadcastVideo : BroadcastAudio, slot))
		atomic_store_explicit(&slot->frame->state, SlotFree, memory_order_release);
}
@end
