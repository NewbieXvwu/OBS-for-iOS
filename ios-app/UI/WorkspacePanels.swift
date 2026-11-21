/* SPDX-License-Identifier: GPL-2.0-or-later */

import SwiftUI

@MainActor
struct SelectionOverlay: View {
    let item: SceneItemReference
    let model: WorkspaceModel
    @State private var originalPosition: vec2?
    @State private var originalScale: vec2?
    @State private var originalWidth = 1.0
    @State private var originalHeight = 1.0

    var body: some View {
        GeometryReader { geometry in
            let video = canvasSize()
            let scale = min(geometry.size.width / video.width, geometry.size.height / video.height)
            let offset = CGPoint(x: (geometry.size.width - video.width * scale) / 2,
                                 y: (geometry.size.height - video.height * scale) / 2)
            let bounds = itemBounds()
            if item.visible && !bounds.isNull {
                Rectangle()
                    .strokeBorder(.red, lineWidth: 2)
                    .overlay(alignment: .bottomTrailing) {
                        if !item.locked {
                            Rectangle().fill(.red).frame(width: 12, height: 12)
                                .padding(5).contentShape(Rectangle())
                                .gesture(sizeGesture(bounds: bounds, scale: scale))
                        }
                    }
                    .frame(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
                    .contentShape(Rectangle())
                    .position(x: offset.x + bounds.midX * scale, y: offset.y + bounds.midY * scale)
                    .gesture(item.locked ? nil : moveGesture(scale: scale, video: video))
            }
        }
    }

    private func itemBounds() -> CGRect {
        var box = CGRect.null
        model.withItem(item) { box = obs_app_item_bounds($0) }
        return box
    }

    private func canvasSize() -> CGSize {
        var video = obs_video_info()
        _ = obs_get_video_info(&video)
        return CGSize(width: Int(max(video.base_width, 1)), height: Int(max(video.base_height, 1)))
    }

    private func moveGesture(scale: CGFloat, video: CGSize) -> some Gesture {
        DragGesture().onChanged { value in
            guard scale > 0 else { return }
            model.withItem(item) { pointer in
                var position = vec2()
                if let originalPosition { position = originalPosition }
                else { obs_sceneitem_get_pos(pointer, &position); originalPosition = position }
                position.x += Float(value.translation.width / scale)
                position.y += Float(value.translation.height / scale)
                if abs(position.x) <= 10 { position.x = 0 }
                if abs(position.y) <= 10 { position.y = 0 }
                let box = obs_app_item_bounds(pointer)
                if abs(CGFloat(position.x) + box.width - video.width) <= 10 {
                    position.x = Float(video.width - box.width)
                }
                if abs(CGFloat(position.y) + box.height - video.height) <= 10 {
                    position.y = Float(video.height - box.height)
                }
                obs_sceneitem_set_pos(pointer, &position)
            }
        }.onEnded { _ in originalPosition = nil; model.saveSources() }
    }

    private func sizeGesture(bounds: CGRect, scale: CGFloat) -> some Gesture {
        DragGesture().onChanged { value in
            guard scale > 0 else { return }
            model.withItem(item) { pointer in
                var size = vec2()
                if let originalScale { size = originalScale }
                else {
                    obs_sceneitem_get_scale(pointer, &size)
                    originalScale = size
                    originalWidth = max(bounds.width, 1)
                    originalHeight = max(bounds.height, 1)
                }
                let dx = value.translation.width / (scale * originalWidth)
                let dy = value.translation.height / (scale * originalHeight)
                let ratio = Float(max(0.01, 1 + (abs(dx) > abs(dy) ? dx : dy)))
                size.x *= ratio
                size.y *= ratio
                obs_sceneitem_set_scale(pointer, &size)
            }
        }.onEnded { _ in originalScale = nil; model.saveSources() }
    }
}

@MainActor
struct TransformView: View {
    let item: SceneItemReference
    let model: WorkspaceModel
    @State private var transform = obs_transform_info()
    @State private var crop = obs_sceneitem_crop()

