import Foundation

struct ReleaseNoteEntry: Identifiable, Sendable {
    let version: String
    let date: String
    let highlights: [String]

    var id: String { version }
}

enum AppReleaseInfo {
    static let releaseTag = "0.1.0-beta.6"

    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    static var displayVersion: String {
        "v\(releaseTag) (Build \(buildNumber))"
    }

    static let changelog: [ReleaseNoteEntry] = [
        ReleaseNoteEntry(
            version: "v0.1.0-beta.6",
            date: "2026-11-27",
            highlights: [
                "根治夸克原画直链请求超时（-1001）与无fallback 卡死：LocalHTTPStreamProxy 升级共享持久连接池（ProxyUpstreamSessionPool，12s 快速失败并回传真实 HTTP 504/502 状态与代理耗时日志）、QuarkDriveClient 透传刷新后的 __puus Cookie 并净化媒体下载请求头",
                "云端主流加载失败秒级自动降级：OpticalFlowPlayerController 新增 onRemoteStreamFailed 回调，原画直链超时或连接失败时自动无感切换至「夸克 4K / 2K / 1080P」HLS 流并保留续播进度",
                "异常提示弹窗新增一键「切换云端清晰度」与「刷新直链重试」恢复入口，无需返回重进片源列表"
            ]
        ),
        ReleaseNoteEntry(
            version: "v0.1.0-beta.5",
            date: "2026-11-27",
            highlights: [
                "根治「原画关闭画质增强掉至 ~100fps、开增强才满 120fps」差异：MetalVideoEnhancer 新增零滤镜 CAMetalLayer 原画直通模式 (allowPassthrough)，SDR 高刷光流 (60/96/120fps) 下的原画不再经过 AVSampleBufferDisplayLayer 分辨率重配置背压，不开滤镜同样锁满 120.0 fps",
                "全面对标 Infuse 8 影院级多手势与防误触体验：支持左/右双击 ±10s 连续叠加快进退、居中双击或双指轻点播放/暂停、长按屏幕 2.0× 临时倍速松手恢复、水平滑动精准拖进度、左半屏上下滑调亮度、右半屏上下滑调系统音量，以及独立防误触屏幕锁",
                "重塑首页与剧集连播体验：首页升级为极简顶栏 + 首屏 C 位「继续观看」宽银幕卡片墙 + 2 列「我的片源」网格 + 紧凑快速打开三联；支持云盘目录选集抽屉、自动连播下一集、多音轨切换、点击切换剩余时长与顶栏影片元数据展示"
            ]
        ),
        ReleaseNoteEntry(
            version: "v0.1.0-beta.4",
            date: "2026-11-27",
            highlights: [
                "根治在线视频 60/96/120fps 补帧掉帧与失效：RemoteStreamOpticalFlowWorker 新增分级分辨率上限（60/96fps 起步 540p、120fps 起步 480p）、有界双帧输入队列、OpticalFlowBudgetGuard 自动降分辨率/降档稳帧，以及动态自适应时钟滞后 (remotePacerLagSeconds) 与切档队列扩容，彻底消除 184353 日志中 978×720 超预算导致的 1222 帧批量丢弃",
                "新增纯原生字幕系统（内嵌软字幕 + 外挂 SRT/ASS/SSA/VTT）：支持云盘同目录字幕自动配对与 Emby 字幕轨发现、本地同目录自动挂载与文件导入，提供字号/底边距/配色/背景不透明度/±0.25s 时间偏移实时调节",
                "新增 Infuse 风格观看记录与断点续播体系：首页「继续观看」16:9 剧照进度卡片墙 +「全部记录」管理面板、云盘列表实时进度条与「续播/已看完」徽章，自动截取高清剧照并在暂停/退后台/返回主页时瞬时持久化进度"
            ]
        ),
        ReleaseNoteEntry(
            version: "v0.1.0-beta.3",
            date: "2026-11-27",
            highlights: [
                "彻底打通夸克网盘原画直链与云端转码播控：LocalHTTPStreamProxy 在线流式将 MP4 容器内的 hev1 SampleEntry 无损改写为 Apple AVPlayer 兼容的 hvc1（严格校验 Box 长度/分辨率/hvcC 避免误改 mdat），根治夸克 MP4 有声黑屏（pres=0, 0×0）",
                "修复云端 AVPlayerItemVideoOutput 输出格式与时序回退：补齐 420v 像素格式声明、移除未挂 AVPlayerLayer 下的 suppressesPlayerRendering 阻塞，并加入 3.5 秒云端黑屏看门狗自动切换至夸克 4K / 1080P HLS 流；同步 AppReleaseInfo.releaseTag 与 VERSION 一致性"
            ]
        ),
        ReleaseNoteEntry(
            version: "v0.1.0-beta.2",
            date: "2026-11-27",
            highlights: [
                "彻底解决 120fps 展开控制栏与超分弹窗掉帧：Frame 级遥测按 4Hz 节流发布、layoutDisplayLayer 全字段幂等防抖、高刷非超分直绘封顶 1600px 并接入 3 缓冲背压、剥离底栏 9 处嵌套 .glassEffect 并启用高刷轻量化描边 HUD",
                "重塑夸克网盘单机登录闭环：接入 uop.quark.cn 原生 CAS 二维码接口，支持一键「保存二维码并打开夸克 App」+ 2 秒自动轮询兑票与首访补齐 __puus；网页登录默认 .mobile 视口并补齐 WKUIDelegate/WKNavigationDelegate 跳转"
            ]
        ),
        ReleaseNoteEntry(
            version: "v0.1.0-beta.1",
            date: "2026-11-27",
            highlights: [
                "版本体系切换为初始 Beta 语义版本（v0.1.0-beta.1，CFBundleShortVersionString=0.1.0，Build 号随 CI 递增）",
                "零拷贝 FP16 Metal 直绘与温控减负：画质增强（非杜比视界/HDR）切换为 CAMetalLayer 全异步直绘，彻底移除每帧 waitUntilCompleted() 主线程阻塞与中间 YUV/UV 拷贝；48fps/60fps 解除 .latencyCritical 锁频，大幅缓解高帧率 + 去糊极速发热",
                "夸克网盘直连架构加固：新增纯原生 Network.framework (NWListener) 127.0.0.1 本地 HTTP Range / HLS 反向代理（跨 302 重定向保留 Cookie/Referer/UA 彻底根治 403）、自动回写 Set-Cookie 中的 __puus 续期，并将夸克登录 WebView 切换为桌面模式强校验凭证"
            ]
        ),
        ReleaseNoteEntry(
            version: "v2026.11.27",
            date: "2026-11-27",
            highlights: [
                "新增原生云端媒体库（夸克网盘 / Emby / WebDAV・Alist）：内置网页扫码提取夸克 Cookie、Emby 账户登录与直链/无损 HLS 流切换、离线高速缓存，云端片源全链路兼容 Metal 画质增强与 ANE 光流补帧",
                "彻底修复「老片去糊 / 低清超分」不明显、全核过热与按住对比失效：Metal 重构为单遍多尺度亮度去糊 + 防光晕 CAS（移除高耗时双边 exp），96/120fps 及过热下超分自动切省电直锐并将 .serious 温控降为 2×(48fps)，新增可点选「分屏对比 / 原画对比」且暂停态即时刷新",
                "最终敲定高实用帧率档位矩阵并接入能效保护：正式移除非 120Hz 整分频的 72fps，24p 收敛为「原画 / 48(2×清晰省电) / 60 / 96(高刷甜点) / 120 fps」，并按档位精准锁定 ProMotion 物理刷新率（48Hz / 60Hz / 120Hz）与 iOS 低电量模式 60Hz 上限",
                "彻底修复隐藏控制栏后掉帧及截图短暂恢复再降：消除 proMotionPulseLayer 同帧双次翻转抵消与圆角裁切，接入 .latencyCritical 全程提频、4K 硬件缩放 1080p 解码、VDEC/ANE 异步并行流水线及 OpticalFlowFramePacer",
                "支持重开 App 后保留上一次会话完整黑匣子诊断日志；完整支持杜比视界（Dolby Vision dvh1/dvhe）及 HDR10/HLG 峰值亮度输出"
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
