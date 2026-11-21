/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 自研必要性证明：原版 OBSStudioAPI 与 OBSBasic 通过 Qt 信号和窗口执行前端操作。
 * 这里实现原版 obs_frontend_callbacks，将系统界面交给 SwiftUI，复用 OBS 配置和场景序列化。 */

#import "OBSBridge.h"
#include <obs-frontend-internal.hpp>
#include <obs.hpp>
#include <util/config-file.h>
#include <util/platform.h>
#include <util/text-lookup.h>

#include <algorithm>
#include <array>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <string_view>

namespace fs = std::filesystem;

namespace {

using Config = std::unique_ptr<config_t, decltype(&config_close)>;
using Locale = std::unique_ptr<lookup_t, decltype(&text_lookup_destroy)>;

Config openConfig(const fs::path &path)
{
	config_t *config = nullptr;
	config_open(&config, path.c_str(), CONFIG_OPEN_ALWAYS);
	return Config(config, config_close);
}

bool validName(const char *name)
{
	return name && *name && strcmp(name, ".") != 0 && strcmp(name, "..") != 0 && !strchr(name, '/') &&
	       !strchr(name, ':');
}

void uiMessage(NSString *action, NSDictionary *values = nil)
{
	dispatch_async(dispatch_get_main_queue(), ^{
		[NSNotificationCenter.defaultCenter postNotificationName:@"OBSFrontendAction" object:action userInfo:values];
	});
}

void queueUiTask(obs_task_t task, void *parameter, bool wait)
{
	if (NSThread.isMainThread) {
		task(parameter);
	} else if (wait) {
		dispatch_sync(dispatch_get_main_queue(), ^{ task(parameter); });
	} else {
		dispatch_async(dispatch_get_main_queue(), ^{ task(parameter); });
	}
}

enum Slot { Stream, Recording, Replay };

class IOSFrontend final : public obs_frontend_callbacks {
	using Event = std::pair<obs_frontend_event_cb, void *>;
	using SaveCallback = std::pair<obs_frontend_save_cb, void *>;

	const fs::path root;
	Config user;
	Config app;
	std::map<std::string, Config> profileConfigs;
	std::string profile;
	std::string collection;
	Locale translations{nullptr, text_lookup_destroy};
	std::recursive_mutex stateMutex;
	std::mutex callbackMutex;
	std::vector<Event> events;
	std::vector<SaveCallback> saveCallbacks, preloadCallbacks;
	std::vector<obs_frontend_translate_ui_cb> extraTranslations;
	std::vector<OBSSource> sources, scenes, transitions;
	struct UndoAction {
		std::string name, before, after;
		undo_redo_cb undo, redo;
	};
	std::vector<UndoAction> undoActions;
	size_t undoPosition = 0;
	OBSSource program, preview, transition;
	std::vector<OBSCanvas> canvases;
	OBSSceneItem copiedItem;
	std::array<OBSOutput, 3> outputs;
	OBSService service;
	std::string recordingPath, screenshotPath;
	int duration = 300;
	int tbarPosition = 0;
	int deferSave = 0;
	bool studio = false;
	bool previewEnabled = true;

	fs::path profilePath(const std::string &name) const { return root / "basic/profiles" / name; }
	fs::path collectionPath(const std::string &name) const { return root / "basic/scenes" / (name + ".json"); }
	config_t *profileConfig() { return profileConfigs.at(profile).get(); }

	std::string recordingDirectory()
	{
		const char *path = obs_ios_get_recording_dir();
		if (path && *path)
			return path;
		NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
							       inDomains:NSUserDomainMask].firstObject;
		return [documents URLByAppendingPathComponent:@"OBS" isDirectory:YES].fileSystemRepresentation;
	}

	std::string configuredRecordingDirectory()
	{
		config_t *config = profileConfig();
		bool advanced = strcmp(config_get_string(config, "Output", "Mode"), "Advanced") == 0;
		const char *directory = config_get_string(config, advanced ? "AdvOut" : "SimpleOutput",
							 advanced ? "RecFilePath" : "FilePath");
		return directory && *directory ? directory : recordingDirectory();
	}

	bool hasRecordingCapacity(const std::string &directory)
	{
		NSURL *url = [NSURL fileURLWithFileSystemRepresentation:directory.c_str() isDirectory:YES relativeToURL:nil];
		NSNumber *available = nil;
		[url getResourceValue:&available forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nullptr];
		if (!available || available.longLongValue >= 100LL * 1024 * 1024)
			return true;
		uiMessage(@"OutputError", @{@"message": @(obs_frontend_get_locale_string("Output.RecordNoSpace.Msg"))});
		return false;
	}

	void profileDefaults(config_t *config)
	{
		config_set_default_string(config, "Output", "Mode", "Simple");
		config_set_default_string(config, "Output", "FilenameFormatting", "%CCYY-%MM-%DD %hh-%mm-%ss");
		config_set_default_string(config, "SimpleOutput", "StreamEncoder", "x264");
		config_set_default_string(config, "SimpleOutput", "RecEncoder", "x264");
		config_set_default_string(config, "SimpleOutput", "RecQuality", "Stream");
		config_set_default_uint(config, "SimpleOutput", "VBitrate", 2500);
		config_set_default_uint(config, "SimpleOutput", "ABitrate", 160);
		config_set_default_uint(config, "SimpleOutput", "RecTracks", 1);
		config_set_default_uint(config, "SimpleOutput", "RecRBTime", 15);
		config_set_default_uint(config, "SimpleOutput", "RecRBSize", 500);
		config_set_default_string(config, "SimpleOutput", "RecFormat2", "hybrid_mp4");
		config_set_default_string(config, "SimpleOutput", "FilePath", recordingDirectory().c_str());
		config_set_default_string(config, "AdvOut", "RecFilePath", recordingDirectory().c_str());
		config_set_default_string(config, "AdvOut", "RecFormat2", "hybrid_mp4");
		config_set_default_string(config, "AdvOut", "Encoder", "obs_x264");
		config_set_default_string(config, "AdvOut", "RecEncoder", "none");
		config_set_default_string(config, "AdvOut", "AudioEncoder", "none");
		config_set_default_string(config, "AdvOut", "RecAudioEncoder", "none");
		config_set_default_bool(config, "AdvOut", "ApplyServiceSettings", true);
		config_set_default_uint(config, "AdvOut", "TrackIndex", 1);
		config_set_default_uint(config, "AdvOut", "RecTracks", 1);
		config_set_default_uint(config, "AdvOut", "RecRBTime", 15);
		config_set_default_uint(config, "AdvOut", "RecRBSize", 500);
		config_set_default_bool(config, "SimpleOutput", "RecRB", true);
		config_set_default_bool(config, "AdvOut", "RecRB", true);
		for (int track = 1; track <= MAX_AUDIO_MIXES; track++)
			config_set_default_uint(config, "AdvOut", ("Track" + std::to_string(track) + "Bitrate").c_str(), 160);
		config_set_default_bool(config, "Output", "Reconnect", true);
		config_set_default_uint(config, "Output", "RetryDelay", 2);
		config_set_default_uint(config, "Output", "MaxRetries", 25);
		config_set_default_uint(config, "Output", "DelaySec", 20);
		config_set_default_bool(config, "Output", "DelayPreserve", true);
		config_set_default_uint(config, "Video", "BaseCX", 1280);
		config_set_default_uint(config, "Video", "BaseCY", 720);
		config_set_default_uint(config, "Video", "OutputCX", 1280);
		config_set_default_uint(config, "Video", "OutputCY", 720);
		config_set_default_string(config, "Video", "FPSCommon", "30");
		config_set_default_uint(config, "Video", "FPSInt", 30);
		config_set_default_uint(config, "Video", "FPSNum", 30000);
		config_set_default_uint(config, "Video", "FPSDen", 1001);
		config_set_default_string(config, "Video", "ColorFormat", "NV12");
		config_set_default_string(config, "Video", "ColorSpace", "709");
		config_set_default_string(config, "Video", "ColorRange", "Partial");
		config_set_default_string(config, "Video", "ScaleType", "bicubic");
		config_set_default_uint(config, "Video", "SdrWhiteLevel", 300);
		config_set_default_uint(config, "Video", "HdrNominalPeakLevel", 1000);
		config_set_default_uint(config, "Audio", "SampleRate", 48000);
		config_set_default_string(config, "Audio", "ChannelSetup", "Stereo");
		config_set_default_string(config, "Audio", "MonitoringDeviceId", "default");
		config_set_default_double(config, "Audio", "MeterDecayRate", 23.53);
		config_set_default_uint(config, "Audio", "PeakMeterType", 1);
	}

	bool openProfile(const std::string &name)
	{
		if (!profileConfigs.count(name)) {
			std::error_code error;
			fs::create_directories(profilePath(name), error);
			Config config = openConfig(profilePath(name) / "basic.ini");
			if (!config)
				return false;
			config_set_default_string(config.get(), "General", "Name", name.c_str());
			profileDefaults(config.get());
			profileConfigs.emplace(name, std::move(config));
		}
		profile = name;
		return true;
	}