    var body: some View {
        Form {
            Section(OBSLocale.str("Basic.TransformWindow.Position")) {
                value("Basic.TransformWindow.PositionX", $transform.pos.x)
                value("Basic.TransformWindow.PositionY", $transform.pos.y)
                value("Basic.TransformWindow.Rotation", $transform.rot)
            }
            Section(OBSLocale.str("Basic.TransformWindow.Size")) {
                size("Basic.TransformWindow.Width", axis: 0)
                size("Basic.TransformWindow.Height", axis: 1)
                alignment("Basic.TransformWindow.Alignment", $transform.alignment)
            }
            Section(OBSLocale.str("Basic.TransformWindow.Bounds")) {
                Picker(OBSLocale.str("Basic.TransformWindow.BoundsType"), selection: $transform.bounds_type) {
                    Text(OBSLocale.str("Basic.TransformWindow.BoundsType.None")).tag(OBS_BOUNDS_NONE)
                    Text(OBSLocale.str("Basic.TransformWindow.BoundsType.MaxOnly")).tag(OBS_BOUNDS_MAX_ONLY)
                    Text(OBSLocale.str("Basic.TransformWindow.BoundsType.ScaleInner")).tag(OBS_BOUNDS_SCALE_INNER)
                    Text(OBSLocale.str("Basic.TransformWindow.BoundsType.ScaleOuter")).tag(OBS_BOUNDS_SCALE_OUTER)
                    Text(OBSLocale.str("Basic.TransformWindow.BoundsType.ScaleToWidth")).tag(OBS_BOUNDS_SCALE_TO_WIDTH)
                    Text(OBSLocale.str("Basic.TransformWindow.BoundsType.ScaleToHeight")).tag(OBS_BOUNDS_SCALE_TO_HEIGHT)
                    Text(OBSLocale.str("Basic.TransformWindow.BoundsType.Stretch")).tag(OBS_BOUNDS_STRETCH)
                }
                .onChange(of: transform.bounds_type) { _ in apply() }
                alignment("Basic.TransformWindow.BoundsAlignment", $transform.bounds_alignment)
                value("Basic.TransformWindow.BoundsWidth", $transform.bounds.x)
                value("Basic.TransformWindow.BoundsHeight", $transform.bounds.y)
                Toggle(OBSLocale.str("Basic.TransformWindow.CropToBounds"), isOn: $transform.crop_to_bounds)
                    .onChange(of: transform.crop_to_bounds) { _ in apply() }
            }
            Section(OBSLocale.str("Basic.TransformWindow.Crop")) {
                cropValue("Basic.TransformWindow.CropLeft", $crop.left)
                cropValue("Basic.TransformWindow.CropRight", $crop.right)
                cropValue("Basic.TransformWindow.CropTop", $crop.top)
                cropValue("Basic.TransformWindow.CropBottom", $crop.bottom)
            }
        }
        .navigationTitle(OBSLocale.str("Basic.TransformWindow.Title").replacingOccurrences(of: "%1", with: item.source.name))
        .onAppear {
            model.withItem(item) { pointer in
                obs_sceneitem_get_info2(pointer, &transform)
                obs_sceneitem_get_crop(pointer, &crop)
            }
        }
    }

