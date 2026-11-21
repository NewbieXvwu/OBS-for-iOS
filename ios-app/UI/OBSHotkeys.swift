/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 自研必要性证明：iOS 硬件按键从 UIResponder 到达前台应用。将 UIKit
 * 键码映射到 libobs 的按键与修饰键，沿用原版热键绑定和分发。 */

import SwiftUI

private struct Hotkey: Identifiable {
    let id: Int
    let name: String
    let title: String
    let frontend: Bool
}

private final class HotkeyList {
    var items: [Hotkey] = []
}

private func collectHotkey(_ data: UnsafeMutableRawPointer?, _ id: Int, _ hotkey: OpaquePointer?) -> Bool {
    guard let data, let name = obs_hotkey_get_name(hotkey), let title = obs_hotkey_get_description(hotkey) else { return true }
    let frontend = obs_hotkey_get_registerer_type(hotkey) == OBS_HOTKEY_REGISTERER_FRONTEND
    Unmanaged<HotkeyList>.fromOpaque(data).takeUnretainedValue().items.append(
        Hotkey(id: id, name: String(cString: name), title: String(cString: title), frontend: frontend))
    return true
}

private func collectBinding(_ data: UnsafeMutableRawPointer?, _ index: Int, _ binding: OpaquePointer?) -> Bool {
    guard let data, let binding else { return true }
    Unmanaged<HotkeyBindings>.fromOpaque(data).takeUnretainedValue().items[obs_hotkey_binding_get_hotkey_id(binding), default: []]
        .append(obs_hotkey_binding_get_key_combination(binding))
    return true
}

private final class HotkeyBindings {
    var items: [Int: [obs_key_combination_t]] = [:]
}

struct OBSHotkeySettings: View {
    @State private var hotkeys: [Hotkey] = []
    @State private var bindings: [Int: [obs_key_combination_t]] = [:]
    @State private var capturing: Hotkey?

    var body: some View {
        Section(OBSLocale.str("Basic.Settings.Hotkeys")) {
            ForEach(hotkeys) { hotkey in
                VStack(alignment: .leading, spacing: 5) {
                    Text(OBSLocale.str(hotkey.title))
                    ForEach(Array((bindings[hotkey.id] ?? []).enumerated()), id: \.offset) { index, key in
                        HStack {
                            Text(description(key)).font(.body.monospaced())
                            Spacer()
                            Button {
                                var revised = bindings[hotkey.id] ?? []
                                revised.remove(at: index)
                                save(hotkey, revised)
                            } label: {
                                Label(OBSLocale.str("Remove"), systemImage: "minus.circle")
                            }.labelStyle(.iconOnly).buttonStyle(.borderless)
                        }
                    }
                    Button(capturing?.id == hotkey.id ? OBSLocale.str("Cancel") : OBSLocale.str("Add")) {
                        capturing = capturing?.id == hotkey.id ? nil : hotkey
                    }.buttonStyle(.borderless)
                }
            }
        }
        .background {
            if let capturing {
                OBSKeyboardInput { key in
                    var keys = bindings[capturing.id] ?? []
                    if !keys.contains(where: { $0.key == key.key && $0.modifiers == key.modifiers }) {
                        keys.append(key)
                        save(capturing, keys)
                    }
                    self.capturing = nil
                }
                .frame(width: 1, height: 1)
            }
        }
        .onAppear { refresh() }
    }

    private func description(_ key: obs_key_combination_t) -> String {
        var result = ""
        if key.modifiers & INTERACT_CONTROL_KEY.rawValue != 0 { result += "⌃" }
        if key.modifiers & INTERACT_ALT_KEY.rawValue != 0 { result += "⌥" }
        if key.modifiers & INTERACT_SHIFT_KEY.rawValue != 0 { result += "⇧" }
        if key.modifiers & INTERACT_COMMAND_KEY.rawValue != 0 { result += "⌘" }
        return result + String(cString: obs_key_to_name(key.key)).replacingOccurrences(of: "OBS_KEY_", with: "")
    }

    private func refresh() {
        let list = HotkeyList()
        let current = HotkeyBindings()
        obs_enum_hotkeys(collectHotkey, Unmanaged.passUnretained(list).toOpaque())
        obs_enum_hotkey_bindings(collectBinding, Unmanaged.passUnretained(current).toOpaque())
        hotkeys = list.items
        bindings = current.items
    }

    private func save(_ hotkey: Hotkey, _ keys: [obs_key_combination_t]) {
        var revised = keys
        revised.withUnsafeMutableBufferPointer {
            obs_hotkey_load_bindings(hotkey.id, $0.baseAddress, $0.count)
        }
        if hotkey.frontend {
            let array = obs_hotkey_save(hotkey.id)
            let data = obs_data_create()
            obs_data_set_array(data, "bindings", array)
            let profile = obs_frontend_get_profile_config()
            config_set_string(profile, "Hotkeys", hotkey.name, obs_data_get_json(data))
            _ = config_save_safe(profile, "tmp", "bak")
            obs_data_release(data)
            obs_data_array_release(array)
        }
        obs_frontend_save()
        refresh()
    }
}

struct OBSKeyboardInput: UIViewRepresentable {
    var capture: ((obs_key_combination_t) -> Void)? = nil

    func makeUIView(context: Context) -> OBSKeyboardReceiver { OBSKeyboardReceiver() }
    func updateUIView(_ view: OBSKeyboardReceiver, context: Context) {
        view.capture = capture
        if view.window != nil && !view.isFirstResponder { view.becomeFirstResponder() }
    }
}

final class OBSKeyboardReceiver: UIView {
    var capture: ((obs_key_combination_t) -> Void)?
    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, pressed: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, pressed: false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, pressed: false) { super.pressesCancelled(presses, with: event) }
    }

    private func handle(_ presses: Set<UIPress>, pressed: Bool) -> Bool {
        var handled = false
        for press in presses {
            guard let key = press.key, let combination = translate(key) else { continue }
            if let capture {
                if pressed { capture(combination) }
                handled = true
            } else {
                obs_hotkey_inject_event(combination, pressed)
            }
        }
        return handled
    }

    private func translate(_ key: UIKey) -> obs_key_combination_t? {
        let obsKey = obs_key_from_virtual_key(Int32(key.keyCode.rawValue))
        guard obsKey != OBS_KEY_NONE else { return nil }
        let flags = key.modifierFlags
        var modifiers: UInt32 = 0
        if flags.contains(.shift) { modifiers |= INTERACT_SHIFT_KEY.rawValue }
        if flags.contains(.control) { modifiers |= INTERACT_CONTROL_KEY.rawValue }
        if flags.contains(.alternate) { modifiers |= INTERACT_ALT_KEY.rawValue }
        if flags.contains(.command) { modifiers |= INTERACT_COMMAND_KEY.rawValue }
        return obs_key_combination_t(modifiers: modifiers, key: obsKey)
    }
}
