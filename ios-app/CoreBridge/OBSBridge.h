/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once

#import <UIKit/UIKit.h>
#include <obs.h>
#include <obs-ios.h>
#include <obs-frontend-api.h>
#include <obs-audio-controls.h>
#include <graphics/vec2.h>
#include <util/bmem.h>
#include <util/config-file.h>
#include <util/platform.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct obs_app_display obs_app_display_t;
bool obs_app_start(const char *locale, const char *configDirectory);
obs_app_display_t *obs_app_create_display(UIView *view, uint32_t width, uint32_t height);
void obs_app_display_resize(obs_app_display_t *display, uint32_t width, uint32_t height);
void obs_app_display_set_source(obs_app_display_t *display, obs_source_t *source);
void obs_app_display_destroy(obs_app_display_t *display);
CGRect obs_app_item_bounds(obs_sceneitem_t *item);
void obs_app_recording_smoke(const char *path, const char *rtmpURL);
bool obs_app_frontend_open(const char *directory, const char *locale);
void obs_app_frontend_ready(void);
void obs_app_frontend_close(void);
obs_source_t *obs_app_create_scene(const char *name);
void obs_app_remove_scene(obs_source_t *scene);
void obs_app_move_scene(obs_source_t *scene, int position);
void obs_app_frontend_reload_locale(const char *locale);
obs_data_t *obs_app_websocket_settings(void);
void obs_app_websocket_apply(obs_data_t *settings);
void obs_app_websocket_disconnect(const char *address);

#ifdef __cplusplus
}
#endif
