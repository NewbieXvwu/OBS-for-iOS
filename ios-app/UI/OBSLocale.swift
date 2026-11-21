/* SPDX-License-Identifier: GPL-2.0-or-later */

import Foundation
import SwiftUI

final class OBSLocale: ObservableObject {
    static let preferenceKey = "OBS.Locale"
    static let directory = Bundle.main.resourceURL!.appendingPathComponent("OBSData/locale")
    static let languages: [String] = (try? FileManager.default.contentsOfDirectory(at: directory,
        includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "ini" }
        .map { $0.deletingPathExtension().lastPathComponent }.sorted() ?? ["en-US"]

    @Published var selection: String {
        didSet {
            UserDefaults.standard.set(selection, forKey: Self.preferenceKey)
            let language = Self.resolve(selection)
            obs_set_locale(language)
            obs_app_frontend_reload_locale(language)
        }
    }

    init() {
        selection = UserDefaults.standard.string(forKey: Self.preferenceKey) ?? ""
    }

    static func resolve(_ selection: String) -> String {
        if languages.contains(selection) { return selection }
        for identifier in Locale.preferredLanguages {
            let canonical = identifier.replacingOccurrences(of: "_", with: "-")
            if let same = languages.first(where: { $0.caseInsensitiveCompare(canonical) == .orderedSame }) {
                return same
            }
            if canonical.hasPrefix("zh-Hant"), languages.contains("zh-TW") { return "zh-TW" }
            if canonical.hasPrefix("zh-Hans"), languages.contains("zh-CN") { return "zh-CN" }
            let language = canonical.split(separator: "-").first
            if let same = languages.first(where: { $0.split(separator: "-").first == language }) {
                return same
            }
        }
        return "en-US"
    }

    static func str(_ key: String, module: String? = nil) -> String {
        key.withCString { text in
            if let module, let plugin = obs_get_module(module), let value = obs_module_get_locale_text(plugin, text) {
                return String(cString: value)
            }
            guard let result = obs_frontend_get_locale_string(text) else { return key }
            return String(cString: result)
        }
    }

    static func menu(_ key: String) -> String {
        str(key).replacingOccurrences(of: "&", with: "")
    }
}