	void loadService()
	{
		OBSDataAutoRelease saved = obs_data_create_from_json_file((profilePath(profile) / "service.json").c_str());
		const char *type = obs_data_get_string(saved, "type");
		OBSDataAutoRelease settings = obs_data_get_obj(saved, "settings");
		OBSServiceAutoRelease opened = obs_service_create(type && *type ? type : "rtmp_custom", "service", settings,
								 NULL);
		service = opened.Get();
	}

	void loadCollection()
	{
		OBSDataAutoRelease saved = obs_data_create_from_json_file(collectionPath(collection).c_str());
		OBSDataArrayAutoRelease serialized = obs_data_get_array(saved, "sources");
		if (serialized) {
			obs_load_sources(serialized, [](void *context, obs_source_t *source) {
				auto *frontend = static_cast<IOSFrontend *>(context);
				frontend->sources.emplace_back(source);
				if (obs_scene_from_source(source) && !obs_source_is_group(source))
					frontend->scenes.emplace_back(source);
			}, this);
			OBSDataArrayAutoRelease order = obs_data_get_array(saved, "scene_order");
			for (size_t i = 0; i < obs_data_array_count(order) && i < scenes.size(); ++i) {
				OBSDataAutoRelease item = obs_data_array_item(order, i);
				const char *name = obs_data_get_string(item, "name");
				auto found = std::find_if(scenes.begin() + i, scenes.end(), [name](const auto &source) {
					return strcmp(obs_source_get_name(source), name) == 0;
				});
				if (found != scenes.end())
					std::rotate(scenes.begin() + i, found, found + 1);
			}
		}
		if (scenes.empty()) {
			OBSSceneAutoRelease scene = obs_scene_create(obs_frontend_get_locale_string("Basic.Scene"));
			scenes.emplace_back(obs_scene_get_source(scene));
		}

		OBSDataArrayAutoRelease transitionData = obs_data_get_array(saved, "transitions");
		for (size_t i = 0; i < obs_data_array_count(transitionData); ++i) {
			OBSDataAutoRelease item = obs_data_array_item(transitionData, i);
			OBSSourceAutoRelease source = obs_load_private_source(item);
			if (source)
				transitions.emplace_back(source.Get());
		}
		const char *id = nullptr;
		for (size_t index = 0; obs_enum_transition_types(index, &id); index++) {
			const char *label = obs_source_get_display_name(id);
			if (!label)
				continue;
			if (std::none_of(transitions.begin(), transitions.end(), [id](const auto &source) {
				    return strcmp(obs_source_get_id(source), id) == 0;
			    })) {
				OBSSourceAutoRelease source = obs_source_create_private(id, label, NULL);
				if (source)
					transitions.emplace_back(source.Get());
			}
		}
		const char *savedTransition = obs_data_get_string(saved, "current_transition");
		for (const auto &candidate : transitions) {
			if (!transition || strcmp(obs_source_get_id(candidate), "fade_transition") == 0)
				transition = candidate;
			if (savedTransition && strcmp(obs_source_get_name(candidate), savedTransition) == 0) {
				transition = candidate;
				break;
			}
		}
		OBSSourceAutoRelease savedProgram = obs_get_source_by_name(obs_data_get_string(saved, "current_program_scene"));
		OBSSourceAutoRelease savedPreview = obs_get_source_by_name(obs_data_get_string(saved, "current_scene"));
		program = savedProgram ? OBSSource(savedProgram.Get()) : scenes.front();
		preview = savedPreview ? OBSSource(savedPreview.Get()) : program;
		if (obs_data_has_user_value(saved, "transition_duration"))
			duration = (int)std::clamp<int64_t>(obs_data_get_int(saved, "transition_duration"), 0, 20000);
		if (transition) {
			obs_transition_set(transition, program);
			obs_set_output_source(0, transition);
		} else {
			obs_set_output_source(0, program);
		}
		OBSDataAutoRelease moduleData = obs_data_get_obj(saved, "modules");
		if (moduleData) {
			on_preload(moduleData);
			on_load(moduleData);
		}
	}

	bool isOutputActive() const
	{
		return std::any_of(outputs.begin(), outputs.end(), [](const auto &output) { return obs_output_active(output); });
	}

	static constexpr obs_frontend_event outputEvents[3][4] = {
		{OBS_FRONTEND_EVENT_STREAMING_STARTING, OBS_FRONTEND_EVENT_STREAMING_STARTED,
		 OBS_FRONTEND_EVENT_STREAMING_STOPPING, OBS_FRONTEND_EVENT_STREAMING_STOPPED},
		{OBS_FRONTEND_EVENT_RECORDING_STARTING, OBS_FRONTEND_EVENT_RECORDING_STARTED,
		 OBS_FRONTEND_EVENT_RECORDING_STOPPING, OBS_FRONTEND_EVENT_RECORDING_STOPPED},
		{OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTING, OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED,
		 OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPING, OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED},
	};
	struct OutputSignalContext {
		IOSFrontend *frontend;
		obs_frontend_event event;
	};
	std::array<std::array<OutputSignalContext, 4>, 3> outputSignals;

	void connectOutput(obs_output_t *output, Slot slot)
	{
		constexpr const char *signals[] = {"starting", "start", "stopping", "stop"};
		signal_handler_t *handler = obs_output_get_signal_handler(output);
		for (int i = 0; i < 4; i++) {
			outputSignals[slot][i] = {this, outputEvents[slot][i]};
			signal_handler_connect(handler, signals[i], [](void *context, calldata_t *) {
				auto *state = static_cast<OutputSignalContext *>(context);
				state->frontend->on_event(state->event);
			}, &outputSignals[slot][i]);
		}
		if (slot == Replay) {
			signal_handler_connect(handler, "saving", [](void *context, calldata_t *) {
				static_cast<IOSFrontend *>(context)->on_event(OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVING);
			}, this);
			signal_handler_connect(handler, "saved", [](void *context, calldata_t *) {
				static_cast<IOSFrontend *>(context)->on_event(OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED);
			}, this);
		}
	}

