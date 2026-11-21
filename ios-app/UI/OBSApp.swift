/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 自研必要性证明：OBS 的 OBSQTDisplay 管理 Qt/NSView。UIKit 与 SwiftUI 提供原生视图，
 * 此处只在其生命周期内挂接原版 libobs 显示对象。 */

import QuartzCore
import SwiftUI

@main
final class OBSApplicationDelegate: UIResponder, UIApplicationDelegate {
    let locale = OBSLocale()
    private(set) var running = false
    private var migratedWindows: [String: UIWindow] = [:]

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = session.configuration
        configuration.sceneClass = UIWindowScene.self
        configuration.delegateClass = session.role == .windowApplication ?
            OBSWorkspaceSceneDelegate.self : OBSProjectorSceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var config = support.appendingPathComponent("OBS", isDirectory: true)
        if let testRun = ProcessInfo.processInfo.environment["OBS_WORKSPACE_SMOKE_RUN"],
           ProcessInfo.processInfo.arguments.contains("--workspace-smoke") {
            config.appendPathComponent("smoke", isDirectory: true)
            config.appendPathComponent(testRun, isDirectory: true)
        }
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
        if running {
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(suspendDisplays),
                               name: UIApplication.willResignActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(enterBackground),
                               name: UIApplication.didEnterBackgroundNotification, object: nil)
            center.addObserver(self, selector: #selector(resumeDisplays),
                               name: UIApplication.didBecomeActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(restoreWorkspace),
                               name: UIScene.didActivateNotification, object: nil)
            center.addObserver(self, selector: #selector(disconnectWorkspace),
                               name: UIScene.didDisconnectNotification, object: nil)
        }
        return true
    }

    @objc private func enterBackground() {
        suspendDisplays()
        obs_frontend_save()
    }

    @objc private func resumeDisplays() {
        obs_ios_set_video_suspended(false)
        _ = obs_ios_set_keepalive(false)
        NotificationCenter.default.post(name: .obsDisplayDidReset, object: nil)
    }

    @objc private func suspendDisplays() {
        NotificationCenter.default.post(name: .obsDisplayWillReset, object: nil)
        let background = obs_ios_get_capabilities() & UInt32(OBS_IOS_CAP_BACKGROUND_GPU.rawValue) != 0
        if !background || !obs_ios_set_keepalive(true) {
            obs_ios_set_video_suspended(true)
        }
    }

    @objc private func restoreWorkspace(_ notification: Notification) {
        // Versions using a SwiftUI WindowGroup may restore a session with its former delegate configuration.
        guard let scene = notification.object as? UIWindowScene, scene.session.role == .windowApplication,
              !(scene.delegate is OBSWorkspaceSceneDelegate),
              migratedWindows[scene.session.persistentIdentifier] == nil else { return }
        let window = OBSWorkspaceSceneDelegate.makeWindow(scene, app: self)
        migratedWindows[scene.session.persistentIdentifier] = window
        window.makeKeyAndVisible()
    }

    @objc private func disconnectWorkspace(_ notification: Notification) {
        if let scene = notification.object as? UIScene {
            migratedWindows.removeValue(forKey: scene.session.persistentIdentifier)
        }
    }
}

@objc(OBSWorkspaceSceneDelegate)
final class OBSWorkspaceSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene,
              let app = UIApplication.shared.delegate as? OBSApplicationDelegate else { return }
        let window = Self.makeWindow(scene, app: app)
        self.window = window
        window.makeKeyAndVisible()
    }

    static func makeWindow(_ scene: UIWindowScene, app: OBSApplicationDelegate) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        if app.running {
            let workspace = WorkspaceView().environmentObject(app.locale).preferredColorScheme(.dark)
            window.rootViewController = OBSWorkspaceHost(rootView: workspace)
        } else {
            window.rootViewController = UIHostingController(rootView: Text("OBS"))
        }
        return window
    }
}

private final class OBSWorkspaceHost<Content: View>: UIHostingController<Content> {
    private var projectorRegistration: AnyObject?

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 27.0, *) {
            let configuration = UISceneConfiguration()
            configuration.delegateClass = OBSProjectorSceneDelegate.self
            let accessory = UISceneAccessory.externalNonInteractive(sceneConfiguration: configuration)
            projectorRegistration = registerSceneAccessory(accessory)
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
