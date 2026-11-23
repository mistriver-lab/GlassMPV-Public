import SwiftUI

@main
struct GlassMPVApp: App {
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
