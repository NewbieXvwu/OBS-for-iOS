/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 自研必要性证明：OBSBasic.ui 的停靠面板依赖 Qt Widgets。此视图按原版面板和菜单组织
 * SwiftUI，在窄窗口中用分段选择器保留全部面板入口。 */

import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct WorkspaceView: View {
    @EnvironmentObject private var locale: OBSLocale
    @StateObject private var model = WorkspaceModel()
    @ObservedObject private var projectors = OBSProjectors.shared
    @State private var pane = Pane.scenes
    @State private var hiddenPanes: Set<Pane> = []
    @State private var sheet: Sheet?
    @State private var namePrompt: NamePrompt?
    @State private var pendingName = ""
    @State private var outputError = ""
    @State private var showError = false
    @State private var confirmation: NamePrompt?
    @State private var importingProfile = false
    @State private var showImporter = false
    @State private var closing = false
    @State private var localProjector: ProjectorSelection?

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
        case properties(SourceReference), filters(SourceReference), transform(SceneItemReference), override(SourceReference), export(URL, String)
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
            case .override(let source): "override-\(source.id)"
            case .export(let url, _): "export-\(url.path)"
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
        .disabled(closing)
        .fullScreenCover(item: $localProjector) { selection in
            OBSProjectorView(selection: selection)
                .overlay(alignment: .topTrailing) {
                    Button(OBSLocale.str("Close")) { localProjector = nil }
                        .buttonStyle(.borderedProminent).padding()
                }
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
        .alert(OBSLocale.str("PluginManager.Status.Error"), isPresented: $showError) {
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
        .onChange(of: locale.selection) { _ in model.reloadSourceKinds(); model.refresh() }
        .onChange(of: model.streaming || model.recording || model.replay, perform: obs_app_update_background_job)
        .task {
            if ProcessInfo.processInfo.arguments.contains("--workspace-smoke") {
                await runWorkspaceSmoke()
            }
        }
        .task(id: model.recording) {
            guard model.recording else { return }
            while !Task.isCancelled && obs_frontend_recording_active() {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { obs_app_check_recording_capacity() }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importingProfile ? [.folder] : [.json]) { result in
            do {
                let file = try result.get()
                let accessible = file.startAccessingSecurityScopedResource()
                defer { if accessible { file.stopAccessingSecurityScopedResource() } }
                let name = importingProfile ? file.lastPathComponent : file.deletingPathExtension().lastPathComponent
                finishConfiguration(obs_app_import_configuration(importingProfile, file.path, name))
            } catch {
                outputError = error.localizedDescription
                showError = true
            }
        }
    }

    private func runWorkspaceSmoke() async {
        let previousLanguage = locale.selection
        locale.selection = "zh-CN"
        let menu = OBSLocale.str("Basic.Main.StartStreaming")
        guard menu.contains("直播") || menu.contains("推流") else {
            print("OBS workspace smoke: locale failed: \(menu)")
            locale.selection = previousLanguage
            return
        }
        locale.selection = previousLanguage
        model.addScene("Simulator QA")
        if let color = model.inputKinds.first(where: { $0.id.hasPrefix("color_source") }) {
            model.addSource(color, name: "Simulator Color")
        }
        guard let item = model.sources.first else { return }
        model.select(item)
        func render() async { try? await Task.sleep(for: .milliseconds(400)) }
        if ProcessInfo.processInfo.arguments.contains("--browser-smoke") {
            let settings = obs_data_create()
            obs_data_set_string(settings, "url", "data:text/html,<div id='capture'>OBS</div>")
            obs_data_set_string(settings, "css", "body { margin: 0; background: transparent; color: #e80; }")
            obs_data_set_int(settings, "width", 320)
            obs_data_set_int(settings, "height", 180)
            let browser = obs_source_create("browser_source", "Simulator Browser", settings, nil)
            obs_data_release(settings)
            guard let browser else { return }
            model.withCurrentScene { _ = obs_scene_add($0, browser) }
            for _ in 0..<30 {
                if obs_source_get_width(browser) > 0 { break }
                await render()
            }
            let captured = obs_source_get_width(browser) > 0 && obs_source_get_height(browser) > 0
            obs_source_release(browser)
            guard captured else {
                print("OBS workspace smoke: browser produced no frames")
                return
            }
            print("OBS workspace smoke: WebKit frame")
        }
        for panel in Pane.allCases {
            pane = panel
            await render()
        }
        model.toggleStudio()
        await render()
        guard obs_frontend_preview_program_mode_active() else { return }
        for panel in [Sheet.transform(item), .properties(item.source), .advancedAudio, .stats, .multiview] {
            sheet = panel
            await render()
            print("OBS workspace smoke: \(panel.id)")
            sheet = nil
            await render()
        }
        sheet = .settings
        await render()
    }

    private var menus: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 17) {
                Menu(OBSLocale.menu("Basic.MainMenu.File")) {
                    Button(OBSLocale.menu("Basic.MainMenu.File.ShowRecordings")) { sheet = .recordings }
                    Button(OBSLocale.menu("Basic.MainMenu.Help.Logs.ViewCurrentLog")) { sheet = .logs }
                    Button(OBSLocale.str("Settings")) { sheet = .settings }
                    Button(OBSLocale.menu("Basic.MainMenu.File.Exit"), action: requestQuit)
                }
                Menu(OBSLocale.menu("Basic.MainMenu.Edit")) {
                    Button(OBSLocale.menu("Basic.MainMenu.Edit.Undo")) { obs_app_undo(false); model.refresh() }
                        .disabled(!obs_app_can_undo(false))
                    Button(OBSLocale.menu("Basic.MainMenu.Edit.Redo")) { obs_app_undo(true); model.refresh() }
                        .disabled(!obs_app_can_undo(true))
                    if let item = model.selectedItem {
                        Button(OBSLocale.menu("Basic.MainMenu.Edit.Transform.EditTransform")) { sheet = .transform(item) }
                        Button(OBSLocale.str("Copy")) { model.withItem(item, obs_frontend_copy_sceneitem) }
                    }
                    if obs_frontend_can_paste_sceneitem(false) {
                        Button(OBSLocale.str("Paste")) {
                            model.editScene("Undo.PasteSourceRef") {
                                model.withCurrentScene { obs_frontend_paste_sceneitem($0, false) }
                            }
                        }
                    }
                    Button(OBSLocale.str("Basic.AdvAudio")) { sheet = .advancedAudio }
                }
                Menu(OBSLocale.menu("Basic.MainMenu.View")) {
                    Button(OBSLocale.str("Basic.Stats")) { sheet = .stats }
                    Button(OBSLocale.str("Projector.Title.Multiview")) { sheet = .multiview }
                    Menu(OBSLocale.str("Projector.Title")) {
                        Button(OBSLocale.str("StudioMode.Program")) { showProjector(.program) }
                        Button(OBSLocale.str("StudioMode.Preview")) { showProjector(.preview) }
                        Button(OBSLocale.str("Projector.Title.Multiview")) { showProjector(.multiview) }
                        if projectors.external != nil {
                            Button(OBSLocale.str("Close")) { projectors.external = nil }
                        }
                    }
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
                configurationMenu(profile: true)
                configurationMenu(profile: false)
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

    private func configurationMenu(profile: Bool) -> some View {
        let key = profile ? "Basic.MainMenu.Profile" : "Basic.MainMenu.SceneCollection"
        let names = ownedStringList(profile ? obs_frontend_get_profiles() : obs_frontend_get_scene_collections())
        let current = ownedString(profile ? obs_frontend_get_current_profile() : obs_frontend_get_current_scene_collection())
        return Menu(OBSLocale.menu(key)) {
            Button(OBSLocale.str("New")) {
                ask("New") { name in
                    if profile { obs_frontend_create_profile(name); model.refresh() }
                    else { finishConfiguration(obs_frontend_add_scene_collection(name)) }
                }
            }
            Button(OBSLocale.str("Duplicate")) {
                ask("Duplicate") { name in
                    if profile { obs_frontend_duplicate_profile(name); model.refresh() }
                    else { finishConfiguration(obs_app_duplicate_collection(name)) }
                }
            }
            Button(OBSLocale.str("Rename")) {
                ask("Rename", initial: current) { finishConfiguration(obs_app_rename_configuration(profile, $0)) }
            }
            Button(OBSLocale.str("Remove"), role: .destructive) {
                confirmation = NamePrompt(title: OBSLocale.str("Remove") + " — " + current) { _ in
                    finishConfiguration(obs_app_delete_configuration(profile, current))
                }
            }.disabled(names.count < 2)
            Button(OBSLocale.str(key + ".Import")) {
                importingProfile = profile
                showImporter = true
            }
            Button(OBSLocale.str(key + ".Export")) {
                obs_frontend_save()
                let path = ownedString(obs_app_configuration_path(profile))
                if !path.isEmpty { sheet = .export(URL(fileURLWithPath: path), OBSLocale.str(key + ".Export")) }
            }
            Divider()
            ForEach(names, id: \.self) { name in
                Button {
                    if profile { obs_frontend_set_current_profile(name) }
                    else { obs_frontend_set_current_scene_collection(name) }
                    model.refresh()
                } label: {
                    if name == current { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        }.disabled(model.streaming || model.recording || model.replay)
    }

    private func finishConfiguration(_ success: Bool) {
        if success { model.refresh() }
        else {
            outputError = OBSLocale.str("Basic.MainMenu.Profile.Exists")
            showError = true
        }
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
                    .overlay {
                        GeometryReader { geometry in
                            Color.clear.contentShape(Rectangle())
                                .gesture(SpatialTapGesture().onEnded { selectAt($0.location, size: geometry.size) })
                        }
                    }
                if let item = model.selectedItem {
                    SelectionOverlay(item: item, model: model)
                }
            } else {
                Text(OBSLocale.str("Basic.Main.PreviewDisabled"))
            }
        }
    }

    private func selectAt(_ location: CGPoint, size: CGSize) {
        var video = obs_video_info()
        guard obs_get_video_info(&video), video.base_width > 0, video.base_height > 0 else { return }
        let width = CGFloat(video.base_width)
        let height = CGFloat(video.base_height)
        let ratio = min(size.width / width, size.height / height)
        guard ratio > 0 else { return }
        let point = CGPoint(x: (location.x - (size.width - width * ratio) / 2) / ratio,
                            y: (location.y - (size.height - height * ratio) / 2) / ratio)
        for item in model.sources where item.visible {
            var contains = false
            model.withItem(item) { contains = obs_app_item_bounds($0).contains(point) }
            if contains { model.select(item); return }
        }
        if let selected = model.selectedItem { model.withItem(selected) { obs_sceneitem_select($0, false) } }
        model.selectedItem = nil
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
                        Button(OBSLocale.str("TransitionOverride")) { sheet = .override(scene) }
                        Button(OBSLocale.str("Projector.Open.Scene")) { showProjector(.source(scene.id)) }
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
                            model.editScene(item.visible ? "Undo.HideSceneItem" : "Undo.ShowSceneItem") {
                                model.withItem(item) { _ = obs_sceneitem_set_visible($0, !item.visible) }
                            }
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
        Button(OBSLocale.str("Projector.Open.Source")) { showProjector(.source(item.source.id)) }
        Menu(OBSLocale.menu("Basic.MainMenu.Edit.Transform")) {
            Button(OBSLocale.menu("Basic.MainMenu.Edit.Transform.EditTransform")) { sheet = .transform(item) }
            ForEach(WorkspaceModel.EditMode.allCases, id: \.self) { mode in
                Button(OBSLocale.menu(mode.rawValue)) { model.editMode = mode; model.select(item) }
            }
            Divider()
            Button(OBSLocale.menu("Basic.MainMenu.Edit.Transform.FitToScreen")) { alignCanvas(item, OBS_BOUNDS_SCALE_INNER) }
            Button(OBSLocale.menu("Basic.MainMenu.Edit.Transform.StretchToScreen")) { alignCanvas(item, OBS_BOUNDS_STRETCH) }
            Button(OBSLocale.menu("Basic.MainMenu.Edit.Transform.CenterToScreen")) { alignCanvas(item, OBS_BOUNDS_NONE) }
        }
        itemTransition(item, show: true)
        itemTransition(item, show: false)
        Menu(OBSLocale.menu("Basic.MainMenu.Edit.Order")) {
            Button(OBSLocale.menu("Basic.MainMenu.Edit.Order.MoveUp")) { move(item, OBS_ORDER_MOVE_UP) }
            Button(OBSLocale.menu("Basic.MainMenu.Edit.Order.MoveDown")) { move(item, OBS_ORDER_MOVE_DOWN) }
            Button(OBSLocale.menu("Basic.MainMenu.Edit.Order.MoveToTop")) { move(item, OBS_ORDER_MOVE_TOP) }
            Button(OBSLocale.menu("Basic.MainMenu.Edit.Order.MoveToBottom")) { move(item, OBS_ORDER_MOVE_BOTTOM) }
        }
        Button(OBSLocale.str("Rename")) {
            ask("Rename", initial: item.source.name) { name in
                model.editScene("Undo.Rename") { withSource(item.source.id) { obs_source_set_name($0, name) } }
            }
        }
        if item.isGroup {
            Button(OBSLocale.str("Basic.Main.Ungroup")) {
                model.editScene("Undo.GroupItems") { model.withItem(item, obs_sceneitem_group_ungroup) }
            }
        }
        Button(OBSLocale.str("Remove"), role: .destructive) { remove(item) }
    }

    private func alignCanvas(_ item: SceneItemReference, _ bounds: obs_bounds_type) {
        var video = obs_video_info()
        guard obs_get_video_info(&video) else { return }
        model.editScene("Undo.Transform") {
            model.withItem(item) { pointer in
                var info = obs_transform_info()
                obs_sceneitem_get_info2(pointer, &info)
                if bounds == OBS_BOUNDS_NONE {
                    let rect = obs_app_item_bounds(pointer)
                    info.pos.x += Float(CGFloat(video.base_width) / 2 - rect.midX)
                    info.pos.y += Float(CGFloat(video.base_height) / 2 - rect.midY)
                } else {
                    info.pos.x = 0
                    info.pos.y = 0
                    info.alignment = 5
                    info.bounds_alignment = 0
                    info.bounds_type = bounds
                    info.bounds.x = Float(video.base_width)
                    info.bounds.y = Float(video.base_height)
                }
                obs_sceneitem_set_info2(pointer, &info)
            }
        }
    }

    private func itemTransition(_ item: SceneItemReference, show: Bool) -> some View {
        Menu(OBSLocale.str(show ? "ShowTransition" : "HideTransition")) {
            Button(OBSLocale.str("None")) { setItemTransition(item, show: show, transition: nil) }
            ForEach(model.transitions) { transition in
                Button(transition.name) { setItemTransition(item, show: show, transition: transition) }
            }
            Button(OBSLocale.str("Properties")) {
                model.withItem(item) { pointer in
                    if let transition = obs_sceneitem_get_transition(pointer, show) {
                        sheet = .properties(SourceReference(transition))
                    }
                }
            }
        }
    }

    private func setItemTransition(_ item: SceneItemReference, show: Bool, transition: SourceReference?) {
        model.editScene(show ? "Undo.ShowTransition" : "Undo.HideTransition") {
            model.withItem(item) { item in
                let copy = transition.flatMap {
                    withSource($0.id) { obs_source_duplicate($0, obs_source_get_name($0), true) } ?? nil
                }
                obs_sceneitem_set_transition(item, show, copy)
                obs_sceneitem_set_transition_duration(item, show, UInt32(model.duration))
                obs_source_release(copy)
            }
        }
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
                Menu(OBSLocale.str("QuickTransitions")) {
                    ForEach(model.transitions) { kind in
                        Button(kind.name) { withSource(kind.id, obs_app_quick_transition) }
                    }
                }
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
            command("Exit", requestQuit)
        }
        .padding(5)
    }

    private func confirmOutput(_ key: String, _ title: String, _ action: @escaping () -> Void) {
        if config_get_bool(obs_frontend_get_user_config(), "BasicWindow", key) {
            confirmation = NamePrompt(title: OBSLocale.str(title), save: { _ in action() })
        } else { action() }
    }

    private func showProjector(_ selection: ProjectorSelection) {
        projectors.external = selection
        if projectors.externalScenes.isEmpty { localProjector = selection }
    }

    private func requestQuit() {
        let running = model.streaming || model.recording || model.replay
        if running && config_get_bool(obs_frontend_get_user_config(), "General", "ConfirmOnExit") {
            confirmation = NamePrompt(title: OBSLocale.str("Exit"), save: { _ in quit() })
        } else { quit() }
    }

    private func quit() {
        closing = true
        obs_frontend_streaming_stop()
        obs_frontend_recording_stop()
        obs_frontend_replay_buffer_stop()
        Task { @MainActor in
            while obs_frontend_streaming_active() || obs_frontend_recording_active() || obs_frontend_replay_buffer_active() {
                try? await Task.sleep(for: .milliseconds(50))
            }
            NotificationCenter.default.post(name: .obsDisplayWillReset, object: nil)
            obs_app_quit()
        }
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
        case .override(let scene): TransitionOverrideView(scene: scene, transitions: model.transitions)
        case .export(let url, let title):
            Form { ShareLink(item: url) { Label(title, systemImage: "square.and.arrow.up") } }
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
        model.editScene("Undo.Delete") { model.withItem(item, obs_sceneitem_remove) }
        model.selectedItem = nil
    }

    private func move(_ item: SceneItemReference, _ direction: obs_order_movement) {
        model.editScene("Undo.ReorderSources") { model.withItem(item) { obs_sceneitem_set_order($0, direction) } }
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
        case "Projector":
            switch (notification.userInfo?["type"] as? String)?.lowercased() {
            case "program": showProjector(.program)
            case "preview": showProjector(.preview)
            case "multiview": showProjector(.multiview)
            case "source", "scene":
                if let name = notification.userInfo?["name"] as? String,
                   let source = obs_get_source_by_name(name) {
                    showProjector(.source(SourceReference(source).id))
                    obs_source_release(source)
                }
            default: break
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

private func ownedString(_ value: UnsafeMutablePointer<CChar>?) -> String {
    guard let value else { return "" }
    defer { bfree(value) }
    return String(cString: value)
}