	void startOutput(Slot slot)
	{
		std::lock_guard lock(stateMutex);
		if (obs_output_active(outputs[slot]))
			return;
		config_t *config = profileConfig();
		const bool advanced = strcmp(config_get_string(config, "Output", "Mode"), "Advanced") == 0;
		const char *section = advanced ? "AdvOut" : "SimpleOutput";
		if (slot == Replay && !config_get_bool(config, section, "RecRB"))
			return;
		const char *format = config_get_string(config, section, "RecFormat2");
		const bool hybrid = strcmp(format, "hybrid_mp4") == 0 || strcmp(format, "hybrid_mov") == 0;
		const bool mov = strcmp(format, "hybrid_mov") == 0 || strcmp(format, "mov") == 0;
		const char *id = slot == Replay ? "replay_buffer" : (mov ? "mov_output" : "mp4_output");
		const bool canSpawn = obs_ios_get_capabilities() & OBS_IOS_CAP_SPAWN_MUXER;
		if (slot == Recording && canSpawn && !hybrid)
			id = "ffmpeg_muxer";
		OBSDataAutoRelease outputSettings = obs_data_create();
		if (slot == Stream) {
			id = obs_service_get_preferred_output_type(service);
			if (!id || !*id)
				id = "rtmp_output";
			obs_data_set_bool(outputSettings, "dyn_bitrate", config_get_bool(config, "Output", "DynamicBitrate"));
		} else {
			std::string directory = configuredRecordingDirectory();
			if (os_mkdirs(directory.c_str()) < 0)
				return;
			if (!hasRecordingCapacity(directory))
				return;
			const char *extension = format;
			if (hybrid || !canSpawn)
				extension = mov ? "mov" : "mp4";
			else if (strcmp(format, "fragmented_mp4") == 0)
				extension = "mp4";
			else if (strcmp(format, "fragmented_mov") == 0)
				extension = "mov";
			else if (strcmp(format, "hls") == 0)
				extension = "m3u8";
			else if (strcmp(format, "mpegts") == 0)
				extension = "ts";
			const char *pattern = config_get_string(config, "Output", "FilenameFormatting");
			if (slot == Replay) {
				obs_data_set_string(outputSettings, "directory", directory.c_str());
				const char *prefix = config_get_string(config, "SimpleOutput", "RecRBPrefix");
				const char *suffix = config_get_string(config, "SimpleOutput", "RecRBSuffix");
				std::string filename = prefix && *prefix ? std::string(prefix) + " " + pattern : pattern;
				if (suffix && *suffix)
					filename += " " + std::string(suffix);
				obs_data_set_string(outputSettings, "format", filename.c_str());
				obs_data_set_string(outputSettings, "extension", extension);
				obs_data_set_bool(outputSettings, "hybrid", hybrid);
				obs_data_set_int(outputSettings, "max_time_sec", config_get_uint(config, section, "RecRBTime"));
				obs_data_set_int(outputSettings, "max_size_mb", config_get_uint(config, section, "RecRBSize"));
			} else {
				char *file = os_generate_formatted_filename(extension, true, pattern);
					auto original = fs::path(directory) / file;
					auto path = original;
					for (unsigned index = 2; os_file_exists(path.c_str()); ++index)
						path = original.parent_path() / (original.stem().string() + " (" + std::to_string(index) +
										 ")" + original.extension().string());
					recordingPath = path.string();
				bfree(file);
				obs_data_set_string(outputSettings, "path", recordingPath.c_str());
					std::string muxer = config_get_string(config, section, "RecMuxerCustom") ?: "";
					if (strncmp(format, "fragmented_", 11) == 0 && canSpawn)
						muxer = "movflags=frag_keyframe+empty_moov+delay_moov " + muxer;
					obs_data_set_string(outputSettings, "muxer_settings", muxer.c_str());
			}
		}
		OBSOutputAutoRelease output = obs_output_create(id, id, outputSettings, NULL);
		if (!output)
			return;
		const char *streamEncoder = config_get_string(config, section, advanced ? "Encoder" : "StreamEncoder");
		const char *encoderId = slot == Stream ? streamEncoder : config_get_string(config, section, "RecEncoder");
		const char *quality = config_get_string(config, "SimpleOutput", "RecQuality");
		if (!advanced && strcmp(quality, "Stream") == 0)
			encoderId = streamEncoder;
		if (!encoderId || !*encoderId || strcmp(encoderId, "none") == 0)
			encoderId = streamEncoder;
		if (strcmp(encoderId, "x264") == 0)
			encoderId = "obs_x264";
		OBSDataAutoRelease encoderSettings = obs_data_create();
		if (advanced) {
			auto name = slot == Stream || strcmp(encoderId, streamEncoder) == 0 ? "streamEncoder.json" : "recordEncoder.json";
			OBSDataAutoRelease saved = obs_data_create_from_json_file((profilePath(profile) / name).c_str());
			if (saved)
				obs_data_apply(encoderSettings, saved);
		} else {
			obs_data_set_int(encoderSettings, "bitrate", config_get_uint(config, section, "VBitrate"));
			if (slot != Stream && strcmp(quality, "Stream") != 0) {
				const bool high = strcmp(quality, "HQ") == 0;
				obs_data_set_string(encoderSettings, "rate_control", "CRF");
				obs_data_set_int(encoderSettings, "crf", high ? 16 : 23);
				obs_data_set_int(encoderSettings, "quality", high ? 82 : 67);
			}
		}
		OBSDataAutoRelease audioSettings = obs_data_create();
		obs_data_set_int(audioSettings, "bitrate", config_get_uint(config, "SimpleOutput", "ABitrate"));
		const bool applyServiceSettings = !advanced || config_get_bool(config, "AdvOut", "ApplyServiceSettings");
		if (slot == Stream) {
			if (applyServiceSettings)
				obs_service_apply_encoder_settings(service, encoderSettings, audioSettings);
			obs_output_set_service(output, service);
			obs_output_set_reconnect_settings(output,
				config_get_bool(config, "Output", "Reconnect") ? (int)config_get_uint(config, "Output", "MaxRetries") : 0,
				(int)config_get_uint(config, "Output", "RetryDelay"));
			if (config_get_bool(config, "Output", "DelayEnable"))
				obs_output_set_delay(output, (uint32_t)config_get_uint(config, "Output", "DelaySec"),
					config_get_bool(config, "Output", "DelayPreserve") ? OBS_OUTPUT_DELAY_PRESERVE : 0);
		}
		OBSEncoderAutoRelease video = obs_video_encoder_create(encoderId, id, encoderSettings, NULL);
		if (!video)
			return;
		obs_encoder_set_video(video, obs_get_video());
		obs_output_set_video_encoder(output, video);
		uint64_t tracks = slot == Stream ? (1ULL << (std::clamp<uint64_t>(config_get_uint(config, "AdvOut", "TrackIndex"), 1, 6) - 1))
					       : config_get_uint(config, section, "RecTracks");
		const char *audioId = strcmp(id, "whip_output") == 0 ? "ffmpeg_opus" :
			obs_encoder_get_display_name("CoreAudio_AAC") ? "CoreAudio_AAC" : "ffmpeg_aac";
		if (advanced) {
			const char *selectedAudio = config_get_string(config, section, slot == Stream ? "AudioEncoder" : "RecAudioEncoder");
			const char *codec = obs_get_encoder_codec(selectedAudio);
			const char *supported = obs_output_get_supported_audio_codecs(output);
			if (codec && (!supported || std::string_view(supported).find(codec) != std::string_view::npos))
				audioId = selectedAudio;
		}
		for (size_t track = 0, index = 0; track < MAX_AUDIO_MIXES; track++) {
			if (!(tracks & (1ULL << track)))
				continue;
			if (advanced) {
				obs_data_set_int(audioSettings, "bitrate", config_get_uint(config, "AdvOut",
					("Track" + std::to_string(track + 1) + "Bitrate").c_str()));
				if (slot == Stream && applyServiceSettings)
					obs_service_apply_encoder_settings(service, nullptr, audioSettings);
			}
			OBSEncoderAutoRelease audio = obs_audio_encoder_create(audioId, id, audioSettings, track, NULL);
			if (!audio)
				return;
			obs_encoder_set_audio(audio, obs_get_audio());
			obs_output_set_audio_encoder(output, audio, index++);
		}
		outputs[slot] = output.Get();
		connectOutput(output, slot);
		if (!obs_output_start(output))
			uiMessage(@"OutputError", @{@"message": @(obs_output_get_last_error(output) ?: "")});
		else if (slot == Stream) {
			if (config_get_bool(user.get(), "BasicWindow", "RecordWhenStreaming"))
				startOutput(Recording);
			if (config_get_bool(user.get(), "BasicWindow", "ReplayBufferWhileStreaming"))
				startOutput(Replay);
		}
	}

	obs_output_t *getOutput(Slot slot)
	{
		std::lock_guard lock(stateMutex);
		return obs_output_get_ref(outputs[slot]);
	}
	bool active(Slot slot)
	{
		OBSOutputAutoRelease output = getOutput(slot);
		return obs_output_active(output);
	}
	void stopOutput(Slot slot)
	{
		OBSOutputAutoRelease output = getOutput(slot);
		if (output)
			obs_output_stop(output);
	}

	static void appendSources(obs_frontend_source_list *list, const std::vector<OBSSource> &items)
	{
		for (const auto &item : items) {
			obs_source_t *source = obs_source_get_ref(item);
			da_push_back(list->sources, &source);
		}
	}

	void sendSourceAction(NSString *action, obs_source_t *source)
	{
		const char *uuid = obs_source_get_uuid(source);
		if (uuid)
			uiMessage(action, @{@"source": @(uuid)});
	}

	using HotkeyAction = void (*)();
	struct Hotkey {
		const char *name;
		const char *title;
		HotkeyAction action;
		obs_hotkey_id id = OBS_INVALID_HOTKEY_ID;
	};
	std::array<Hotkey, 11> hotkeys = {{
		{"OBSBasic.StartStreaming", "Basic.Main.StartStreaming", ::obs_frontend_streaming_start},
		{"OBSBasic.StopStreaming", "Basic.Main.StopStreaming", ::obs_frontend_streaming_stop},
		{"OBSBasic.StartRecording", "Basic.Main.StartRecording", ::obs_frontend_recording_start},
		{"OBSBasic.StopRecording", "Basic.Main.StopRecording", ::obs_frontend_recording_stop},
		{"OBSBasic.PauseRecording", "Basic.Main.PauseRecording", [] { ::obs_frontend_recording_pause(true); }},
		{"OBSBasic.UnpauseRecording", "Basic.Main.UnpauseRecording", [] { ::obs_frontend_recording_pause(false); }},
		{"OBSBasic.StartReplayBuffer", "Basic.Main.StartReplayBuffer", ::obs_frontend_replay_buffer_start},
		{"OBSBasic.StopReplayBuffer", "Basic.Main.StopReplayBuffer", ::obs_frontend_replay_buffer_stop},
		{"OBSBasic.SaveReplayBuffer", "Basic.Main.SaveReplay", ::obs_frontend_replay_buffer_save},
		{"OBSBasic.Transition", "Transition", ::obs_frontend_preview_program_trigger_transition},
		{"OBSBasic.TogglePreviewProgram", "Basic.Main.StudioMode", [] {
			::obs_frontend_set_preview_program_mode(!::obs_frontend_preview_program_mode_active());
		}},
	}};

	void loadHotkeys()
	{
		for (auto &key : hotkeys) {
			if (key.id == OBS_INVALID_HOTKEY_ID) {
				key.id = obs_hotkey_register_frontend(key.name, key.title,
					[](void *data, obs_hotkey_id, obs_hotkey_t *, bool pressed) {
						if (pressed) {
							const auto action = static_cast<const Hotkey *>(data)->action;
							dispatch_async(dispatch_get_main_queue(), ^{ action(); });
						}
					}, &key);
			}
			const char *json = config_get_string(profileConfig(), "Hotkeys", key.name);
			OBSDataAutoRelease binding = json ? obs_data_create_from_json(json) : nullptr;
			OBSDataArrayAutoRelease array = binding ? obs_data_get_array(binding, "bindings") : nullptr;
			obs_hotkey_load(key.id, array);
		}
	}

