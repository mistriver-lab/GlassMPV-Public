import SwiftUI
import UIKit

final class GlassMPVAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated {
            OrientationController.shared.supportedMask
        }
    }
}

@main
struct GlassMPVApp: App {
    @UIApplicationDelegateAdaptor(GlassMPVAppDelegate.self) private var appDelegate
    @StateObject private var coordinator = PlayerCoordinator()

    var body: some Scene {
        WindowGroup {
            LiquidGlassPlayerView(coordinator: coordinator)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    coordinator.open(url: url, isSecurityScoped: url.isFileURL)
                }
        }
    }
}
