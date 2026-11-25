import Combine
import UIKit

/// 屏幕方向管理器：打开视频默认进入横屏，支持播放页手动旋转，返回主界面自动恢复竖屏
@MainActor
final class OrientationController: ObservableObject {
    static let shared = OrientationController()

    @Published private(set) var isLandscapeLocked: Bool = false
    private(set) var supportedMask: UIInterfaceOrientationMask = .allButUpsideDown

    private init() {}

    func enterVideoLandscape() {
        supportedMask = .landscape
        isLandscapeLocked = true
        requestGeometry(.landscape)
    }

    func toggleVideoOrientation() {
        if isLandscapeLocked {
            supportedMask = .portrait
            isLandscapeLocked = false
            requestGeometry(.portrait)
        } else {
            supportedMask = .landscape
            isLandscapeLocked = true
            requestGeometry(.landscape)
        }
    }

    func returnToHomeOrientation() {
        supportedMask = .allButUpsideDown
        isLandscapeLocked = false
        requestGeometry(.portrait)
    }

    private func requestGeometry(_ orientations: UIInterfaceOrientationMask) {
        let windowScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        for scene in windowScenes {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
        }
    }
}
