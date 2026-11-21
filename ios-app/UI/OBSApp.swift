/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 自研必要性证明：OBS 的 OBSQTDisplay 管理 Qt/NSView。UIKit 与 SwiftUI 提供原生视图，
 * 此处只在其生命周期内挂接原版 libobs 显示对象。 */

import QuartzCore
import SwiftUI

@main
struct OBSApp: App {
    private let running: Bool

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let config = support.appendingPathComponent("OBS", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            running = obs_app_start("en-US", config.path)
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
                OBSPreview()
            }
        }
    }
}

private struct OBSPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> OBSMetalView { OBSMetalView() }
    func updateUIView(_ uiView: OBSMetalView, context: Context) {}

    static func dismantleUIView(_ uiView: OBSMetalView, coordinator: Void) {
        uiView.detachDisplay()
    }
}

final class OBSMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var display: OpaquePointer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { detachDisplay() }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let width = UInt32(bounds.width * contentScaleFactor)
        let height = UInt32(bounds.height * contentScaleFactor)
        if let display {
            obs_display_resize(display, width, height)
        } else {
            display = obs_app_create_display(self, width, height)
        }
    }

    func detachDisplay() {
        if let display {
            obs_display_destroy(display)
            self.display = nil
        }
    }
}
