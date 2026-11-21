/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 自研必要性证明：OBSBasicSettings 使用 Qt 表单；这里采用相同的词条、配置
 * 字段、服务和编码器元数据，在 iOS 上提供原生设置窗口。 */

import AVFAudio
import SwiftUI

struct OBSSettingsView: View {
    @EnvironmentObject private var locale: OBSLocale
    @State private var tab = Tab.general
    @State private var outputTab = OutputTab.streaming
    @State private var generation = 0
    @State private var serviceType = ""
    @State private var serviceEditor: OBSPropertyEditor?

    private enum Tab: String, CaseIterable {
        case general = "General", stream = "Stream", output = "Output", audio = "Audio"
        case video = "Video", hotkeys = "Hotkeys", advanced = "Advanced"
    }

    private enum OutputTab: String, CaseIterable {
        case streaming = "Streaming", recording = "Recording", audio = "Audio", replay = "ReplayBuffer"
    }

    private var profile: OpaquePointer? { obs_frontend_get_profile_config() }
    private var user: OpaquePointer? { obs_frontend_get_user_config() }
    private var active: Bool {
        obs_frontend_streaming_active() || obs_frontend_recording_active() || obs_frontend_replay_buffer_active()
    }
    private var advanced: Bool { configText(profile, "Output", "Mode") == "Advanced" }
    private var outputSection: String { advanced ? "AdvOut" : "SimpleOutput" }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Tab.allCases, id: \.self) { option in
                        Button(label(option.rawValue)) { tab = option }
                            .fontWeight(option == tab ? .semibold : .regular)
                            .foregroundStyle(option == tab ? Color.accentColor : Color.primary)
                            .accessibilityAddTraits(option == tab ? .isSelected : [])
                    }
                }.padding(.horizontal).padding(.vertical, 10)
            }
            Form {
                switch tab {
                case .general: general
                case .stream: stream
                case .output: output
                case .audio: audio
                case .video: video
                case .hotkeys: OBSHotkeySettings()
                case .advanced: advancedSettings
                }
            }
            .id(tab)
        }
        .navigationTitle(OBSLocale.str("Settings"))
        .onAppear {
            let service = obs_frontend_get_streaming_service()
            defer { obs_service_release(service) }
            if let service, let type = obs_service_get_type(service) {
                serviceType = String(cString: type)
                openService(serviceType, current: service)
            }
        }
    }

    private var general: some View {
        Section(label("General")) {
            Picker(label("General.Language"), selection: $locale.selection) {
                Text(OBSLocale.str("Default")).tag("")
                ForEach(OBSLocale.languages, id: \.self) { language in
                    let native = Locale(identifier: language)
                    Text(native.localizedString(forIdentifier: language) ?? language).tag(language)
                }
            }
            Toggle(label("General.WarnBeforeStartingStream"), isOn: flag(user, "BasicWindow", "WarnBeforeStartingStream"))
            Toggle(label("General.WarnBeforeStoppingStream"), isOn: flag(user, "BasicWindow", "WarnBeforeStoppingStream"))
            Toggle(label("General.WarnBeforeStoppingRecord"), isOn: flag(user, "BasicWindow", "WarnBeforeStoppingRecord"))
            Toggle(label("General.RecordWhenStreaming"), isOn: flag(user, "BasicWindow", "RecordWhenStreaming"))
            Toggle(label("General.KeepRecordingWhenStreamStops"), isOn: flag(user, "BasicWindow", "KeepRecordingWhenStreamStops"))
            Toggle(label("General.ReplayBufferWhileStreaming"), isOn: flag(user, "BasicWindow", "ReplayBufferWhileStreaming"))
            Toggle(label("General.KeepReplayBufferStreamStops"), isOn: flag(user, "BasicWindow", "KeepReplayBufferStreamStops"))
        }
    }

    private var stream: some View {
        Section(label("Stream")) {
            Picker(OBSLocale.str("Service"), selection: Binding(get: { serviceType }, set: { type in
                serviceType = type
                openService(type, current: nil)
            })) {
                ForEach(registeredKinds(obs_enum_service_types, obs_service_get_display_name)) { kind in
                    Text(kind.name).tag(kind.id)
                }
            }
            if let serviceEditor {
                OBSPropertiesView(editor: serviceEditor).id(serviceType)
            }
        }.disabled(obs_frontend_streaming_active())
    }

    private func openService(_ type: String, current: OpaquePointer?) {
        let settings = current.flatMap { obs_service_get_settings($0) } ?? obs_service_defaults(type)
        defer { obs_data_release(settings) }
        guard let settings, let properties = obs_get_service_properties(type) else {
            serviceEditor = nil
            return
        }
        serviceEditor = OBSPropertyEditor(properties: properties, settings: settings) { changed in
            guard let service = obs_service_create(type, "service", changed, nil) else { return }
            obs_frontend_set_streaming_service(service)
            obs_frontend_save_streaming_service()
            obs_service_release(service)
        }
        if current == nil { serviceEditor?.apply() }
    }

    private var output: some View {
        let section = outputSection
        let formats = [("hybrid_mp4", label("Output.Format.hMP4")), ("hybrid_mov", label("Output.Format.hMOV"))]
        let extraFormats = [("mkv", label("Output.Format.MKV")), ("flv", label("Output.Format.FLV")),
                            ("mpegts", label("Output.Format.TS")), ("mp4", label("Output.Format.MP4")),
                            ("mov", label("Output.Format.MOV"))]
        return Group {
            choice(label("Output.Mode"), profile, "Output", "Mode",
                   [("Simple", label("Output.Mode.Simple")), ("Advanced", label("Output.Mode.Adv"))])
            Picker(label("Output"), selection: $outputTab) {
                ForEach(OutputTab.allCases, id: \.self) { option in
                    Text(outputTitle(option)).tag(option)
                }
            }
            if outputTab == .streaming {
                encoder(section, advanced ? "Encoder" : "StreamEncoder", record: false)
                if advanced {
                    Picker(label("Output.Simple.RecAudioTrack"), selection: quantity(profile, section, "TrackIndex", 1...6)) {
                        ForEach(1...6, id: \.self) { Text(String($0)).tag(UInt64($0)) }
                    }
                } else {
                    number(label("Output.VideoBitrate"), profile, section, "VBitrate", 100...100_000)
                    number(label("Output.AudioBitrate"), profile, section, "ABitrate", 32...320)
                }
            } else if outputTab == .recording {
                TextField(label("Output.Simple.SavePath"), text: string(profile, section, advanced ? "RecFilePath" : "FilePath"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                choice(label("Output.Format"), profile, section, "RecFormat2",
                       obs_ios_get_capabilities() & UInt32(OBS_IOS_CAP_SPAWN_MUXER.rawValue) != 0 ? formats + extraFormats : formats)
                encoder(section, "RecEncoder", record: true)
                tracks(section)
                if advanced && obs_ios_get_capabilities() & UInt32(OBS_IOS_CAP_SPAWN_MUXER.rawValue) != 0 {
                    TextField(label("Output.Adv.FFmpeg.MuxerSettings"), text: string(profile, section, "RecMuxerCustom"))
                }
            } else if outputTab == .audio {
                ForEach(1...6, id: \.self) { track in
                    Section(OBSLocale.str("Basic.Settings.Output.Adv.Audio.Track\(track)")) {
                        number(label("Output.AudioBitrate"), profile, "AdvOut", "Track\(track)Bitrate", 32...320)
                        TextField(OBSLocale.str("Name"), text: string(profile, "AdvOut", "Track\(track)Name"))
                    }
                }
            } else {
                Toggle(outputTitle(.replay), isOn: flag(profile, section, "RecRB"))
                number(label("Output.ReplayBuffer.SecondsMax"), profile, section, "RecRBTime", 1...3600)
                number(label("Output.ReplayBuffer.MegabytesMax"), profile, section, "RecRBSize", 1...16384)
                TextField(label("Output.ReplayBuffer.Prefix"), text: string(profile, "SimpleOutput", "RecRBPrefix"))
                TextField(label("Output.ReplayBuffer.Suffix"), text: string(profile, "SimpleOutput", "RecRBSuffix"))
            }
        }.disabled(active)
    }

    private func outputTitle(_ page: OutputTab) -> String {
        switch page {
        case .streaming: label("Stream")
        case .recording: OBSLocale.str("Basic.MainMenu.File.ShowRecordings").replacingOccurrences(of: "&", with: "")
        case .audio: label("Audio")
        case .replay: OBSLocale.str("ReplayBuffer")
        }
    }

    private func tracks(_ section: String) -> some View {
        Section(OBSLocale.str("Basic.Settings.Output.Simple.RecAudioTrack")) {
            ForEach(0..<6, id: \.self) { track in
                let bit = UInt64(1) << track
                Toggle(String(track + 1), isOn: Binding(get: {
                    config_get_uint(profile, section, "RecTracks") & bit != 0
                }, set: { enabled in
                    let previous = config_get_uint(profile, section, "RecTracks")
                    let next = enabled ? previous | bit : previous & ~bit
                    if next != 0 { config_set_uint(profile, section, "RecTracks", next); save(profile) }
                }))
            }
        }
    }

    @ViewBuilder private func encoder(_ section: String, _ key: String, record: Bool) -> some View {
        let value = configText(profile, section, key)
        let id = value == "x264" ? "obs_x264" : value
        let kinds = registeredKinds(obs_enum_encoder_types, obs_encoder_get_display_name).filter {
            obs_get_encoder_type($0.id) == OBS_ENCODER_VIDEO
        }
        let options = kinds.map { (advanced || $0.id != "obs_x264" ? $0.id : "x264", $0.name) }
        let same = record ? [(advanced ? "none" : "", label("Output.Simple.RecordingQuality.Stream"))] : []
        choice(label("Output.Encoder.Video"), profile, section, key, same + options)
        if advanced && id != "none" && !id.isEmpty {
            EncoderSettingsView(id: id, filename: record ? "recordEncoder.json" : "streamEncoder.json")
                .id(id + key)
        }
    }

    private var audio: some View {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        return Group {
            Section(label("Audio")) {
                Picker(label("Audio.SampleRate"), selection: quantity(profile, "Audio", "SampleRate", 44100...48000)) {
                    Text("44.1 kHz").tag(UInt64(44100))
                    Text("48 kHz").tag(UInt64(48000))
                }
                choice(label("Audio.Channels"), profile, "Audio", "ChannelSetup",
                       [("Mono", OBSLocale.str("Mono")), ("Stereo", OBSLocale.str("Stereo"))] +
                       ["2.1", "4.0", "4.1", "5.1", "7.1"].map { ($0, $0) })
            }
            Section(label("Audio.Devices")) {
                ForEach(0..<4, id: \.self) { index in
                    let suffix = index == 0 ? "" : String(index + 1)
                    choice(label("Audio.AuxDevice" + suffix), profile, "Audio", "AuxDevice\(index + 1)",
                           [("", OBSLocale.str("Disabled")), ("default", OBSLocale.str("Default"))] +
                           (session.availableInputs ?? []).map { ($0.uid, $0.portName) })
                }
                choice(label("Advanced.Audio.MonitoringDevice"), profile, "Audio", "MonitoringDeviceId",
                       [("default", label("Advanced.Audio.MonitoringDevice.Default"))] + outputs.map { ($0.uid, $0.portName) })
            }
            Section(label("Audio.Meters")) {
                choice(label("Audio.MeterDecayRate"), profile, "Audio", "MeterDecay",
                       ["Fast", "Medium", "Slow"].map { ($0, label("Audio.MeterDecayRate." + $0)) })
                Toggle(label("Audio.PeakMeterType.TruePeak"), isOn: flag(profile, "Audio", "TruePeak"))
            }
        }.disabled(active)
    }

    private var video: some View {
        Group {
            resolution(label("Video.BaseResolution"), width: "BaseCX", height: "BaseCY")
            resolution(label("Video.ScaledResolution"), width: "OutputCX", height: "OutputCY")
            choice(label("Video.DownscaleFilter"), profile, "Video", "ScaleType",
                   ["Bilinear", "Bicubic", "Lanczos", "Area"].map { ($0.lowercased(), label("Video.DownscaleFilter." + $0)) })
            Picker(label("Video.FPS"), selection: quantity(profile, "Video", "FPSType", 0...2)) {
                Text(label("Video.FPSCommon")).tag(UInt64(0))
                Text(label("Video.FPSInteger")).tag(UInt64(1))
                Text(label("Video.FPSFraction")).tag(UInt64(2))
            }
            switch config_get_uint(profile, "Video", "FPSType") {
            case 1:
                number(label("Video.FPSInteger"), profile, "Video", "FPSInt", 1...240)
            case 2:
                number(label("Video.Numerator"), profile, "Video", "FPSNum", 1...240_000)
                number(label("Video.Denominator"), profile, "Video", "FPSDen", 1...1001)
            default:
                choice(label("Video.FPSCommon"), profile, "Video", "FPSCommon",
                       ["10", "20", "23.976", "24", "25", "29.97", "30", "48", "50", "59.94", "60", "120"].map { ($0, $0) })
            }
            Button(OBSLocale.str("Apply")) { applyVideo() }
        }.disabled(active)
    }

    private func resolution(_ title: String, width: String, height: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: quantity(profile, "Video", width, 2...8192), format: .number.grouping(.never))
            Text("×")
            TextField(title, value: quantity(profile, "Video", height, 2...8192), format: .number.grouping(.never))
        }.keyboardType(.numberPad).multilineTextAlignment(.trailing)
    }

    private var advancedSettings: some View {
        Group {
            Section(label("Video")) {
                choice(label("Advanced.Video.ColorFormat"), profile, "Video", "ColorFormat",
                       ["NV12", "I420", "I444", "P010", "I010", "P216", "P416", "BGRA"]
                       .map { ($0, label("Advanced.Video.ColorFormat." + $0)) })
                choice(label("Advanced.Video.ColorSpace"), profile, "Video", "ColorSpace",
                       ["sRGB", "601", "709", "2100PQ", "2100HLG"].map { ($0, label("Advanced.Video.ColorSpace." + $0)) })
                choice(label("Advanced.Video.ColorRange"), profile, "Video", "ColorRange",
                       ["Partial", "Full"].map { ($0, label("Advanced.Video.ColorRange." + $0)) })
                number(label("Advanced.Video.SdrWhiteLevel"), profile, "Video", "SdrWhiteLevel", 80...500)
                number(label("Advanced.Video.HdrNominalPeakLevel"), profile, "Video", "HdrNominalPeakLevel", 100...10_000)
                Button(OBSLocale.str("Apply")) { applyVideo() }
            }
            Section(label("Advanced.StreamDelay")) {
                Toggle(label("Advanced.StreamDelay"), isOn: flag(profile, "Output", "DelayEnable"))
                number(label("Advanced.StreamDelay.Duration"), profile, "Output", "DelaySec", 1...1800)
                Toggle(label("Advanced.StreamDelay.Preserve"), isOn: flag(profile, "Output", "DelayPreserve"))
            }
            Section(label("Advanced.Network")) {
                Toggle(label("Output.Reconnect"), isOn: flag(profile, "Output", "Reconnect"))
                number(label("Output.RetryDelay"), profile, "Output", "RetryDelay", 1...120)
                number(label("Output.MaxRetries"), profile, "Output", "MaxRetries", 0...100)
                Toggle(label("Output.DynamicBitrate"), isOn: flag(profile, "Output", "DynamicBitrate"))
            }
        }.disabled(active)
    }

    private func applyVideo() {
        NotificationCenter.default.post(name: .obsDisplayWillReset, object: nil)
        obs_frontend_reset_video()
        NotificationCenter.default.post(name: .obsDisplayDidReset, object: nil)
    }

    private func label(_ key: String) -> String { OBSLocale.str("Basic.Settings." + key) }

    private func save(_ config: OpaquePointer?) {
        _ = config_save_safe(config, "tmp", "bak")
        generation += 1
    }

    private func string(_ config: OpaquePointer?, _ section: String, _ key: String) -> Binding<String> {
        Binding(get: { configText(config, section, key) }, set: {
            config_set_string(config, section, key, $0)
            save(config)
        })
    }

    private func flag(_ config: OpaquePointer?, _ section: String, _ key: String) -> Binding<Bool> {
        Binding(get: { config_get_bool(config, section, key) }, set: {
            config_set_bool(config, section, key, $0)
            save(config)
        })
    }

    private func quantity(_ config: OpaquePointer?, _ section: String, _ key: String,
                          _ range: ClosedRange<UInt64>) -> Binding<UInt64> {
        Binding(get: { config_get_uint(config, section, key) }, set: {
            config_set_uint(config, section, key, min(max($0, range.lowerBound), range.upperBound))
            save(config)
        })
    }

    private func number(_ title: String, _ config: OpaquePointer?, _ section: String, _ key: String,
                        _ range: ClosedRange<UInt64>) -> some View {
        LabeledContent(title) {
            TextField(title, value: quantity(config, section, key, range), format: .number.grouping(.never))
                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
        }
    }

    private func choice(_ title: String, _ config: OpaquePointer?, _ section: String, _ key: String,
                        _ options: [(String, String)]) -> some View {
        let selection = string(config, section, key)
        return Picker(title, selection: selection) {
            if !options.contains(where: { $0.0 == selection.wrappedValue }) {
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
            ForEach(options, id: \.0) { option in Text(option.1).tag(option.0) }
        }
    }
}

