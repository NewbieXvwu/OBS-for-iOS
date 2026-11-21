/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 自研必要性证明：OBSBasic.ui 的停靠面板依赖 Qt Widgets。此视图按原版面板和菜单组织
 * SwiftUI，在窄窗口中用分段选择器保留全部面板入口。 */

import SwiftUI

@MainActor
struct WorkspaceView: View {
    @EnvironmentObject private var locale: OBSLocale
    @StateObject private var model = WorkspaceModel()
    @State private var pane = Pane.scenes
    @State private var hiddenPanes: Set<Pane> = []
    @State private var sheet: Sheet?
    @State private var namePrompt: NamePrompt?
    @State private var pendingName = ""
    @State private var outputError = ""
    @State private var showError = false
    @State private var confirmation: NamePrompt?

    private enum Pane: CaseIterable, Identifiable {
        case scenes, sources, mixer, transitions, controls
        var id: Self { self }
        var key: String {
            switch self {
            case .scenes: "Basic.Main.Scenes"
            case .sources: "Basic.Main.Sources"
            case .mixer: "Mixer"
            case .transitions: "Basic.SceneTransitions"
            case .controls: "Basic.Main.Controls"
            }
        }
    }

    private struct NamePrompt: Identifiable {
        let id = UUID()
        let title: String
        let save: (String) -> Void
    }

    private enum Sheet: Identifiable {
        case settings, stats, recordings, logs, multiview, websocket, advancedAudio
        case properties(SourceReference), filters(SourceReference), transform(SceneItemReference)
        var id: String {
            switch self {
            case .settings: "settings"
            case .stats: "stats"
            case .recordings: "recordings"
            case .logs: "logs"
            case .multiview: "multiview"
            case .websocket: "websocket"
            case .advancedAudio: "advancedAudio"
            case .properties(let source): "properties-\(source.id)"
            case .filters(let source): "filters-\(source.id)"
            case .transform(let item): "transform-\(item.id)"
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 720 && geometry.size.width > geometry.size.height
            VStack(spacing: 6) {
                menus
                preview.frame(height: wide ? geometry.size.height * 0.51 : min(geometry.size.width * 9 / 16, geometry.size.height * 0.42))
                if wide {
                    HStack(spacing: 5) {
                        ForEach(Pane.allCases.filter { !hiddenPanes.contains($0) }) { selected in
                            dock(selected)
                        }
                    }
                } else {
                    Picker(OBSLocale.str("Basic.MainMenu.Docks"), selection: $pane) {
                        ForEach(Pane.allCases) { option in Text(OBSLocale.str(option.key)).tag(option) }
                    }
                    .pickerStyle(.segmented)
                    dock(pane)
                }
                statusBar
            }
            .padding(6)
            .background(Color(uiColor: .systemBackground))
        }
        .sheet(item: $sheet) { item in
            NavigationStack {
                sheetContent(item)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(OBSLocale.str("Close")) { sheet = nil }
                        }
                    }
            }
        }
        .alert(namePrompt?.title ?? "", isPresented: Binding(get: { namePrompt != nil }, set: {
            if !$0 { namePrompt = nil }
        }), presenting: namePrompt) { request in
            TextField(OBSLocale.str("Name"), text: $pendingName)
            Button(OBSLocale.str("OK")) { request.save(pendingName.trimmingCharacters(in: .whitespacesAndNewlines)) }
            Button(OBSLocale.str("Cancel"), role: .cancel) { }
        }
        .alert(OBSLocale.str("Error"), isPresented: $showError) {
            Button(OBSLocale.str("OK"), role: .cancel) { }
        } message: { Text(outputError) }
        .confirmationDialog(confirmation?.title ?? "", isPresented: Binding(get: { confirmation != nil }, set: {
            if !$0 { confirmation = nil }
        }), titleVisibility: .visible, presenting: confirmation) { request in
            Button(request.title) { request.save("") }
        }
        .background {
            if sheet == nil { OBSKeyboardInput().frame(width: 1, height: 1) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OBSFrontendAction"))) { message in
            handleFrontend(message)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OBSWebSocketAlert"))) { message in
            outputError = message.userInfo?["body"] as? String ?? ""
            showError = true
        }
        .onChange(of: locale.selection) { _ in model.refresh() }
    }

