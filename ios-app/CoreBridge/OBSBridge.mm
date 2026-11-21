/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 自研必要性证明：原版 obs-frontend-api 通过 Qt 前端调用 libobs，无法建立 UIKit 显示对象。
 * 此桥接调用原版生命周期和显示接口，提供 SwiftUI 所需的宿主边界。 */

#import "OBSBridge.h"
#include <graphics/vec2.h>
#include <util/base.h>

bool obs_app_start(const char *locale, const char *configDirectory)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (!obs_startup(locale, configDirectory, NULL))
		return false;

	obs_audio_info audio = {.samples_per_sec = 48000, .speakers = SPEAKERS_STEREO};
	obs_video_info video = {
		.graphics_module = "libobs-metal",
		.fps_num = 30,
		.fps_den = 1,
		.base_width = 1280,
		.base_height = 720,
		.output_width = 1280,
		.output_height = 720,
		.output_format = VIDEO_FORMAT_NV12,
		.adapter = 0,
		.gpu_conversion = true,
		.colorspace = VIDEO_CS_709,
		.range = VIDEO_RANGE_PARTIAL,
		.scale_type = OBS_SCALE_BICUBIC,
	};
	if (!obs_reset_audio(&audio) || obs_reset_video(&video) != OBS_VIDEO_SUCCESS || !obs_load_core_modules()) {
		obs_shutdown();
		return false;
	}
	obs_ios_load_extra_plugins();
	obs_post_load_modules();
	return true;
}

static void render_program(void *, uint32_t width, uint32_t height)
{
	obs_video_info video;
	if (!obs_get_video_info(&video))
		return;
	const double scale = fmin((double)width / video.base_width, (double)height / video.base_height);
	const int targetWidth = (int)(video.base_width * scale);
	const int targetHeight = (int)(video.base_height * scale);
	gs_viewport_push();
	gs_projection_push();
	gs_ortho(0, video.base_width, 0, video.base_height, -100, 100);
	gs_set_viewport(((int)width - targetWidth) / 2, ((int)height - targetHeight) / 2, targetWidth, targetHeight);
	obs_render_main_texture();
	gs_projection_pop();
	gs_viewport_pop();
}

obs_display_t *obs_app_create_display(UIView *view, uint32_t width, uint32_t height)
{
	gs_init_data data = {};
	data.window.view = view;
	data.cx = width;
	data.cy = height;
	data.format = GS_BGRA;
	data.zsformat = GS_ZS_NONE;
	obs_display_t *display = obs_display_create(&data, 0);
	if (display)
		obs_display_add_draw_callback(display, render_program, NULL);
	return display;
}

static obs_output_t *start_output(const char *id, obs_data_t *settings, obs_encoder_t *video, obs_encoder_t *audio,
				  obs_service_t *service)
{
	obs_output_t *output = obs_output_create(id, id, settings, NULL);
	if (!output)
		return NULL;
	obs_output_set_video_encoder(output, video);
	obs_output_set_audio_encoder(output, audio, 0);
	if (service)
		obs_output_set_service(output, service);
	if (!obs_output_start(output)) {
		blog(LOG_ERROR, "%s: %s", id, obs_output_get_last_error(output) ?: "");
		obs_output_release(output);
		return NULL;
	}
	return output;
}

void obs_app_recording_smoke(const char *path, const char *rtmpURL)
{
	obs_scene_t *scene = obs_scene_create("OBS");
	obs_data_t *settings = obs_data_create();
	obs_data_set_int(settings, "color", 0xFFE08822);
	obs_data_set_int(settings, "width", 1280);
	obs_data_set_int(settings, "height", 720);
	obs_source_t *color = obs_source_create("color_source_v3", "Color", settings, NULL);
	obs_data_release(settings);
	obs_source_t *filter = obs_source_create("color_filter_v2", "Color Correction", NULL, NULL);
	obs_source_filter_add(color, filter);
	obs_scene_add(scene, color);
	obs_source_release(filter);
	obs_source_release(color);

	settings = obs_data_create();
	obs_data_set_string(settings, "text", "OBS");
	obs_source_t *text = obs_source_create("text_ft2_source_v2", "Text", settings, NULL);
	obs_data_release(settings);
	obs_sceneitem_t *item = obs_scene_add(scene, text);
	vec2 position = {.x = 96, .y = 96};
	obs_sceneitem_set_pos(item, &position);
	obs_source_release(text);
	obs_set_output_source(0, obs_scene_get_source(scene));
	obs_scene_release(scene);

	settings = obs_data_create();
	obs_data_set_int(settings, "bitrate", 1500);
	obs_data_set_int(settings, "keyint_sec", 1);
	obs_data_set_string(settings, "preset", "veryfast");
	obs_encoder_t *video = obs_video_encoder_create("obs_x264", "H.264", settings, NULL);
	obs_data_release(settings);
	obs_encoder_t *audio = obs_audio_encoder_create("ffmpeg_aac", "AAC", NULL, 0, NULL);
	obs_encoder_set_video(video, obs_get_video());
	obs_encoder_set_audio(audio, obs_get_audio());

	settings = obs_data_create();
	obs_data_set_string(settings, "path", path);
	obs_output_t *recording = start_output("mp4_output", settings, video, audio, NULL);
	obs_data_release(settings);

	obs_output_t *stream = NULL;
	obs_service_t *service = NULL;
	if (rtmpURL && *rtmpURL) {
		settings = obs_data_create();
		obs_data_set_string(settings, "server", rtmpURL);
		obs_data_set_string(settings, "key", "phase1");
		service = obs_service_create("rtmp_custom", "RTMP", settings, NULL);
		obs_data_release(settings);
		if (service)
			stream = start_output("rtmp_output", NULL, video, audio, service);
	}

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		if (recording)
			obs_output_stop(recording);
		if (stream)
			obs_output_stop(stream);
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
			obs_output_release(recording);
			obs_output_release(stream);
			obs_service_release(service);
			obs_encoder_release(audio);
			obs_encoder_release(video);
		});
	});
}
