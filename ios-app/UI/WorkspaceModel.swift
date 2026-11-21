/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 自研必要性证明：OBSBasic 的源列表与选中状态由 Qt 模型保存。
 * SwiftUI 的列表直接读取 libobs 的对象标识，编辑仍走原版场景项接口。 */

import SwiftUI

struct SourceReference: Identifiable, Hashable {
    let id: String
    let name: String

    init(_ source: OpaquePointer) {
        id = String(cString: obs_source_get_uuid(source))
        name = String(cString: obs_source_get_name(source))
    }
}

struct SceneItemReference: Identifiable, Hashable {
    let source: SourceReference
    let scene: String
    let item: Int64
    let depth: Int
    let visible: Bool
    let locked: Bool
    let isGroup: Bool
    var id: String { "\(scene):\(item)" }
}

struct SourceKind: Identifiable {
    let id: String
    let name: String
}

@discardableResult
func withSource<Result>(_ uuid: String, _ body: (OpaquePointer) -> Result) -> Result? {
    guard let source = obs_get_source_by_uuid(uuid) else { return nil }
    defer { obs_source_release(source) }
    return body(source)
}

private final class SceneItemCollector {
    var items: [SceneItemReference] = []
    var depth = 0
}

private func collectSceneItem(_ scene: OpaquePointer?, _ item: OpaquePointer?, _ pointer: UnsafeMutableRawPointer?) -> Bool {
    guard let scene, let item, let pointer, let source = obs_sceneitem_get_source(item) else { return true }
    let collector = Unmanaged<SceneItemCollector>.fromOpaque(pointer).takeUnretainedValue()
    let group = obs_sceneitem_is_group(item)
    let sceneId = String(cString: obs_source_get_uuid(obs_scene_get_source(scene)))
    collector.items.append(SceneItemReference(source: SourceReference(source), scene: sceneId,
        item: obs_sceneitem_get_id(item), depth: collector.depth, visible: obs_sceneitem_visible(item),
        locked: obs_sceneitem_locked(item), isGroup: group))
    if group {
        collector.depth += 1
        obs_sceneitem_group_enum_items(item, collectSceneItem, pointer)
        collector.depth -= 1
    }
    return true
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var scenes: [SourceReference] = []
    @Published private(set) var sources: [SceneItemReference] = []
    @Published private(set) var transitions: [SourceReference] = []
    @Published private(set) var currentTransition = ""
    @Published private(set) var currentScene = ""
    @Published private(set) var studio = false
    @Published private(set) var streaming = false
    @Published private(set) var recording = false
    @Published private(set) var paused = false
    @Published private(set) var replay = false
    @Published var selectedItem: SceneItemReference?
    @Published var duration = 300
    @Published var tbar = 0.0
    @Published var previewEnabled = true
    @Published var editMode = EditMode.proportional
    @Published private(set) var inputKinds: [SourceKind] = []

    enum EditMode: String, CaseIterable {
        case proportional = "Basic.TransformWindow.Size"
        case stretch = "Basic.MainMenu.Edit.Transform.StretchToScreen"
        case crop = "Basic.TransformWindow.Crop"
    }

    init() {
        reloadSourceKinds()
        refresh()
    }

    func reloadSourceKinds() {
        var kinds: [SourceKind] = []
        var index = 0
        var id: UnsafePointer<CChar>?
        var unversioned: UnsafePointer<CChar>?
        while obs_enum_input_types2(index, &id, &unversioned) {
            defer { index += 1 }
            guard let id, let unversioned, let latest = obs_get_latest_input_type_id(unversioned),
                  strcmp(id, latest) == 0, let name = obs_source_get_display_name(id) else { continue }
            let flags = obs_get_source_output_flags(id)
            if flags & UInt32(OBS_SOURCE_CAP_DISABLED | OBS_SOURCE_CAP_OBSOLETE) == 0 {
                kinds.append(SourceKind(id: String(cString: id), name: String(cString: name)))
            }
        }
        inputKinds = kinds.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func refresh() {
        scenes = sourceList(obs_frontend_get_scenes)
        transitions = sourceList(obs_frontend_get_transitions)
        studio = obs_frontend_preview_program_mode_active()
        previewEnabled = obs_frontend_preview_enabled()
        duration = Int(obs_frontend_get_transition_duration())
        tbar = Double(obs_frontend_get_tbar_position())
        streaming = obs_frontend_streaming_active()
        recording = obs_frontend_recording_active()
        paused = obs_frontend_recording_paused()
        replay = obs_frontend_replay_buffer_active()
        if let transition = obs_frontend_get_current_transition() {
            currentTransition = SourceReference(transition).id
            obs_source_release(transition)
        }
        refreshSources()
    }

    func refreshSources() {
        let source = studio ? obs_frontend_get_current_preview_scene() : obs_frontend_get_current_scene()
        guard let source else {
            sources = []
            currentScene = ""
            return
        }
        defer { obs_source_release(source) }
        currentScene = SourceReference(source).id
        guard let scene = obs_scene_from_source(source) else { return }
        let collector = SceneItemCollector()
        obs_scene_enum_items(scene, collectSceneItem, Unmanaged.passUnretained(collector).toOpaque())
        sources = Array(collector.items.reversed())
        if let item = selectedItem { selectedItem = sources.first { $0.id == item.id } }
    }

    func pickScene(_ scene: SourceReference) {
        withSource(scene.id) { source in
            if studio { obs_frontend_set_current_preview_scene(source) }
            else { obs_frontend_set_current_scene(source) }
        }
        refreshSources()
    }

    func addScene(_ name: String) {
        guard !name.isEmpty else { return }
        obs_source_release(obs_app_create_scene(name))
        refresh()
    }

    func moveScene(_ scene: SourceReference, by amount: Int) {
        guard let index = scenes.firstIndex(of: scene) else { return }
        withSource(scene.id) { obs_app_move_scene($0, Int32(index + amount)) }
        refresh()
    }

    func removeScene(_ scene: SourceReference) {
        withSource(scene.id, obs_app_remove_scene)
        refresh()
    }

    func withCurrentScene(_ body: (OpaquePointer) -> Void) {
        withSource(currentScene) { source in
            if let scene = obs_scene_from_source(source) { body(scene) }
        }
    }

    func addSource(_ kind: SourceKind, name: String) {
        editScene("Undo.Add") {
            withCurrentScene { scene in
                guard let source = obs_source_create(kind.id, name, nil, nil) else { return }
                defer { obs_source_release(source) }
                if let item = obs_scene_add(scene, source) { obs_sceneitem_select(item, true) }
            }
        }
    }

    func nestScene(_ nested: SourceReference) {
        editScene("Undo.Add") {
            withCurrentScene { scene in
                withSource(nested.id) { source in _ = obs_scene_add(scene, source) }
            }
        }
    }

    func groupSelected(_ name: String) {
        editScene("Undo.GroupItems") {
            withCurrentScene { scene in
                guard let group = obs_scene_add_group(scene, name) else { return }
                if let selectedItem, selectedItem.depth == 0 {
                    withItem(selectedItem) { obs_sceneitem_group_add_item(group, $0) }
                }
            }
        }
    }

    func withItem(_ item: SceneItemReference, _ body: (OpaquePointer) -> Void) {
        withSource(item.scene) { source in
            guard let scene = obs_group_or_scene_from_source(source), let found = obs_scene_find_sceneitem_by_id(scene, item.item)
            else { return }
            body(found)
        }
    }

    func select(_ item: SceneItemReference) {
        if let selectedItem { withItem(selectedItem) { obs_sceneitem_select($0, false) } }
        selectedItem = item
        withItem(item) { obs_sceneitem_select($0, true) }
    }

    func saveSources() {
        obs_frontend_save()
        refreshSources()
    }

    func snapshot() -> String? {
        guard let data = withSource(currentScene, obs_app_snapshot_scene) ?? nil else { return nil }
        defer { obs_data_release(data) }
        return obs_data_get_json(data).map { String(cString: $0) }
    }

    func finishEdit(_ key: String, from before: String?, repeatable: Bool = false) {
        if let before, let after = snapshot() {
            obs_frontend_add_undo_redo_action(OBSLocale.str(key), obs_app_restore_scene, obs_app_restore_scene,
                                             before, after, repeatable)
        }
        saveSources()
    }

    func editScene(_ key: String, _ edit: () -> Void) {
        let before = snapshot()
        edit()
        finishEdit(key, from: before)
    }

    func setTransition(_ identifier: String) {
        withSource(identifier, obs_frontend_set_current_transition)
        refresh()
    }

    func toggleStudio() {
        obs_frontend_set_preview_program_mode(!studio)
        refresh()
    }

    private func sourceList(_ enumerate: (UnsafeMutablePointer<obs_frontend_source_list>) -> Void) -> [SourceReference] {
        var list = obs_frontend_source_list()
        enumerate(&list)
        defer { obs_frontend_source_list_free(&list) }
        guard let array = list.sources.array else { return [] }
        return (0..<list.sources.num).compactMap { array[$0].map(SourceReference.init) }
    }
}