	void resetAudio()
	{
		config_t *config = profileConfig();
		const char *layout = config_get_string(config, "Audio", "ChannelSetup");
		speaker_layout speakers = SPEAKERS_STEREO;
		if (strcmp(layout, "Mono") == 0) speakers = SPEAKERS_MONO;
		if (strcmp(layout, "2.1") == 0) speakers = SPEAKERS_2POINT1;
		if (strcmp(layout, "4.0") == 0) speakers = SPEAKERS_4POINT0;
		if (strcmp(layout, "4.1") == 0) speakers = SPEAKERS_4POINT1;
		if (strcmp(layout, "5.1") == 0) speakers = SPEAKERS_5POINT1;
		if (strcmp(layout, "7.1") == 0) speakers = SPEAKERS_7POINT1;
		obs_audio_info audio = {(uint32_t)config_get_uint(config, "Audio", "SampleRate"), speakers};
		obs_audio_info current = {};
		if (!obs_get_audio_info(&current) || current.samples_per_sec != audio.samples_per_sec || current.speakers != speakers) {
			if (obs_reset_audio(&audio))
				obs_reset_audio_monitoring();
		}
		const char *monitor = config_get_string(config, "Audio", "MonitoringDeviceId");
		obs_set_audio_monitoring_device(monitor, monitor);
	}

	void applyMicInputs()
	{
		for (int index = 1; index <= 4; ++index) {
			const auto key = "AuxDevice" + std::to_string(index);
			const char *selected = config_get_string(profileConfig(), "Audio", key.c_str());
			if (!selected || !*selected) {
				obs_set_output_source(index, nullptr);
				continue;
			}
			const auto label = "Basic.Settings.Audio.AuxDevice" + (index == 1 ? "" : std::to_string(index));
			OBSDataAutoRelease settings = obs_data_create();
			obs_data_set_string(settings, "device_id", selected);
			OBSSourceAutoRelease known = obs_get_output_source(index);
			if (known) {
				obs_source_update(known, settings);
			} else {
				OBSSourceAutoRelease mic = obs_source_create_private("ios_audio_input",
					obs_frontend_get_locale_string(label.c_str()), settings);
				obs_set_output_source(index, mic);
			}
		}
	}

public:
	IOSFrontend(const char *directory, const char *locale)
		: root(directory), user(openConfig(root / "user.ini")), app(openConfig(root / "global.ini"))
	{
		reloadLocale(locale);
		if (!user || !app)
			return;
		config_set_default_bool(user.get(), "General", "ConfirmOnExit", true);
		config_set_default_bool(user.get(), "BasicWindow", "SnappingEnabled", true);
		config_set_default_bool(user.get(), "BasicWindow", "ScreenSnapping", true);
		config_set_default_bool(user.get(), "BasicWindow", "CenterSnapping", true);
		config_set_default_bool(user.get(), "BasicWindow", "SourceSnapping", true);
		config_set_default_double(user.get(), "BasicWindow", "SnapDistance", 10);
		const char *lastProfile = config_get_string(user.get(), "Basic", "ProfileDir");
		const char *lastCollection = config_get_string(user.get(), "Basic", "SceneCollectionFile");
		const char *untitled = obs_frontend_get_locale_string("Untitled");
		collection = validName(lastCollection) ? lastCollection : untitled;
		openProfile(validName(lastProfile) ? lastProfile : untitled);
		std::error_code error;
		fs::create_directories(root / "basic/scenes", error);
	}

	bool valid() const { return user && app && !profile.empty(); }

	void ready()
	{
		std::lock_guard lock(stateMutex);
		resetAudio();
		obs_frontend_reset_video();
		loadService();
		loadCollection();
		applyMicInputs();
		loadHotkeys();
		obs_frontend_save();
	}

	void releaseSources()
	{
		std::lock_guard lock(stateMutex);
		obs_frontend_save();
		on_event(OBS_FRONTEND_EVENT_EXIT);
		for (int channel = 0; channel <= 4; channel++)
			obs_set_output_source(channel, nullptr);
		for (auto &output : outputs)
			output = nullptr;
		program = nullptr;
		preview = nullptr;
		transition = nullptr;
		copiedItem = nullptr;
		transitions.clear();
		scenes.clear();
		sources.clear();
		canvases.clear();
		service = nullptr;
	}

	void reloadLocale(const char *locale)
	{
		std::lock_guard lock(stateMutex);
		char *directory = os_get_program_data_path_ptr("locale");
		fs::path path(directory);
		bfree(directory);
		translations.reset(text_lookup_create((path / "en-US.ini").c_str()));
		if (translations && strcmp(locale, "en-US") != 0)
			text_lookup_add(translations.get(), (path / (std::string(locale) + ".ini")).c_str());
	}

	void applyAudio()
	{
		std::lock_guard lock(stateMutex);
		if (!isOutputActive()) {
			resetAudio();
			applyMicInputs();
		}
	}

	void checkRecordingCapacity()
	{
		std::lock_guard lock(stateMutex);
		if (!recordingPath.empty() && obs_output_active(outputs[Recording]) &&
		    !hasRecordingCapacity(fs::path(recordingPath).parent_path().string()))
			stopOutput(Recording);
	}

	void quickTransition(obs_source_t *value)
	{
		std::lock_guard lock(stateMutex);
		if (!studio || !preview || !value)
			return;
		auto saved = transition;
		transition = value;
		++deferSave;
		obs_frontend_set_current_scene(preview);
		--deferSave;
		transition = saved;
		obs_frontend_save();
	}

	obs_source_t *addScene(const char *name)
	{
		std::lock_guard lock(stateMutex);
		OBSSceneAutoRelease scene = obs_scene_create(name);
		if (!scene)
			return NULL;
		obs_source_t *source = obs_scene_get_source(scene);
		scenes.emplace_back(source);
		obs_frontend_set_current_preview_scene(source);
		if (!studio)
			obs_frontend_set_current_scene(source);
		obs_frontend_save();
		on_event(OBS_FRONTEND_EVENT_SCENE_LIST_CHANGED);
		return obs_source_get_ref(source);
	}

	void removeScene(obs_source_t *source)
	{
		std::lock_guard lock(stateMutex);
		if (scenes.size() <= 1)
			return;
		scenes.erase(std::remove_if(scenes.begin(), scenes.end(), [source](const auto &item) { return item == source; }),
			     scenes.end());
		if (program == source)
			obs_frontend_set_current_scene(scenes.front());
		if (preview == source)
			obs_frontend_set_current_preview_scene(scenes.front());
		obs_source_remove(source);
		obs_frontend_save();
		on_event(OBS_FRONTEND_EVENT_SCENE_LIST_CHANGED);
	}

	void moveScene(obs_source_t *source, int position)
	{
		std::lock_guard lock(stateMutex);
		auto from = std::find_if(scenes.begin(), scenes.end(), [source](const auto &item) { return item == source; });
		if (from == scenes.end() || position < 0 || static_cast<size_t>(position) >= scenes.size())
			return;
		OBSSource item = *from;
		scenes.erase(from);
		scenes.insert(scenes.begin() + position, item);
		obs_frontend_save();
		on_event(OBS_FRONTEND_EVENT_SCENE_LIST_CHANGED);
	}

	const fs::path configurationPath(bool isProfile, const char *name = nullptr)
	{
		std::lock_guard lock(stateMutex);
		return isProfile ? profilePath(name ? name : profile.c_str()) : collectionPath(name ? name : collection.c_str());
	}

	bool renameConfiguration(bool isProfile, const char *name)
	{
		std::lock_guard lock(stateMutex);
		if (!validName(name) || isOutputActive())
			return false;
		std::error_code error;
		auto oldPath = configurationPath(isProfile);
		auto newPath = configurationPath(isProfile, name);
		if (fs::exists(newPath, error))
			return false;
		obs_frontend_save();
		fs::rename(oldPath, newPath, error);
		if (error)
			return false;
		if (isProfile) {
			profileConfigs.erase(name);
			if (!openProfile(name)) {
				fs::rename(newPath, oldPath, error);
				return false;
			}
			config_set_string(profileConfig(), "General", "Name", name);
		} else {
			collection = name;
		}
		obs_frontend_save();
		on_event(isProfile ? OBS_FRONTEND_EVENT_PROFILE_LIST_CHANGED : OBS_FRONTEND_EVENT_SCENE_COLLECTION_LIST_CHANGED);
		return true;
	}

