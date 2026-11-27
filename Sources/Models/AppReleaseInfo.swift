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
            version: "v2026.11.27",
            date: "2026-11-27",
            highlights: [
                "最终敲定高实用帧率档位矩阵并接入能效保护：正式移除非 120Hz 整分频的 72fps，24p 收敛为「原画 / 48(2×清晰省电) / 60 / 96(高刷甜点) / 120 fps」，并按档位精准锁定 ProMotion 物理刷新率（48Hz / 60Hz / 120Hz）与 iOS 低电量模式 60Hz 上限，大幅降低中低档功耗发热",
                "彻底修复隐藏控制栏后掉帧及截图短暂恢复再降：消除 proMotionPulseLayer 同帧双次翻转抵消与圆角裁切，接入 .latencyCritical 全程提频、4K 硬件缩放 1080p 解码、VDEC/ANE 异步并行流水线及 OpticalFlowFramePacer（55ms 容错 + 逐 VSync 单帧弹出 + 迟滞追赶）",
                "解决多相档位切换并重构智能源适配帧率弹窗：多相 2× 以上统一从 720p 起跑并支持 540p/480p 阶梯降档；底栏瘦身为两行并升级为折叠式智能帧率弹窗（自动匹配 24p/30p/60p 片源与 120Hz 屏幕整分频档位：48/60/96/120 fps）",
                "支持重开 App 后保留上一次会话完整黑匣子诊断日志（避免重启导出空白报告）；完整支持杜比视界（Dolby Vision dvh1/dvhe）及 HDR10/HLG 峰值亮度输出"
            ]
        ),
        ReleaseNoteEntry(
            version: "v2026.11.26",
            date: "2026-11-26",
            highlights: [
                "修复 ANE 发热与降档风暴：按 Apple 2^x-1 指数规则传入 VTLowLatencyFrameInterpolationConfiguration，优先选择原生 4:2:0/32-bit 像素格式替代 51MB RGhA，VTDecompressionSession 强制原生硬解并消除双次 VTPixelTransferSession 拷贝",
                "新增片源 AVAssetReader 透传缓存（跳过重复 -12906 探测）、暂停挂起 CADisplayLink 与按目标帧率动态设置 preferredFrameRateRange、保留降档冷却期 + 时钟追平护栏及 ThermalState .serious/.critical 主动限档",
                "精细化 4K 超分门控与开关状态保存：4K 下自动复位预设并放行 KrigBilateral / Adaptive Sharpen，修复 MPV ↔ ANE 切换覆盖 .off 及暂停态误起播",
                "升级诊断日志全链路：保留退回主界面前的 lastSessionSummary 防归零，新增 [ui-switch] 审计流、设备型号/内存/队列深度/音画差 Timeline 指标与 HH:mm:ss.SSS 毫秒级 500 条环形缓冲",
                "新增 ANE 光流核多档位目标帧率（2× / 60 / 72 / 96 / 120fps）：支持 2 的幂倍率优先 LowLatency 与非 2 的幂（如 24→60/72/120）优先 FRC 双后端协同",
                "新增 OpticalFlowPhaseScheduler（整倍等分 + 非整倍时间栅格重采样）与单次多缓冲 process 调用，配合动态预缓冲与「先降分辨率后降帧率」算力预算守卫（OpticalFlowBudgetGuard）",
                "根治 ANE 4K 光流 -19730 失败：新增 OpticalFlowResolutionPlanner 自动将 4K 降档至 1080p/720p/540p 等比偶对齐档位并结合系统维度边界过滤",
                "打通 LowLatency 与 VTFrameRateConversion (FRC) 双后端协商，保留池原生 IOSurfaceProperties 并支持运行期首帧异常自动降档切后端自愈与日志防刷屏",
                "在控制台、HUD、真机 5 项体检与诊断导出中实时透出目标/实测档位分段控制及激活的 ANE 光流后端标签（activeBackendLabel）"
            ]
        ),
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
                "修复 ANE 光流核黑屏失效并升级 MPV 时域平滑：为 AVSampleBufferDisplayLayer 绑定 controlTimebase、规范像素格式与色彩附件传播、增加追帧保护，MPV 升级 tscale=mitchell",
                "重构双引擎补帧链路与真实遥测：ANE 新增无音轨单调合成时钟、preferredTransform 自动旋转排版、首帧延迟挂载缓存、requiresFlushToResumeDecoding 恢复及 6 帧预缓冲；MPV 新增 ProMotion 120Hz 刷新率保活与无兜底伪造的同步/重绘遥测",
                "新增运行期 2s 黑匣子遥测时间轴、libmpv 属性探针与补帧客观判定；切入 ANE 时自动释放 MPV 硬解会话，ANE 启用纯音轨合成、5 级 AVAssetReader 回退及源帧标准化，MPV 4K 片源自适应切换 tscale=linear",
                "新增 ANE 光流核 -11833/-12906 压缩透传 + HEVCFormatNormalizer + VTDecompressionSession 硬解兜底与 B 帧 PTS 重排，新增轨道格式描述日志与停播去重；明确区分「MPV 时域平滑」与「ANE 硬件光流真补帧」语义"
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
