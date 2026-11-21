/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <stdatomic.h>
#include <sys/un.h>
#include <unistd.h>

#define OBS_BROADCAST_ID @"org.obsproject.studio.ios.broadcast"
#define OBS_BROADCAST_ORIENTATION CFSTR("OBSReplayKitOrientation")
#define OBS_BROADCAST_MACH_SERVICE "com.obsproject.ios.screen.mach"
#define OBS_BROADCAST_MACH_FRAME 0x4f425301

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

struct BroadcastSurfaceMessage {
	mach_msg_header_t header;
	mach_msg_body_t body;
	mach_msg_port_descriptor_t surface;
	struct BroadcastFrame frame;
};

/* The iOS SDK omits these legacy declarations; libSystem still exports the MIG interfaces. */
typedef kern_return_t (*BroadcastBootstrapPort)(mach_port_t, const char *, mach_port_t *);
typedef kern_return_t (*BroadcastBootstrapRegister)(mach_port_t, const char *, mach_port_t);

static inline mach_port_t broadcast_lookup(void)
{
	BroadcastBootstrapPort lookup = (BroadcastBootstrapPort)dlsym(RTLD_DEFAULT, "bootstrap_look_up");
	mach_port_t bootstrap = MACH_PORT_NULL, service = MACH_PORT_NULL;
	if (lookup && task_get_bootstrap_port(mach_task_self(), &bootstrap) == KERN_SUCCESS) {
		if (lookup(bootstrap, OBS_BROADCAST_MACH_SERVICE, &service) != KERN_SUCCESS)
			service = MACH_PORT_NULL;
		mach_port_deallocate(mach_task_self(), bootstrap);
	}
	return service;
}

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