    private var menus: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 17) {
                Menu(OBSLocale.menu("Basic.MainMenu.File")) {
                    Button(OBSLocale.menu("Basic.MainMenu.File.ShowRecordings")) { sheet = .recordings }
                    Button(OBSLocale.menu("Basic.MainMenu.Help.Logs.ViewCurrentLog")) { sheet = .logs }
                    Button(OBSLocale.str("Settings")) { sheet = .settings }
                }
                Menu(OBSLocale.menu("Basic.MainMenu.Edit")) {
                    if let item = model.selectedItem {
                        Button(OBSLocale.menu("Basic.MainMenu.Edit.Transform.EditTransform")) { sheet = .transform(item) }
                        Button(OBSLocale.str("Copy")) { model.withItem(item, obs_frontend_copy_sceneitem) }
                    }
                    if obs_frontend_can_paste_sceneitem(false) {
                        Button(OBSLocale.str("Paste")) {
                            model.withCurrentScene { obs_frontend_paste_sceneitem($0, false) }
                            model.saveSources()
                        }
                    }
                    Button(OBSLocale.str("Basic.AdvAudio")) { sheet = .advancedAudio }
                }
                Menu(OBSLocale.menu("Basic.MainMenu.View")) {
                    Button(OBSLocale.str("Basic.Stats")) { sheet = .stats }
                    Button(OBSLocale.str("Projector.Title.Multiview")) { sheet = .multiview }
                    Toggle(OBSLocale.str("Basic.Main.PreviewConextMenu.Enable"), isOn: Binding(
                        get: { model.previewEnabled }, set: {
                            obs_frontend_set_preview_enabled($0)
                            model.previewEnabled = $0
                        }))
                    Menu(OBSLocale.menu("Basic.MainMenu.Docks")) {
                        ForEach(Pane.allCases) { option in
                            Toggle(OBSLocale.str(option.key), isOn: Binding(
                                get: { !hiddenPanes.contains(option) }, set: { visible in
                                    if visible { hiddenPanes.remove(option) }
                                    else { hiddenPanes.insert(option) }
                                }))
                        }
                        Button(OBSLocale.menu("Basic.MainMenu.Docks.ResetDocks")) { hiddenPanes = [] }
                    }
                }
                Menu(OBSLocale.menu("Basic.MainMenu.Profile")) {
                    Button(OBSLocale.str("New")) { ask("New", save: { name in obs_frontend_create_profile(name); model.refresh() }) }
                    Button(OBSLocale.str("Duplicate")) {
                        ask("Duplicate", save: { name in obs_frontend_duplicate_profile(name); model.refresh() })
                    }
                    ForEach(ownedStringList(obs_frontend_get_profiles()), id: \.self) { profile in
                        Button(profile) { obs_frontend_set_current_profile(profile); model.refresh() }
                    }
                }
                Menu(OBSLocale.menu("Basic.MainMenu.SceneCollection")) {
                    Button(OBSLocale.str("New")) {
                        ask("New", save: { name in _ = obs_frontend_add_scene_collection(name); model.refresh() })
                    }
                    ForEach(ownedStringList(obs_frontend_get_scene_collections()), id: \.self) { collection in
                        Button(collection) { obs_frontend_set_current_scene_collection(collection); model.refresh() }
                    }
                }
                Menu(OBSLocale.menu("Basic.MainMenu.Tools")) {
                    Button(OBSLocale.str("OBSWebSocket.Settings.DialogTitle", module: "obs-websocket")) { sheet = .websocket }
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var preview: some View {
        HStack(spacing: 6) {
            if model.studio {
                VStack(spacing: 3) {
                    Text(OBSLocale.str("StudioMode.Preview")).font(.caption)
                    editablePreview
                }
                VStack(spacing: 3) {
                    Text(OBSLocale.str("StudioMode.Program")).font(.caption)
                    OBSPreview().background(.black)
                }
            } else {
                editablePreview
            }
        }
    }

    private var editablePreview: some View {
        ZStack {
            Color.black
            if model.previewEnabled {
                OBSPreview(source: model.studio ? model.currentScene : nil)
                if let item = model.selectedItem {
                    SelectionOverlay(item: item, model: model)
                }
            } else {
                Text(OBSLocale.str("Basic.Main.PreviewDisabled"))
            }
        }
    }

    private func dock(_ option: Pane) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(OBSLocale.str(option.key))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            Divider()
            Group {
                switch option {
                case .scenes: scenes
                case .sources: sources
                case .mixer: ScrollView { MixerView { sheet = .advancedAudio } }
                case .transitions: ScrollView { transitionControls }
                case .controls: ScrollView { controlButtons }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 4))
    }

    private var scenes: some View {
        VStack(spacing: 0) {
            ScrollView {
                ForEach(model.scenes) { scene in
                    Button { model.pickScene(scene) } label: {
                        Text(scene.name).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .buttonStyle(.plain)
                    .background(model.currentScene == scene.id ? Color.accentColor.opacity(0.35) : .clear)
                    .contextMenu {
                        Button(OBSLocale.str("Rename")) {
                            ask("Rename", initial: scene.name) { name in
                                withSource(scene.id) { obs_source_set_name($0, name) }
                                obs_frontend_save(); model.refresh()
                            }
                        }
                        Button(OBSLocale.menu("Basic.MainMenu.Edit.Order.MoveUp")) { model.moveScene(scene, by: -1) }
                        Button(OBSLocale.menu("Basic.MainMenu.Edit.Order.MoveDown")) { model.moveScene(scene, by: 1) }
                        Button(OBSLocale.str("Remove"), role: .destructive) { model.removeScene(scene) }
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                icon("plus", "AddScene") { ask("AddScene", save: model.addScene) }
                if let scene = model.scenes.first(where: { $0.id == model.currentScene }) {
                    icon("minus", "Remove") { model.removeScene(scene) }
                    icon("chevron.up", "Basic.MainMenu.Edit.Order.MoveUp") { model.moveScene(scene, by: -1) }
                    icon("chevron.down", "Basic.MainMenu.Edit.Order.MoveDown") { model.moveScene(scene, by: 1) }
                }
                Spacer(minLength: 0)
            }
            .padding(5)
        }
    }

    private var sources: some View {
        VStack(spacing: 0) {
            ScrollView {
                ForEach(model.sources) { item in
                    HStack(spacing: 5) {
                        Button { model.select(item) } label: {
                            Text(item.source.name).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.leading, CGFloat(item.depth) * 12)
                        icon(item.visible ? "eye" : "eye.slash", "Basic.Main.Sources.Visibility") {
                            model.withItem(item) { _ = obs_sceneitem_set_visible($0, !item.visible) }
                            model.saveSources()
                        }
                        icon(item.locked ? "lock" : "lock.open", "Basic.Main.Sources.Lock") {
                            model.withItem(item) { _ = obs_sceneitem_set_locked($0, !item.locked) }
                            model.saveSources()
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .background(model.selectedItem?.id == item.id ? Color.accentColor.opacity(0.35) : .clear)
                    .contextMenu { sourceActions(item) }
                }
            }
            Divider()
            HStack {
                Menu {
                    ForEach(model.inputKinds) { kind in
                        Button(kind.name) { ask("Basic.Main.Source", initial: kind.name) { model.addSource(kind, name: $0) } }
                    }
                    Menu(OBSLocale.str("Basic.Scene")) {
                        ForEach(model.scenes.filter { $0.id != model.currentScene }) { scene in
                            Button(scene.name) { model.nestScene(scene) }
                        }
                    }
                    Button(OBSLocale.str("Basic.Main.NewGroup")) { ask("Basic.Main.NewGroup", save: model.groupSelected) }
                } label: {
                    Image(systemName: "plus").frame(minWidth: 28, minHeight: 30)
                        .accessibilityLabel(OBSLocale.str("Add"))
                }
                if let item = model.selectedItem {
                    icon("minus", "Remove") { remove(item) }
                    icon("gearshape", "Properties") { sheet = .properties(item.source) }
                }
                Spacer(minLength: 0)
            }
            .padding(5)
        }
    }

    @ViewBuilder
    private func sourceActions(_ item: SceneItemReference) -> some View {
        Button(OBSLocale.str("Properties")) { sheet = .properties(item.source) }
        Button(OBSLocale.str("Filters")) { sheet = .filters(item.source) }
        Button(OBSLocale.menu("Basic.MainMenu.Edit.Transform.EditTransform")) { sheet = .transform(item) }
        Menu(OBSLocale.menu("Basic.MainMenu.Edit.Order")) {
            Button(OBSLocale.menu("Basic.MainMenu.Edit.Order.MoveUp")) { move(item, OBS_ORDER_MOVE_UP) }
            Button(OBSLocale.menu("Basic.MainMenu.Edit.Order.MoveDown")) { move(item, OBS_ORDER_MOVE_DOWN) }
            Button(OBSLocale.menu("Basic.MainMenu.Edit.Order.MoveToTop")) { move(item, OBS_ORDER_MOVE_TOP) }
            Button(OBSLocale.menu("Basic.MainMenu.Edit.Order.MoveToBottom")) { move(item, OBS_ORDER_MOVE_BOTTOM) }
        }
        Button(OBSLocale.str("Rename")) {
            ask("Rename", initial: item.source.name) { name in
                withSource(item.source.id) { obs_source_set_name($0, name) }
                model.saveSources()
            }
        }
        if item.isGroup {
            Button(OBSLocale.str("Basic.Main.Ungroup")) {
                model.withItem(item, obs_sceneitem_group_ungroup)
                model.saveSources()
            }
        }
        Button(OBSLocale.str("Remove"), role: .destructive) { remove(item) }
    }

    private var transitionControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(OBSLocale.str("Basic.SceneTransitions"), selection: Binding(
                get: { model.currentTransition }, set: model.setTransition)) {
                ForEach(model.transitions) { item in Text(item.name).tag(item.id) }
            }
            .labelsHidden()
            Stepper(value: Binding(get: { model.duration }, set: { newValue in
                model.duration = newValue
                obs_frontend_set_transition_duration(Int32(newValue))
            }), in: 0...20000, step: 50) {
                Text(OBSLocale.str("Basic.TransitionDuration") + " \(model.duration) ms")
            }
            if let current = model.transitions.first(where: { $0.id == model.currentTransition }) {
                Button(OBSLocale.str("Basic.TransitionProperties")) { sheet = .properties(current) }
            }
            if model.studio {
                Slider(value: Binding(get: { model.tbar }, set: {
                    model.tbar = $0
                    obs_frontend_set_tbar_position(Int32($0))
                }), in: 0...1024, onEditingChanged: { editing in
                    if !editing { obs_frontend_release_tbar(); model.refresh() }
                })
                command("Transition") { obs_frontend_preview_program_trigger_transition() }
            }
        }
        .padding(6)
    }

    private var controlButtons: some View {
        VStack(spacing: 5) {
            command(model.streaming ? "Basic.Main.StopStreaming" : "Basic.Main.StartStreaming") {
                let stopping = model.streaming
                confirmOutput(stopping ? "WarnBeforeStoppingStream" : "WarnBeforeStartingStream",
                              stopping ? "Basic.Main.StopStreaming" : "Basic.Main.StartStreaming",
                              stopping ? obs_frontend_streaming_stop : obs_frontend_streaming_start)
            }
            command(model.recording ? "Basic.Main.StopRecording" : "Basic.Main.StartRecording") {
                if model.recording {
                    confirmOutput("WarnBeforeStoppingRecord", "Basic.Main.StopRecording", obs_frontend_recording_stop)
                } else { obs_frontend_recording_start() }
            }
            if model.recording {
                command(model.paused ? "Basic.Main.UnpauseRecording" : "Basic.Main.PauseRecording") {
                    obs_frontend_recording_pause(!model.paused)
                }
            }
            command(model.replay ? "Basic.Main.StopReplayBuffer" : "Basic.Main.StartReplayBuffer") {
                if model.replay { obs_frontend_replay_buffer_stop() } else { obs_frontend_replay_buffer_start() }
            }
            if model.replay { command("Basic.Main.SaveReplay", obs_frontend_replay_buffer_save) }
            command("Basic.TogglePreviewProgramMode", model.toggleStudio)
            command("Settings") { sheet = .settings }
        }
        .padding(5)
    }

    private func confirmOutput(_ key: String, _ title: String, _ action: @escaping () -> Void) {
        if config_get_bool(obs_frontend_get_user_config(), "BasicWindow", key) {
            confirmation = NamePrompt(title: OBSLocale.str(title), save: { _ in action() })
        } else { action() }
    }

    private var statusBar: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 12) {
                if model.streaming { Label(OBSLocale.str("Basic.Stats.Status.Live"), systemImage: "antenna.radiowaves.left.and.right") }
                if model.recording { Label(OBSLocale.str("Basic.Stats.Status.Recording"), systemImage: "record.circle").foregroundStyle(.red) }
                Spacer()
                Text(String(format: "%.1f FPS", obs_get_active_fps()))
                Button(OBSLocale.str("Basic.Stats")) { sheet = .stats }
            }
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func sheetContent(_ item: Sheet) -> some View {
        switch item {
        case .settings: OBSSettingsView()
        case .stats: OBSStatsView()
        case .recordings: OBSFilesView(logs: false)
        case .logs: OBSFilesView(logs: true)
        case .multiview: MultiviewView(model: model)
        case .websocket: OBSWebSocketSettingsView()
        case .advancedAudio: AdvancedAudioView()
        case .properties(let source): SourcePropertiesView(source: source)
        case .filters(let source): SourceFiltersView(source: source)
        case .transform(let item): TransformView(item: item, model: model)
        }
    }

    private func command(_ key: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(OBSLocale.str(key))
                .font(.footnote)
                .frame(maxWidth: .infinity, minHeight: 27)
        }
        .buttonStyle(.bordered)
        .tint(.secondary)
    }

    private func icon(_ symbol: String, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote)
                .frame(minWidth: 24, minHeight: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(OBSLocale.menu(key))
    }

    private func ask(_ key: String, initial: String = "", save: @escaping (String) -> Void) {
        pendingName = initial
        namePrompt = NamePrompt(title: OBSLocale.str(key)) { name in if !name.isEmpty { save(name) } }
    }

    private func remove(_ item: SceneItemReference) {
        model.withItem(item, obs_sceneitem_remove)
        model.selectedItem = nil
        model.saveSources()
    }

    private func move(_ item: SceneItemReference, _ direction: obs_order_movement) {
        model.withItem(item) { obs_sceneitem_set_order($0, direction) }
        model.saveSources()
    }

    private func handleFrontend(_ notification: Notification) {
        switch notification.object as? String {
        case "Event": model.refresh()
        case "OutputError":
            outputError = notification.userInfo?["message"] as? String ?? ""
            showError = true
        case "Properties", "Filters":
            if let id = notification.userInfo?["source"] as? String, let source = withSource(id, SourceReference.init) {
                sheet = notification.object as? String == "Properties" ? .properties(source) : .filters(source)
            }
        case "Transform":
            if let id = notification.userInfo?["item"] as? Int64, let item = model.sources.first(where: { $0.item == id }) {
                sheet = .transform(item)
            }
        default: break
        }
    }
}

func ownedStringList(_ list: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> [String] {
    guard let list else { return [] }
    defer { bfree(list) }
    var values: [String] = []
    var index = 0
    while let value = list[index] {
        values.append(String(cString: value))
        index += 1
    }
    return values
}