    private func value(_ key: String, _ selection: Binding<Float>) -> some View {
        LabeledContent(OBSLocale.str(key)) {
            TextField(OBSLocale.str(key), value: selection, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
        }
        .onChange(of: selection.wrappedValue) { _ in apply() }
    }

    private func size(_ key: String, axis: Int) -> some View {
        let pixels = withSource(item.source.id) { axis == 0 ? obs_source_get_width($0) : obs_source_get_height($0) } ?? 1
        let scale = axis == 0 ? $transform.scale.x : $transform.scale.y
        return value(key, Binding(get: { Float(pixels) * scale.wrappedValue }, set: {
            if pixels > 0 { scale.wrappedValue = $0 / Float(pixels) }
        }))
    }

    private func cropValue(_ key: String, _ selection: Binding<Int32>) -> some View {
        LabeledContent(OBSLocale.str(key)) {
            TextField(OBSLocale.str(key), value: selection, format: .number)
                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
        }
        .onChange(of: selection.wrappedValue) { _ in apply() }
    }

    private func alignment(_ key: String, _ selection: Binding<UInt32>) -> some View {
        let names = ["TopLeft", "TopCenter", "TopRight", "CenterLeft", "Center", "CenterRight",
                     "BottomLeft", "BottomCenter", "BottomRight"]
        let flags: [UInt32] = [5, 4, 6, 1, 0, 2, 9, 8, 10]
        return Picker(OBSLocale.str(key), selection: selection) {
            ForEach(names.indices, id: \.self) { index in
                Text(OBSLocale.str("Basic.TransformWindow.Alignment.\(names[index])")).tag(flags[index])
            }
        }
        .onChange(of: selection.wrappedValue) { _ in apply() }
    }

    private func apply() {
        model.withItem(item) { pointer in
            obs_sceneitem_set_info2(pointer, &transform)
            obs_sceneitem_set_crop(pointer, &crop)
        }
        model.saveSources()
    }
}

private final class AudioSources {
    var values: [SourceReference] = []
}

private func audioSources() -> [SourceReference] {
    let collector = AudioSources()
    obs_enum_sources({ pointer, source in
        if let source, let pointer, obs_source_get_output_flags(source) & UInt32(OBS_SOURCE_AUDIO) != 0,
           obs_source_active(source) {
            Unmanaged<AudioSources>.fromOpaque(pointer).takeUnretainedValue().values.append(SourceReference(source))
        }
        return true
    }, Unmanaged.passUnretained(collector).toOpaque())
    return collector.values
}

private final class MixerMeter: ObservableObject {
    private let lock = NSLock()
    private var peak = -60.0
    private var meter: OpaquePointer?

    static let callback: obs_volmeter_updated_t = { parameter, _, peak, _ in
        guard let parameter, let peak else { return }
        let owner = Unmanaged<MixerMeter>.fromOpaque(parameter).takeUnretainedValue()
        owner.lock.lock()
        let channels = Int(obs_volmeter_get_nr_channels(owner.meter))
        owner.peak = Double(UnsafeBufferPointer(start: peak, count: channels).max() ?? -60)
        owner.lock.unlock()
    }

    func attach(_ source: SourceReference) {
        guard meter == nil, let reference = obs_volmeter_create(OBS_FADER_LOG) else { return }
        meter = reference
        obs_volmeter_set_peak_meter_type(reference, TRUE_PEAK_METER)
        obs_volmeter_add_callback(reference, Self.callback, Unmanaged.passUnretained(self).toOpaque())
        withSource(source.id) { _ = obs_volmeter_attach_source(reference, $0) }
    }

    func level() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return max(-60, min(0, peak))
    }

    deinit {
        if let meter {
            obs_volmeter_remove_callback(meter, Self.callback, Unmanaged.passUnretained(self).toOpaque())
            obs_volmeter_destroy(meter)
        }
    }
}

struct MixerView: View {
    let advanced: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(audioSources()) { source in MixerRow(source: source) }
            Button(OBSLocale.str("Basic.AdvAudio"), action: advanced).font(.caption)
        }
        .padding(6)
    }
}

private struct MixerRow: View {
    let source: SourceReference
    @StateObject private var meter = MixerMeter()
    @State private var volume = 1.0
    @State private var muted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(source.name).font(.caption).lineLimit(1)
            TimelineView(.periodic(from: .now, by: 0.06)) { _ in
                GeometryReader { geometry in
                    let level = meter.level()
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.black.opacity(0.5))
                        Rectangle().fill(level == 0 ? .red : level > -9 ? .yellow : .green)
                            .frame(width: geometry.size.width * (level + 60) / 60)
                    }
                }.frame(height: 6)
            }
            HStack {
                ForEach([-60, -40, -20, 0], id: \.self) { db in
                    Text("\(db)").font(.system(size: 8, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: db == 0 ? .trailing : .leading)
                }
            }
            HStack(spacing: 5) {
                Slider(value: $volume, in: 0...2, onEditingChanged: { if !$0 { obs_frontend_save() } })
                    .onChange(of: volume) { value in withSource(source.id) { obs_source_set_volume($0, Float(value)) } }
                    .accessibilityLabel(OBSLocale.str("Basic.AdvAudio.Volume"))
                Button {
                    muted.toggle()
                    withSource(source.id) { obs_source_set_muted($0, muted) }
                    obs_frontend_save()
                } label: { Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                .buttonStyle(.plain)
                .accessibilityLabel(OBSLocale.str(muted ? "Unmute" : "Mute"))
            }
        }
        .onAppear {
            meter.attach(source)
            withSource(source.id) {
                volume = Double(obs_source_get_volume($0))
                muted = obs_source_muted($0)
            }
        }
    }
}

