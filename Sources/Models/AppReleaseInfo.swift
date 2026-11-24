import Foundation

struct ReleaseNoteEntry: Identifiable, Sendable {
    let version: String
    let date: String
    let highlights: [String]

    var id: String { version }
}

enum AppReleaseInfo {
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.1"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    static var displayVersion: String {
        "v\(shortVersion) (Build \(buildNumber))"
    }

    static let changelog: [ReleaseNoteEntry] = [
        ReleaseNoteEntry(
            version: "v1.0.1",
            date: "2026-11-24",
            highlights: [
                "新增 Liquid Glass 晶透应用图标 (AppIcon 1024×1024)",
                "建立 VERSION + CHANGELOG.md 版本体系与 CI 自动递增 Build 号",
                "首页及控制台新增当前版本号与版本更新日志面板",
                "修复冷启动闪退、Info.plist 覆盖、58 个 GLSL 着色器缺失与冗余占位框架问题"
            ]
        ),
        ReleaseNoteEntry(
            version: "v1.0.0",
            date: "2026-11-23",
            highlights: [
                "首发 iOS 26 双核播放器：MPV (MoltenVK + gpu-next + 58 个超分着色器) 与 VideoToolbox ANE 光流补帧核",
                "支持 120Hz ProMotion 时域平滑、本地视频导入、网络串流与 Liquid Glass 悬浮控制"
            ]
        )
    ]
}