	bool deleteConfiguration(bool isProfile, const char *name)
	{
		std::lock_guard lock(stateMutex);
		if (!validName(name) || isOutputActive())
			return false;
		std::string removed = name;
		const auto &current = isProfile ? profile : collection;
		if (removed == current) {
			std::vector<std::string> names;
			if (isProfile)
				obs_frontend_get_profiles(names);
			else
				obs_frontend_get_scene_collections(names);
			auto next = std::find_if(names.begin(), names.end(), [&](const auto &item) { return item != removed; });
			if (next == names.end())
				return false;
			if (isProfile)
				obs_frontend_set_current_profile(next->c_str());
			else
				obs_frontend_set_current_scene_collection(next->c_str());
			if (removed == current)
				return false;
		}
		std::error_code error;
		if (fs::remove_all(configurationPath(isProfile, removed.c_str()), error) == 0 || error)
			return false;
		if (isProfile)
			profileConfigs.erase(removed);
		on_event(isProfile ? OBS_FRONTEND_EVENT_PROFILE_LIST_CHANGED : OBS_FRONTEND_EVENT_SCENE_COLLECTION_LIST_CHANGED);
		return true;
	}

	bool importConfiguration(bool isProfile, const char *path, const char *name)
	{
		std::lock_guard lock(stateMutex);
		if (!validName(name) || !path || !*path || isOutputActive())
			return false;
		auto target = configurationPath(isProfile, name);
		std::error_code error;
		if (fs::exists(target, error))
			return false;
		if (isProfile) {
			const fs::path source(path);
			if (!fs::is_regular_file(source / "basic.ini", error) || !fs::create_directory(target, error))
				return false;
			for (const char *file : {"basic.ini", "service.json", "streamEncoder.json", "recordEncoder.json"}) {
				if (fs::is_regular_file(source / file, error)) {
					fs::copy_file(source / file, target / file, error);
					if (error) {
						fs::remove_all(target, error);
						return false;
					}
				}
			}
			obs_frontend_set_current_profile(name);
			config_set_string(profileConfig(), "General", "Name", name);
		} else {
			OBSDataAutoRelease data = obs_data_create_from_json_file(path);
			OBSDataArrayAutoRelease items = obs_data_get_array(data, "sources");
			if (!items)
				return false;
			obs_data_set_string(data, "name", name);
			if (!obs_data_save_json_safe(data, target.c_str(), "tmp", "bak"))
				return false;
			obs_frontend_set_current_scene_collection(name);
		}
		obs_frontend_save();
		on_event(isProfile ? OBS_FRONTEND_EVENT_PROFILE_LIST_CHANGED : OBS_FRONTEND_EVENT_SCENE_COLLECTION_LIST_CHANGED);
		return true;
	}

	void *obs_frontend_get_main_window() override { return nullptr; }
	void *obs_frontend_get_main_window_handle() override { return nullptr; }
	void *obs_frontend_get_system_tray() override { return nullptr; }
	void obs_frontend_get_scenes(obs_frontend_source_list *list) override
	{
		std::lock_guard lock(stateMutex);
		appendSources(list, scenes);
	}
	obs_source_t *obs_frontend_get_current_scene() override
	{
		std::lock_guard lock(stateMutex);
		return obs_source_get_ref(program);
	}
	void obs_frontend_set_current_scene(obs_source_t *scene) override
	{
		std::lock_guard lock(stateMutex);
		if (!obs_scene_from_source(scene) || program == scene)
			return;
		auto chosen = transition;
		int milliseconds = duration;
		OBSDataAutoRelease settings = obs_source_get_private_settings(scene);
		const char *overrideName = obs_data_get_string(settings, "transition");
		if (overrideName && *overrideName) {
			for (const auto &candidate : transitions) {
				if (strcmp(obs_source_get_name(candidate), overrideName) == 0) {
					chosen = candidate;
					const int value = (int)obs_data_get_int(settings, "transition_duration");
					if (value > 0)
						milliseconds = value;
					break;
				}
			}
		}
		if (chosen) {
			OBSSourceAutoRelease output = obs_get_output_source(0);
			if (output != chosen) {
				obs_transition_set(chosen, program);
				obs_set_output_source(0, chosen);
			}
			if (!obs_transition_start(chosen, OBS_TRANSITION_MODE_AUTO, milliseconds, scene))
				obs_transition_set(chosen, scene);
		} else {
			obs_set_output_source(0, scene);
		}
		program = scene;
		if (!studio)
			preview = scene;
		obs_frontend_save();
		on_event(OBS_FRONTEND_EVENT_SCENE_CHANGED);
	}
	void obs_frontend_get_transitions(obs_frontend_source_list *list) override
	{
		std::lock_guard lock(stateMutex);
		appendSources(list, transitions);
	}
	obs_source_t *obs_frontend_get_current_transition() override
	{
		std::lock_guard lock(stateMutex);
		return obs_source_get_ref(transition);
	}
	void obs_frontend_set_current_transition(obs_source_t *source) override
	{
		std::lock_guard lock(stateMutex);
		if (!source || obs_source_get_type(source) != OBS_SOURCE_TYPE_TRANSITION || transition == source)
			return;
		obs_transition_set(source, program);
		transition = source;
		obs_set_output_source(0, source);
		obs_frontend_save();
		on_event(OBS_FRONTEND_EVENT_TRANSITION_CHANGED);
	}
	int obs_frontend_get_transition_duration() override { std::lock_guard lock(stateMutex); return duration; }
	void obs_frontend_set_transition_duration(int value) override
	{
		std::lock_guard lock(stateMutex);
		duration = std::max(0, value);
		obs_frontend_save();
		on_event(OBS_FRONTEND_EVENT_TRANSITION_DURATION_CHANGED);
	}
	int obs_frontend_get_tbar_position() override { std::lock_guard lock(stateMutex); return tbarPosition; }
	void obs_frontend_set_tbar_position(int value) override
	{
		std::lock_guard lock(stateMutex);
		if (!studio || !transition || program == preview)
			return;
		if (tbarPosition == 0)
		{
			obs_transition_set(transition, program);
			obs_set_output_source(0, transition);
			obs_transition_start(transition, OBS_TRANSITION_MODE_MANUAL, duration, preview);
		}
		tbarPosition = std::clamp(value, 0, 1024);
		obs_transition_set_manual_time(transition, tbarPosition / 1024.0f);
		on_event(OBS_FRONTEND_EVENT_TBAR_VALUE_CHANGED);
	}
	void obs_frontend_release_tbar() override
	{
		std::lock_guard lock(stateMutex);
		if (tbarPosition != 0 && transition) {
			if (tbarPosition >= 512)
				program = preview;
			obs_transition_set(transition, program);
			tbarPosition = 0;
			obs_frontend_save();
			on_event(OBS_FRONTEND_EVENT_SCENE_CHANGED);
			on_event(OBS_FRONTEND_EVENT_TBAR_VALUE_CHANGED);
		}
	}

	void obs_frontend_get_scene_collections(std::vector<std::string> &names) override
	{
		std::error_code error;
		for (const auto &entry : fs::directory_iterator(root / "basic/scenes", error)) {
			if (entry.path().extension() == ".json")
				names.push_back(entry.path().stem().string());
		}
		std::sort(names.begin(), names.end());
	}
	char *obs_frontend_get_current_scene_collection() override
	{
		std::lock_guard lock(stateMutex);
		return bstrdup(collection.c_str());
	}
	void obs_frontend_set_current_scene_collection(const char *name) override
	{
		std::lock_guard lock(stateMutex);
		if (!validName(name) || collection == name || isOutputActive())
			return;
		std::error_code error;
		if (!fs::is_regular_file(collectionPath(name), error))
			return;
		obs_frontend_save();
		on_event(OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING);
		obs_set_output_source(0, nullptr);
		for (auto &scene : scenes)
			obs_source_remove(scene);
		for (auto &source : sources)
			obs_source_remove(source);
		program = nullptr;
		preview = nullptr;
		copiedItem = nullptr;
		transition = nullptr;
		undoActions.clear();
		undoPosition = 0;
		scenes.clear();
		sources.clear();
		transitions.clear();
		on_event(OBS_FRONTEND_EVENT_SCENE_COLLECTION_CLEANUP);
		collection = name;
		loadCollection();
		obs_frontend_save();
		on_event(OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED);
		on_event(OBS_FRONTEND_EVENT_SCENE_LIST_CHANGED);
	}
	bool obs_frontend_add_scene_collection(const char *name) override
	{
		std::lock_guard lock(stateMutex);
		std::error_code error;
		if (!validName(name) || fs::exists(collectionPath(name), error))
			return false;
		OBSDataAutoRelease settings = obs_data_create();
		obs_data_set_string(settings, "name", name);
		if (!obs_data_save_json_safe(settings, collectionPath(name).c_str(), "tmp", "bak"))
			return false;
		obs_frontend_set_current_scene_collection(name);
		on_event(OBS_FRONTEND_EVENT_SCENE_COLLECTION_LIST_CHANGED);
		return true;
	}
	void obs_frontend_get_profiles(std::vector<std::string> &names) override
	{
		std::error_code error;
		for (const auto &entry : fs::directory_iterator(root / "basic/profiles", error)) {
			if (entry.is_directory(error))
				names.push_back(entry.path().filename().string());
		}
		std::sort(names.begin(), names.end());
	}
	char *obs_frontend_get_current_profile() override { std::lock_guard lock(stateMutex); return bstrdup(profile.c_str()); }
	char *obs_frontend_get_current_profile_path() override
	{
		std::lock_guard lock(stateMutex);
		return bstrdup(profilePath(profile).c_str());
	}
	void obs_frontend_set_current_profile(const char *name) override
	{
		std::lock_guard lock(stateMutex);
		std::error_code error;
		if (!validName(name) || profile == name || isOutputActive() || !fs::is_directory(profilePath(name), error))
			return;
		obs_frontend_save();
		on_event(OBS_FRONTEND_EVENT_PROFILE_CHANGING);
		if (openProfile(name)) {
			loadService();
			loadHotkeys();
			resetAudio();
			applyMicInputs();
			obs_frontend_reset_video();
			obs_frontend_save();
			on_event(OBS_FRONTEND_EVENT_PROFILE_CHANGED);
		}
	}
	void obs_frontend_create_profile(const char *name) override
	{
		std::lock_guard lock(stateMutex);
		std::error_code error;
		if (!validName(name) || isOutputActive() || !fs::create_directory(profilePath(name), error))
			return;
		obs_frontend_set_current_profile(name);
		on_event(OBS_FRONTEND_EVENT_PROFILE_LIST_CHANGED);
	}
	void obs_frontend_duplicate_profile(const char *name) override
	{
		std::lock_guard lock(stateMutex);
		std::error_code error;
		if (!validName(name) || isOutputActive() || fs::exists(profilePath(name), error))
			return;
		obs_frontend_save();
		fs::copy(profilePath(profile), profilePath(name), fs::copy_options::recursive, error);
		if (!error) {
			obs_frontend_set_current_profile(name);
			config_set_string(profileConfig(), "General", "Name", name);
			obs_frontend_save();
			on_event(OBS_FRONTEND_EVENT_PROFILE_LIST_CHANGED);
		}
	}
	void obs_frontend_delete_profile(const char *name) override
	{
		std::lock_guard lock(stateMutex);
		std::error_code error;
		if (validName(name) && profile != name && fs::remove_all(profilePath(name), error) > 0 && !error)
			on_event(OBS_FRONTEND_EVENT_PROFILE_LIST_CHANGED);
	}