private func configText(_ config: OpaquePointer?, _ section: String, _ key: String) -> String {
    config_get_string(config, section, key).map { String(cString: $0) } ?? ""
}

private func registeredKinds(
    _ enumerate: (Int, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Bool,
    _ title: (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
) -> [SourceKind] {
    var kinds: [SourceKind] = []
    var index = 0
    var id: UnsafePointer<CChar>?
    while enumerate(index, &id) {
        defer { index += 1 }
        if let id, let title = title(id) {
            kinds.append(SourceKind(id: String(cString: id), name: String(cString: title)))
        }
    }
    return kinds
}

private struct EncoderSettingsView: View {
    let id: String
    let filename: String
    @State private var editor: OBSPropertyEditor?

    var body: some View {
        Group {
            if let editor { OBSPropertiesView(editor: editor) }
        }.onAppear {
            guard let pointer = obs_frontend_get_current_profile_path() else { return }
            let file = URL(fileURLWithPath: String(cString: pointer)).appendingPathComponent(filename).path
            bfree(pointer)
            guard let properties = obs_get_encoder_properties(id), let defaults = obs_encoder_defaults(id) else { return }
            defer { obs_data_release(defaults) }
            if let saved = obs_data_create_from_json_file_safe(file, "bak") {
                obs_data_apply(defaults, saved)
                obs_data_release(saved)
            }
            editor = OBSPropertyEditor(properties: properties, settings: defaults) {
                obs_data_save_json_safe($0, file, "tmp", "bak")
            }
        }
    }
}

extension Notification.Name {
    static let obsDisplayWillReset = Notification.Name("OBSDisplayWillReset")
    static let obsDisplayDidReset = Notification.Name("OBSDisplayDidReset")
}
