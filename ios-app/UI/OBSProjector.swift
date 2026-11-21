/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 自研必要性证明：OBSProjector 用 Qt/桌面显示器创建窗口。iOS 把窗口交给 UIKit 的
 * 外屏场景，实际绘制仍由工作区共用的 libobs CAMetalLayer 显示对象完成。 */

import SwiftUI

enum ProjectorSelection: Identifiable, Equatable {
    case program, preview, multiview
    case source(String)

    var id: String {
        switch self {
        case .program: "program"
        case .preview: "preview"
        case .multiview: "multiview"
        case .source(let identifier): identifier
        }
    }
}

@MainActor
final class OBSProjectors: ObservableObject {
    static let shared = OBSProjectors()
    @Published var external: ProjectorSelection?
    @Published private(set) var externalScenes: Set<String> = []

    func connect(_ scene: UISceneSession) { externalScenes.insert(scene.persistentIdentifier) }
    func disconnect(_ scene: UISceneSession) { externalScenes.remove(scene.persistentIdentifier) }
}

@objc(OBSProjectorSceneDelegate)
final class OBSProjectorSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ExternalOBSProjector())
        window.isHidden = false
        self.window = window
        OBSProjectors.shared.connect(session)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        OBSProjectors.shared.disconnect(scene.session)
    }
}

private struct ExternalOBSProjector: View {
    @ObservedObject private var projectors = OBSProjectors.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let selection = projectors.external {
                OBSProjectorView(selection: selection).id(selection.id)
            }
        }
    }
}

struct OBSProjectorView: View {
    let selection: ProjectorSelection
    @StateObject private var model = WorkspaceModel()

    var body: some View {
        Group {
            switch selection {
            case .program: OBSPreview()
            case .preview: OBSPreview(source: model.currentScene)
            case .source(let identifier): OBSPreview(source: identifier)
            case .multiview: MultiviewView(model: model)
            }
        }
        .background(.black)
        .foregroundStyle(.white)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OBSFrontendAction"))) { event in
            if event.object as? String == "Event" { model.refresh() }
        }
    }
}