	void obs_frontend_streaming_start() override { startOutput(Stream); }
	void obs_frontend_streaming_stop() override
	{
		std::lock_guard lock(stateMutex);
		stopOutput(Stream);
		if (config_get_bool(user.get(), "BasicWindow", "RecordWhenStreaming") &&
		    !config_get_bool(user.get(), "BasicWindow", "KeepRecordingWhenStreamStops"))
			stopOutput(Recording);
		if (config_get_bool(user.get(), "BasicWindow", "ReplayBufferWhileStreaming") &&
		    !config_get_bool(user.get(), "BasicWindow", "KeepReplayBufferStreamStops"))
			stopOutput(Replay);
	}
	bool obs_frontend_streaming_active() override { return active(Stream); }
	void obs_frontend_recording_start() override { startOutput(Recording); }
	void obs_frontend_recording_stop() override { stopOutput(Recording); }
	bool obs_frontend_recording_active() override { return active(Recording); }
	void obs_frontend_recording_pause(bool pause) override
	{
		OBSOutputAutoRelease output = getOutput(Recording);
		if (output && obs_output_pause(output, pause))
			on_event(pause ? OBS_FRONTEND_EVENT_RECORDING_PAUSED : OBS_FRONTEND_EVENT_RECORDING_UNPAUSED);
	}
	bool obs_frontend_recording_paused() override
	{
		OBSOutputAutoRelease output = getOutput(Recording);
		return output && obs_output_paused(output);
	}
	bool obs_frontend_recording_split_file() override { return outputProc(Recording, "split_file"); }
	bool obs_frontend_recording_add_chapter(const char *name) override
	{
		OBSOutputAutoRelease output = getOutput(Recording);
		if (!output)
			return false;
		calldata_t data = {};
		calldata_set_string(&data, "chapter_name", name);
		bool result = proc_handler_call(obs_output_get_proc_handler(output), "add_chapter", &data);
		calldata_free(&data);
		return result;
	}
	bool outputProc(Slot slot, const char *name)
	{
		OBSOutputAutoRelease output = getOutput(slot);
		if (!output)
			return false;
		calldata_t data = {};
		bool result = proc_handler_call(obs_output_get_proc_handler(output), name, &data);
		calldata_free(&data);
		return result;
	}
	void obs_frontend_replay_buffer_start() override { startOutput(Replay); }
	void obs_frontend_replay_buffer_save() override { outputProc(Replay, "save"); }
	void obs_frontend_replay_buffer_stop() override { stopOutput(Replay); }
	bool obs_frontend_replay_buffer_active() override { return active(Replay); }
	obs_output_t *obs_frontend_get_streaming_output() override { return getOutput(Stream); }
	obs_output_t *obs_frontend_get_recording_output() override { return getOutput(Recording); }
	obs_output_t *obs_frontend_get_replay_buffer_output() override { return getOutput(Replay); }

	void *obs_frontend_add_tools_menu_qaction(const char *) override { return nullptr; }
	void obs_frontend_add_tools_menu_item(const char *, obs_frontend_cb, void *) override {}
	bool obs_frontend_add_dock_by_id(const char *, const char *, void *) override { return false; }
	void obs_frontend_remove_dock(const char *) override {}
	bool obs_frontend_add_custom_qdock(const char *, void *) override { return false; }

	void obs_frontend_add_event_callback(obs_frontend_event_cb callback, void *data) override
	{
		std::lock_guard lock(callbackMutex);
		Event registration{callback, data};
		if (std::find(events.begin(), events.end(), registration) == events.end())
			events.push_back(registration);
	}
	void obs_frontend_remove_event_callback(obs_frontend_event_cb callback, void *data) override
	{
		std::lock_guard lock(callbackMutex);
		events.erase(std::remove(events.begin(), events.end(), Event{callback, data}), events.end());
	}
	void on_event(obs_frontend_event event) override
	{
		std::vector<Event> listeners;
		{
			std::lock_guard lock(callbackMutex);
			listeners = events;
		}
		for (auto [callback, data] : listeners)
			callback(event, data);
		uiMessage(@"Event", @{@"event": @(event)});
	}

	config_t *obs_frontend_get_profile_config() override { std::lock_guard lock(stateMutex); return profileConfig(); }
	config_t *obs_frontend_get_app_config() override { return app.get(); }
	config_t *obs_frontend_get_user_config() override { return user.get(); }
	void obs_frontend_open_projector(const char *type, int monitor, const char *geometry, const char *name) override
	{
		uiMessage(@"Projector", @{@"type": @(type ?: ""), @"monitor": @(monitor),
					  @"geometry": @(geometry ?: ""), @"name": @(name ?: "")});
	}
	void obs_frontend_save() override
	{
		std::lock_guard lock(stateMutex);
		if (deferSave || scenes.empty())
			return;
		config_set_string(user.get(), "Basic", "Profile", profile.c_str());
		config_set_string(user.get(), "Basic", "ProfileDir", profile.c_str());
		config_set_string(user.get(), "Basic", "SceneCollection", collection.c_str());
		config_set_string(user.get(), "Basic", "SceneCollectionFile", collection.c_str());
		config_save_safe(user.get(), "tmp", "bak");
		config_save_safe(profileConfig(), "tmp", "bak");
		OBSDataAutoRelease data = obs_data_create();
		OBSDataArrayAutoRelease serialized = obs_save_sources();
		OBSDataArrayAutoRelease order = obs_data_array_create();
		OBSDataArrayAutoRelease transitionData = obs_data_array_create();
		for (const auto &scene : scenes) {
			OBSDataAutoRelease entry = obs_data_create();
			obs_data_set_string(entry, "name", obs_source_get_name(scene));
			obs_data_array_push_back(order, entry);
		}
		for (const auto &item : transitions) {
			OBSDataAutoRelease entry = obs_save_source(item);
			obs_data_array_push_back(transitionData, entry);
		}
		obs_data_set_string(data, "name", collection.c_str());
		obs_data_set_string(data, "current_program_scene", obs_source_get_name(program));
		obs_data_set_string(data, "current_scene", obs_source_get_name(preview));
		if (transition)
			obs_data_set_string(data, "current_transition", obs_source_get_name(transition));
		obs_data_set_int(data, "transition_duration", duration);
		obs_data_set_array(data, "sources", serialized);
		obs_data_set_array(data, "scene_order", order);
		obs_data_set_array(data, "transitions", transitionData);
		OBSDataAutoRelease moduleData = obs_data_create();
		on_save(moduleData);
		obs_data_set_obj(data, "modules", moduleData);
		obs_data_save_json_safe(data, collectionPath(collection).c_str(), "tmp", "bak");
	}
	void obs_frontend_defer_save_begin() override { std::lock_guard lock(stateMutex); ++deferSave; }
	void obs_frontend_defer_save_end() override
	{
		std::lock_guard lock(stateMutex);
		if (deferSave > 0 && --deferSave == 0)
			obs_frontend_save();
	}
	void obs_frontend_add_save_callback(obs_frontend_save_cb callback, void *data) override
	{
		std::lock_guard lock(stateMutex);
		saveCallbacks.emplace_back(callback, data);
	}
	void obs_frontend_remove_save_callback(obs_frontend_save_cb callback, void *data) override
	{
		std::lock_guard lock(stateMutex);
		saveCallbacks.erase(std::remove(saveCallbacks.begin(), saveCallbacks.end(), SaveCallback{callback, data}),
				    saveCallbacks.end());
	}
	void obs_frontend_add_preload_callback(obs_frontend_save_cb callback, void *data) override
	{
		std::lock_guard lock(stateMutex);
		preloadCallbacks.emplace_back(callback, data);
	}
	void obs_frontend_remove_preload_callback(obs_frontend_save_cb callback, void *data) override
	{
		std::lock_guard lock(stateMutex);
		preloadCallbacks.erase(std::remove(preloadCallbacks.begin(), preloadCallbacks.end(), SaveCallback{callback, data}),
				       preloadCallbacks.end());
	}
	void on_load(obs_data_t *settings) override { for (auto [callback, data] : saveCallbacks) callback(settings, false, data); }
	void on_preload(obs_data_t *settings) override { for (auto [callback, data] : preloadCallbacks) callback(settings, false, data); }
	void on_save(obs_data_t *settings) override { for (auto [callback, data] : saveCallbacks) callback(settings, true, data); }