struct AdvancedAudioView: View {
    var body: some View {
        Form {
            ForEach(audioSources()) { source in AdvancedAudioSection(source: source) }
        }.navigationTitle(OBSLocale.str("Basic.AdvAudio"))
    }
}

private struct AdvancedAudioSection: View {
    let source: SourceReference
    @State private var volume = 1.0
    @State private var usePercent = false
    @State private var balance = 0.5
    @State private var mono = false
    @State private var sync = 0.0
    @State private var monitoring = OBS_MONITORING_TYPE_NONE
    @State private var tracks: UInt32 = 1

    var body: some View {
        Section(source.name) {
            Toggle(OBSLocale.str("Basic.AdvAudio.VolumeSource"), isOn: $usePercent)
            LabeledContent(OBSLocale.str("Basic.AdvAudio.Volume")) {
                TextField(OBSLocale.str("Basic.AdvAudio.Volume"), value: Binding(get: {
                    usePercent ? volume * 100 : (volume > 0 ? 20 * log10(volume) : -60)
                }, set: { value in
                    volume = max(0, min(20, usePercent ? value / 100 : pow(10, value / 20)))
                    update { obs_source_set_volume($0, Float(volume)) }
                }), format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
            }
            Toggle(OBSLocale.str("Basic.AdvAudio.Mono"), isOn: $mono).onChange(of: mono) { value in
                update { source in
                    let flags = obs_source_get_flags(source)
                    let mask = UInt32(OBS_SOURCE_FLAG_FORCE_MONO)
                    obs_source_set_flags(source, value ? flags | mask : flags & ~mask)
                }
            }
            LabeledContent(OBSLocale.str("Basic.AdvAudio.Balance")) {
                Slider(value: $balance, in: 0...1).onChange(of: balance) { value in
                    update { obs_source_set_balance_value($0, Float(value)) }
                }
            }
            LabeledContent(OBSLocale.str("Basic.AdvAudio.SyncOffset")) {
                TextField(OBSLocale.str("Basic.AdvAudio.SyncOffset"), value: $sync, format: .number)
                    .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                    .onChange(of: sync) { value in update { obs_source_set_sync_offset($0, Int64(value * 1_000_000)) } }
            }
            Picker(OBSLocale.str("Basic.AdvAudio.Monitoring"), selection: $monitoring) {
                Text(OBSLocale.str("Basic.AdvAudio.Monitoring.None")).tag(OBS_MONITORING_TYPE_NONE)
                Text(OBSLocale.str("Basic.AdvAudio.Monitoring.MonitorOnly")).tag(OBS_MONITORING_TYPE_MONITOR_ONLY)
                Text(OBSLocale.str("Basic.AdvAudio.Monitoring.Both")).tag(OBS_MONITORING_TYPE_MONITOR_AND_OUTPUT)
            }.onChange(of: monitoring) { value in update { obs_source_set_monitoring_type($0, value) } }
            ForEach(0..<6) { index in
                let mask = UInt32(1 << index)
                Toggle(OBSLocale.str("Basic.AdvAudio.Tracks") + " \(index + 1)", isOn: Binding(get: { tracks & mask != 0 }, set: {
                    tracks = $0 ? tracks | mask : tracks & ~mask
                    update { obs_source_set_audio_mixers($0, tracks) }
                }))
            }
        }
        .onAppear {
            withSource(source.id) {
                volume = Double(obs_source_get_volume($0))
                balance = Double(obs_source_get_balance_value($0))
                mono = obs_source_get_flags($0) & UInt32(OBS_SOURCE_FLAG_FORCE_MONO) != 0
                sync = Double(obs_source_get_sync_offset($0)) / 1_000_000
                monitoring = obs_source_get_monitoring_type($0)
                tracks = obs_source_get_audio_mixers($0)
            }
        }
    }

    private func update(_ action: (OpaquePointer) -> Void) {
        withSource(source.id, action)
        obs_frontend_save()
    }
}

struct OBSStatsView: View {
    @State private var cpu = 0.0
    @State private var bitrate = 0.0
    @State private var dropped: UInt32 = 0
    @State private var tick = Date.now

