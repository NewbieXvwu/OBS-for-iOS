/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once

#import <Foundation/Foundation.h>
#include <stdatomic.h>
#include <sys/un.h>
#include <unistd.h>

#define OBS_BROADCAST_ID @"org.obsproject.studio.ios.broadcast"
#define OBS_BROADCAST_ORIENTATION CFSTR("OBSReplayKitOrientation")

enum { BroadcastVideo = 1, BroadcastAudio, BroadcastPause };
enum { SlotFree, SlotReady };
enum { PCMInt16 = 1, PCMInt32, PCMFloat32 };
enum { Color601 = 1, Color709, Color2020, ColorP3, ColorPQ, ColorHLG };
enum { BroadcastMaxBytes = 64 * 1024 * 1024 };

struct BroadcastFrame {
	_Atomic(uint32_t) state;
	uint32_t capacity;
	uint32_t format, width, height;
	uint32_t stride[2], size[2];
	uint32_t orientation, matrix, primaries, transfer;
	uint32_t rate, channels, samples;
	uint64_t timestamp;
};

static inline NSURL *broadcast_container(void)
{
	return [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:
		@"group.org.obsproject.studio.ios"];
}

static inline bool broadcast_address(struct sockaddr_un *address)
{
	NSURL *url = [broadcast_container() URLByAppendingPathComponent:@"obs.sock"];
	const char *path = url.fileSystemRepresentation;
	if (!path || strlen(path) >= sizeof(address->sun_path))
		return false;
	address->sun_family = AF_UNIX;
	strlcpy(address->sun_path, path, sizeof(address->sun_path));
	address->sun_len = SUN_LEN(address);
	return true;
}
