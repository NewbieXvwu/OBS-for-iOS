/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 自研必要性证明：OBS 的 OBSQTDisplay 管理 Qt/NSView。UIKit 与 SwiftUI 提供原生视图，
 * 此处只在其生命周期内挂接原版 libobs 显示对象。 */

import QuartzCore
import SwiftUI

@main
struct OBSApp: App {
    @StateObject private var locale = OBSLocale()
    private let running: Bool

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let config = support.appendingPathComponent("OBS", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            let language = OBSLocale.resolve(UserDefaults.standard.string(forKey: OBSLocale.preferenceKey) ?? "")
            running = obs_app_start(language, config.path)
            if running, ProcessInfo.processInfo.arguments.contains("--recording-smoke") {
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let run = ProcessInfo.processInfo.environment["OBS_SMOKE_RUN"] ?? "manual"
                obs_app_recording_smoke(
                    documents.appendingPathComponent("phase1-\(run).mp4").path,
                    ProcessInfo.processInfo.environment["OBS_TEST_RTMP"] ?? ""
                )
            }
        } catch {
            running = false
            NSLog("OBS configuration directory: %@", error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            if running {
                WorkspaceView()
                    .environmentObject(locale)
                    .preferredColorScheme(.dark)
            }
        }
    }
}

struct OBSPreview: UIViewRepresentable {
    var source: String? = nil

    func makeUIView(context: Context) -> OBSMetalView { OBSMetalView() }
    func updateUIView(_ uiView: OBSMetalView, context: Context) { uiView.show(source) }

    static func dismantleUIView(_ uiView: OBSMetalView, coordinator: Void) {
        uiView.detachDisplay()
    }
}

final class OBSMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var display: OpaquePointer?
    private var source: String?
    private var resetting = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(willReset),
                                               name: .obsDisplayWillReset, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didReset),
                                               name: .obsDisplayDidReset, object: nil)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    @objc private func willReset() {
        resetting = true
        detachDisplay()
    }

    @objc private func didReset() {
        resetting = false
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { detachDisplay() }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !resetting, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let width = UInt32(bounds.width * contentScaleFactor)
        let height = UInt32(bounds.height * contentScaleFactor)
        if let display {
            obs_app_display_resize(display, width, height)
        } else {
            display = obs_app_create_display(self, width, height)
            bindSource()
        }
    }

    func detachDisplay() {
        if let display {
            obs_app_display_destroy(display)
            self.display = nil
        }
    }

    func show(_ identifier: String?) {
        guard source != identifier else { return }
        source = identifier
        bindSource()
    }

    private func bindSource() {
        guard let display else { return }
        if let source {
            withSource(source) { obs_app_display_set_source(display, $0) }
        } else {
            obs_app_display_set_source(display, nil)
        }
    }
}
