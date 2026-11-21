/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once

#import <UIKit/UIKit.h>
#include <obs.h>
#include <obs-ios.h>

#ifdef __cplusplus
extern "C" {
#endif

bool obs_app_start(const char *locale, const char *configDirectory);
obs_display_t *obs_app_create_display(UIView *view, uint32_t width, uint32_t height);
void obs_app_recording_smoke(const char *path, const char *rtmpURL);

#ifdef __cplusplus
}
#endif