    var body: some View {
        Form {
            LabeledContent("FPS", value: obs_get_active_fps().formatted(.number.precision(.fractionLength(2))))
            LabeledContent(OBSLocale.str("Basic.Stats.CPUUsage"), value: String(format: "%.1f%%", cpu))
            LabeledContent(OBSLocale.str("Basic.Stats.MemoryUsage"), value: "\(os_get_proc_resident_size() / 1048576) MiB")
            LabeledContent(OBSLocale.str("Basic.Stats.AverageTimeToRender"), value: String(format: "%.2f ms", Double(obs_get_average_frame_time_ns()) / 1_000_000))
            LabeledContent(OBSLocale.str("Basic.Stats.MissedFrames"), value: String(obs_get_lagged_frames()))
            LabeledContent(OBSLocale.str("Basic.Stats.SkippedFrames"), value: String(video_output_get_skipped_frames(obs_get_video())))
            LabeledContent(OBSLocale.str("Basic.Stats.DroppedFrames"), value: String(dropped))
            LabeledContent(OBSLocale.str("Basic.Stats.Bitrate"), value: String(format: "%.0f kb/s", bitrate))
        }
        .navigationTitle(OBSLocale.str("Basic.Stats"))
        .task {
            let sampler = os_cpu_usage_info_start()
            defer { os_cpu_usage_info_destroy(sampler) }
            var previousBytes: UInt64 = 0
            while !Task.isCancelled {
                if let output = obs_frontend_get_streaming_output() {
                    let bytes = obs_output_get_total_bytes(output)
                    let elapsed = max(Date.now.timeIntervalSince(tick), 0.1)
                    bitrate = bytes >= previousBytes ? Double(bytes - previousBytes) * 0.008 / elapsed : 0
                    dropped = UInt32(max(0, obs_output_get_frames_dropped(output)))
                    previousBytes = bytes
                    obs_output_release(output)
                }
                cpu = os_cpu_usage_info_query(sampler)
                tick = .now
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }
}

struct MultiviewView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        ScrollView {
            HStack {
                tile(OBSLocale.str("StudioMode.Preview"), source: model.currentScene)
                tile(OBSLocale.str("StudioMode.Program"), source: nil)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))]) {
                ForEach(model.scenes) { scene in
                    Button { model.pickScene(scene) } label: { tile(scene.name, source: scene.id) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(8)
        .navigationTitle(OBSLocale.str("Projector.Title.Multiview"))
    }

    private func tile(_ name: String, source: String?) -> some View {
        VStack(spacing: 3) {
            OBSPreview(source: source).aspectRatio(16 / 9, contentMode: .fit).background(.black)
            Text(name).font(.caption).lineLimit(1)
        }
    }
}

struct OBSFilesView: View {
    let logs: Bool
    @State private var files: [URL] = []

    var body: some View {
        List(files, id: \.self) { file in
            if logs {
                NavigationLink(file.lastPathComponent) {
                    ScrollView {
                        Text((try? String(contentsOf: file, encoding: .utf8)) ?? "")
                            .font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).padding()
                    }.navigationTitle(file.lastPathComponent)
                }
            } else {
                ShareLink(item: file) { Text(file.lastPathComponent) }
            }
        }
        .navigationTitle(OBSLocale.menu(logs ? "Basic.MainMenu.Help.Logs" : "Basic.MainMenu.File.ShowRecordings"))
        .onAppear {
            let directory: URL
            if logs {
                directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("OBS/logs")
            } else {
                let path = obs_frontend_get_current_record_output_path()
                defer { bfree(path) }
                guard let path else { return }
                directory = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            }
            files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
    }
}