	void obs_frontend_push_ui_translation(obs_frontend_translate_ui_cb translation) override
	{
		std::lock_guard lock(stateMutex);
		extraTranslations.push_back(translation);
	}
	void obs_frontend_pop_ui_translation() override
	{
		std::lock_guard lock(stateMutex);
		if (!extraTranslations.empty())
			extraTranslations.pop_back();
	}
	const char *obs_frontend_get_locale_string(const char *key) override
	{
		std::lock_guard lock(stateMutex);
		const char *translated = key;
		for (auto lookup = extraTranslations.rbegin(); lookup != extraTranslations.rend(); ++lookup) {
			if ((*lookup)(key, &translated))
				return translated;
		}
		if (translations)
			text_lookup_getstr(translations.get(), key, &translated);
		return translated;
	}

	obs_service_t *obs_frontend_get_streaming_service() override
	{
		std::lock_guard lock(stateMutex);
		return obs_service_get_ref(service);
	}
	void obs_frontend_set_streaming_service(obs_service_t *value) override
	{
		std::lock_guard lock(stateMutex);
		service = value;
	}
	void obs_frontend_save_streaming_service() override
	{
		std::lock_guard lock(stateMutex);
		if (!service)
			return;
		OBSDataAutoRelease data = obs_data_create();
		OBSDataAutoRelease settings = obs_service_get_settings(service);
		obs_data_set_string(data, "type", obs_service_get_type(service));
		obs_data_set_obj(data, "settings", settings);
		obs_data_save_json_safe(data, (profilePath(profile) / "service.json").c_str(), "tmp", "bak");
	}

	bool obs_frontend_preview_program_mode_active() override { std::lock_guard lock(stateMutex); return studio; }
	void obs_frontend_set_preview_program_mode(bool enable) override
	{
		std::lock_guard lock(stateMutex);
		if (studio != enable) {
			studio = enable;
			preview = program;
			on_event(enable ? OBS_FRONTEND_EVENT_STUDIO_MODE_ENABLED : OBS_FRONTEND_EVENT_STUDIO_MODE_DISABLED);
		}
	}
	void obs_frontend_preview_program_trigger_transition() override
	{
		std::lock_guard lock(stateMutex);
		if (studio && preview)
			obs_frontend_set_current_scene(preview);
	}
	bool obs_frontend_preview_enabled() override { std::lock_guard lock(stateMutex); return previewEnabled; }
	void obs_frontend_set_preview_enabled(bool enable) override
	{
		std::lock_guard lock(stateMutex);
		previewEnabled = enable;
		uiMessage(@"PreviewEnabled");
	}
	obs_source_t *obs_frontend_get_current_preview_scene() override
	{
		std::lock_guard lock(stateMutex);
		return studio ? obs_source_get_ref(preview) : nullptr;
	}
	void obs_frontend_set_current_preview_scene(obs_source_t *scene) override
	{
		std::lock_guard lock(stateMutex);
		if (obs_scene_from_source(scene)) {
			preview = scene;
			on_event(OBS_FRONTEND_EVENT_PREVIEW_SCENE_CHANGED);
		}
	}

	void obs_frontend_take_screenshot() override { uiMessage(@"Screenshot"); }
	void obs_frontend_take_source_screenshot(obs_source_t *source) override { sendSourceAction(@"Screenshot", source); }
	obs_output_t *obs_frontend_get_virtualcam_output() override { return nullptr; }
	void obs_frontend_start_virtualcam() override {}
	void obs_frontend_stop_virtualcam() override {}
	bool obs_frontend_virtualcam_active() override { return false; }
	void obs_frontend_reset_video() override
	{
		std::lock_guard lock(stateMutex);
		if (isOutputActive())
			return;
		obs_video_info video = {};
		if (!obs_get_video_info(&video))
			return;
		config_t *config = profileConfig();
		video.base_width = (uint32_t)config_get_uint(config, "Video", "BaseCX");
		video.base_height = (uint32_t)config_get_uint(config, "Video", "BaseCY");
		video.output_width = (uint32_t)config_get_uint(config, "Video", "OutputCX");
		video.output_height = (uint32_t)config_get_uint(config, "Video", "OutputCY");
		const char *format = config_get_string(config, "Video", "ColorFormat");
		const std::pair<const char *, video_format> formats[] = {
			{"NV12", VIDEO_FORMAT_NV12}, {"I420", VIDEO_FORMAT_I420}, {"I444", VIDEO_FORMAT_I444},
			{"P010", VIDEO_FORMAT_P010}, {"I010", VIDEO_FORMAT_I010}, {"P216", VIDEO_FORMAT_P216},
			{"P416", VIDEO_FORMAT_P416}, {"BGRA", VIDEO_FORMAT_BGRA}};
		for (const auto &[name, value] : formats)
			if (strcmp(format, name) == 0)
				video.output_format = value;
		const char *space = config_get_string(config, "Video", "ColorSpace");
		video.colorspace = strcmp(space, "2100PQ") == 0 ? VIDEO_CS_2100_PQ :
					   strcmp(space, "2100HLG") == 0 ? VIDEO_CS_2100_HLG :
					   strcmp(space, "601") == 0 ? VIDEO_CS_601 :
					   strcmp(space, "sRGB") == 0 ? VIDEO_CS_SRGB : VIDEO_CS_709;
		video.range = strcmp(config_get_string(config, "Video", "ColorRange"), "Full") == 0 ? VIDEO_RANGE_FULL : VIDEO_RANGE_PARTIAL;
		const auto fpsType = config_get_uint(config, "Video", "FPSType");
		if (fpsType == 1) {
			video.fps_num = (uint32_t)config_get_uint(config, "Video", "FPSInt");
			video.fps_den = 1;
		} else if (fpsType == 2) {
			video.fps_num = (uint32_t)config_get_uint(config, "Video", "FPSNum");
			video.fps_den = (uint32_t)config_get_uint(config, "Video", "FPSDen");
		} else {
			const double fps = strtod(config_get_string(config, "Video", "FPSCommon"), nullptr);
			video.fps_den = fps == 23.976 || fps == 29.97 || fps == 59.94 ? 1001 : 1;
			video.fps_num = (uint32_t)round(std::max(fps, 1.0) * video.fps_den);
		}
		const char *scale = config_get_string(config, "Video", "ScaleType");
		video.scale_type = strcmp(scale, "bilinear") == 0 ? OBS_SCALE_BILINEAR :
				   strcmp(scale, "lanczos") == 0 ? OBS_SCALE_LANCZOS :
				   strcmp(scale, "area") == 0 ? OBS_SCALE_AREA : OBS_SCALE_BICUBIC;
		obs_set_video_levels((float)config_get_uint(config, "Video", "SdrWhiteLevel"),
				     (float)config_get_uint(config, "Video", "HdrNominalPeakLevel"));
		obs_reset_video(&video);
	}
	void obs_frontend_open_source_properties(obs_source_t *source) override { sendSourceAction(@"Properties", source); }
	void obs_frontend_open_source_filters(obs_source_t *source) override { sendSourceAction(@"Filters", source); }
	void obs_frontend_open_source_interaction(obs_source_t *source) override { sendSourceAction(@"Interaction", source); }
	void obs_frontend_open_sceneitem_edit_transform(obs_sceneitem_t *item) override
	{
		if (item)
			uiMessage(@"Transform", @{@"item": @(obs_sceneitem_get_id(item))});
	}
	char *obs_frontend_get_current_record_output_path() override
	{
		std::lock_guard lock(stateMutex);
		return bstrdup(configuredRecordingDirectory().c_str());
	}
	bool obs_frontend_is_theme_dark() override { return true; }
	char *obs_frontend_get_last_recording() override { std::lock_guard lock(stateMutex); return bstrdup(recordingPath.c_str()); }
	char *obs_frontend_get_last_screenshot() override { std::lock_guard lock(stateMutex); return bstrdup(screenshotPath.c_str()); }
	char *obs_frontend_get_last_replay() override
	{
		OBSOutputAutoRelease output = getOutput(Replay);
		if (!output)
			return nullptr;
		calldata_t data = {};
		proc_handler_call(obs_output_get_proc_handler(output), "get_last_replay", &data);
		char *path = bstrdup(calldata_string(&data, "path"));
		calldata_free(&data);
		return path;
	}
	void obs_frontend_add_undo_redo_action(const char *name, undo_redo_cb undo, undo_redo_cb redo,
					      const char *before, const char *after, bool repeatable) override
	{
		std::lock_guard lock(stateMutex);
		if (!undo || !redo || !before || !after || strcmp(before, after) == 0)
			return;
		undoActions.resize(undoPosition);
		if (repeatable && !undoActions.empty() && undoActions.back().name == name) {
			undoActions.back().after = after;
		} else {
			undoActions.push_back({name, before, after, undo, redo});
			if (undoActions.size() > 100)
				undoActions.erase(undoActions.begin());
		}
		undoPosition = undoActions.size();
	}
	bool canUndo(bool redo)
	{
		std::lock_guard lock(stateMutex);
		return redo ? undoPosition < undoActions.size() : undoPosition > 0;
	}
	void undo(bool redo)
	{
		std::lock_guard lock(stateMutex);
		if (!canUndo(redo))
			return;
		const auto action = undoActions[redo ? undoPosition++ : --undoPosition];
		if (redo)
			action.redo(action.after.c_str());
		else
			action.undo(action.before.c_str());
		obs_frontend_save();
	}
	obs_canvas_t *obs_frontend_add_canvas(const char *name, obs_video_info *video, int flags) override
	{
		std::lock_guard lock(stateMutex);
		OBSCanvasAutoRelease canvas = obs_canvas_create(name, video, flags);
		if (canvas) {
			canvases.emplace_back(canvas.Get());
			on_event(OBS_FRONTEND_EVENT_CANVAS_ADDED);
		}
		return obs_canvas_get_ref(canvas);
	}
	bool obs_frontend_remove_canvas(obs_canvas_t *canvas) override
	{
		std::lock_guard lock(stateMutex);
		auto item = std::find_if(canvases.begin(), canvases.end(), [canvas](const auto &entry) { return entry == canvas; });
		if (item == canvases.end())
			return false;
		obs_canvas_remove(canvas);
		canvases.erase(item);
		on_event(OBS_FRONTEND_EVENT_CANVAS_REMOVED);
		return true;
	}
	void obs_frontend_get_canvases(obs_frontend_canvas_list *list) override
	{
		obs_enum_canvases([](void *data, obs_canvas_t *canvas) {
			auto *list = static_cast<obs_frontend_canvas_list *>(data);
			obs_canvas_t *reference = obs_canvas_get_ref(canvas);
			da_push_back(list->canvases, &reference);
			return true;
		}, list);
	}
	void obs_frontend_copy_sceneitem(obs_sceneitem_t *item) override { std::lock_guard lock(stateMutex); copiedItem = item; }
	bool obs_frontend_can_paste_sceneitem(bool) override { std::lock_guard lock(stateMutex); return copiedItem != nullptr; }
	void obs_frontend_paste_sceneitem(obs_scene_t *scene, bool duplicate) override
	{
		std::lock_guard lock(stateMutex);
		if (!copiedItem || !scene)
			return;
		obs_source_t *source = obs_sceneitem_get_source(copiedItem);
		OBSSourceAutoRelease copy = duplicate ? obs_source_duplicate(source, obs_source_get_name(source), false) : nullptr;
		obs_sceneitem_t *item = obs_scene_add(scene, copy ? copy.Get() : source);
		if (item) {
			obs_transform_info transform;
			obs_sceneitem_crop crop;
			obs_sceneitem_get_info2(copiedItem, &transform);
			obs_sceneitem_get_crop(copiedItem, &crop);
			obs_sceneitem_set_info2(item, &transform);
			obs_sceneitem_set_crop(item, &crop);
			obs_frontend_save();
		}
	}
	bool obs_frontend_is_safe_mode_enabled() override { return false; }
};

