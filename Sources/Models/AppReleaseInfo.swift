import Foundation

struct ReleaseNoteEntry: Identifiable, Sendable {
    let version: String
    let date: String
    let highlights: [String]

    var id: String { version }
}

enum AppReleaseInfo {
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    static var displayVersion: String {
        "v\(shortVersion) (Build \(buildNumber))"
    }

    static let changelog: [ReleaseNoteEntry] = [
        ReleaseNoteEntry(
            version: "v2026.11.25",
            date: "2026-11-25",
            highlights: [
                "修复 iOS 26 本地视频选择器点击无反应：切换原生 UIDocumentPickerViewController(asCopy: true) 并补齐相册权限描述与 Inbox 安全拷贝",
                "新增 MPV 风格常驻关键信息 HUD：未开补帧也能实时显示编码、分辨率、源/输出帧率、色深/HDR、硬解状态、丢帧与设备温度",
                "打通 MPVUI 真实解码帧率与光流核 1s 滑动窗口实测帧率遥测，支持一键显隐状态角标",
                "全面切换东八区日期时间版本号体系（CalVer：YYYY.MM.DD / YYYYMMDDHHMM）",
                "修复 MPV 120Hz 时域平滑插帧（interpolation-threshold=-1 + tscale=linear）与 ANE 光流核会话参数/像素格式池/首帧时钟竞态，新增 ANE 诊断日志采集",
                "新增 4K 片源自动禁用超分门控（SuperResolutionPolicy）：≥3840×2160 时自动屏蔽 GLSL 与 ANE 2× 超分",
                "新增默认横屏起播与手动旋转切换（OrientationController）、一键返回主界面及一键导出 .txt 完整诊断日志",
                "消除播放页顶部 Liquid Glass 按钮粘黏并精简顶栏（移除重复的打开文件/相册/串流按钮，引擎切换改为单胶囊分段控件）",
                "修复 ANE 光流核黑屏与失效（补齐 controlTimebase、消除切引擎 startAt/seek 竞态、规范像素格式与色彩附件传播、增加追帧保护与真实帧率回显），并升级 MPV 120Hz 时域平滑为 tscale=mitchell + interpolation-preserve=yes"
            ]
        ),
        ReleaseNoteEntry(
            version: "v1.1.0",
            date: "2026-11-24",
            highlights: [
                "切换开源 SwiftUI 播放器底座 MPVUI (0.11.0)，保留 Metal gpu-next 58 个超分着色器管线",
                "新增系统相册直选 (PhotosPicker) 与后台异步沙盒安全拷贝，修复本地文件打不开问题",
                "修复 ANE 光流补帧 DisplayImmediately 时间轴同步与静默吞错，暴露成功/失败帧遥测",
                "诊断中心新增「一键真机 5 项体检」与完整体检报告导出"
            ]
        ),
        ReleaseNoteEntry(
            version: "v1.0.2",
            date: "2026-11-24",
            highlights: [
                "修复无法播放与死锁隐患：改用 addSublayer、mpv_command_async 与非阻塞 EDR 更新",
                "新增端内播放诊断中心、错误横幅与一键内置 3 秒测试视频自测",
                "本地文件导入增加 NSFileCoordinator 沙盒协调拷贝兜底",
                "接入 CI iOS 模拟器 XCTest 自动实播自测与经验沉淀文档"
            ]
        ),
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