IOSFrontend *frontend;

} // namespace

bool obs_app_frontend_open(const char *directory, const char *locale)
{
	auto host = std::make_unique<IOSFrontend>(directory, locale);
	if (!host->valid())
		return false;
	frontend = host.release();
	obs_frontend_set_callbacks_internal(frontend);
	obs_set_ui_task_handler(queueUiTask);
	return true;
}

void obs_app_frontend_ready(void)
{
	frontend->ready();
	obs_post_load_modules();
	frontend->on_event(OBS_FRONTEND_EVENT_FINISHED_LOADING);
	blog(LOG_INFO, "OBS iOS frontend ready");
}

void obs_app_frontend_close(void)
{
	obs_frontend_set_callbacks_internal(nullptr);
	frontend = nullptr;
}
void obs_app_frontend_release_sources(void) { frontend->releaseSources(); }

obs_source_t *obs_app_create_scene(const char *name) { return frontend->addScene(name); }
void obs_app_remove_scene(obs_source_t *scene) { frontend->removeScene(scene); }
void obs_app_move_scene(obs_source_t *scene, int position) { frontend->moveScene(scene, position); }
void obs_app_frontend_reload_locale(const char *locale) { frontend->reloadLocale(locale); }
void obs_app_frontend_apply_audio(void) { frontend->applyAudio(); }
void obs_app_check_recording_capacity(void) { frontend->checkRecordingCapacity(); }
bool obs_app_can_undo(bool redo) { return frontend->canUndo(redo); }
void obs_app_undo(bool redo) { frontend->undo(redo); }
void obs_app_quick_transition(obs_source_t *transition) { frontend->quickTransition(transition); }
bool obs_app_rename_configuration(bool profile, const char *name) { return frontend->renameConfiguration(profile, name); }
bool obs_app_delete_configuration(bool profile, const char *name) { return frontend->deleteConfiguration(profile, name); }
bool obs_app_duplicate_collection(const char *name)
{
	obs_frontend_save();
	return frontend->importConfiguration(false, frontend->configurationPath(false).c_str(), name);
}
bool obs_app_import_configuration(bool profile, const char *path, const char *name)
{
	return frontend->importConfiguration(profile, path, name);
}
char *obs_app_configuration_path(bool profile) { return bstrdup(frontend->configurationPath(profile).c_str()); }

/* The desktop scene undo saves dependent sources followed by the scene, then
 * restores all settings before resolving scene items in a second pass. */
static void snapshot_source(obs_source_t *source, obs_data_array_t *array);

static bool snapshot_item(obs_scene_t *, obs_sceneitem_t *item, void *data)
{
	auto *array = static_cast<obs_data_array_t *>(data);
	snapshot_source(obs_sceneitem_get_source(item), array);
	return true;
}

static void snapshot_source(obs_source_t *source, obs_data_array_t *array)
{
	if (auto *scene = obs_group_from_source(source))
		obs_scene_enum_items(scene, snapshot_item, array);
	OBSDataAutoRelease saved = obs_save_source(source);
	obs_data_array_push_back(array, saved);
}

obs_data_t *obs_app_snapshot_scene(obs_source_t *source)
{
	auto *scene = obs_scene_from_source(source);
	if (!scene)
		return nullptr;
	OBSDataArrayAutoRelease items = obs_data_array_create();
	obs_scene_enum_items(scene, snapshot_item, items);
	snapshot_source(source, items);
	auto *data = obs_data_create();
	obs_data_set_array(data, "array", items);
	return data;
}

void obs_app_restore_scene(const char *json)
{
	OBSDataAutoRelease data = obs_data_create_from_json(json);
	OBSDataArrayAutoRelease entries = obs_data_get_array(data, "array");
	std::vector<OBSSource> loaded, existing;
	for (size_t index = 0; index < obs_data_array_count(entries); index++) {
		OBSDataAutoRelease saved = obs_data_array_item(entries, index);
		OBSSourceAutoRelease source = obs_get_source_by_uuid(obs_data_get_string(saved, "uuid"));
		if (!source)
			source = obs_load_source(saved);
		if (!source)
			continue;
		loaded.emplace_back(source.Get());
		obs_source_set_name(source, obs_data_get_string(saved, "name"));
		if (auto *scene = obs_group_or_scene_from_source(source)) {
			obs_scene_enum_items(scene, [](obs_scene_t *, obs_sceneitem_t *item, void *data) {
				static_cast<std::vector<OBSSource> *>(data)->emplace_back(obs_sceneitem_get_source(item));
				return true;
			}, &existing);
			OBSDataAutoRelease settings = obs_data_get_obj(saved, "settings");
			obs_source_update(source, settings);
		}
	}
	for (auto &source : loaded)
		obs_source_load2(source);
}
