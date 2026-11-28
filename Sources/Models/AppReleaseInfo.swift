import Foundation

struct ReleaseNoteEntry: Identifiable, Sendable {
    let version: String
    let date: String
    let highlights: [String]

    var id: String { version }
}

enum AppReleaseInfo {
    static let releaseTag = "0.1.0-beta.14"

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
            version: "v0.1.0-beta.14",
            date: "2026-11-28",
            highlights: [
                "全新零降采样 Metal GPU 金字塔光流引擎 (MetalPyramidOpticalFlow)：60 / 96 / 120fps 彻底摆脱 Apple VTOpticalFlow (RGhA 32–46ms 超预算) 与静态背景符号错锁，在原分辨率 4K/1080p YUV 上实现亚像素真运动追踪、边缘保真与切镜无重影，静止文字背景 100% 锐利直出",
                "根治切画质「1440×810 闪烁式卡顿 + 600MB 内存飙升」：强制经 sourceNormPool 标准化送入 ANE 并为 1440×810 增加 1280×720 降级档与连续异常熔断器，彻底终结 -19740 会话泄漏循环",
                "单调送显时钟守卫 (RemoteDisplayCadenceGuard) + 动态高刷队列扩容（24/30/36 帧替代误丢帧的 14 帧硬上限）：杜绝超前直通帧与延迟队列帧交错倒跳，CI 新增真实 GPU 运动精度像素级回归测试"
            ]
        ),
        ReleaseNoteEntry(
            version: "v0.1.0-beta.13",
            date: "2026-11-28",
            highlights: [
                "全新原生 4K 120fps Flow-Warp v2 架构：60 / 96 / 120fps 全程保留 100% 原生 3840×2160 输出（告别降分辨率 720p/1080p 与 120fps 自动跌档 96fps）—— ANE 每对源码帧仅算 1 次 960×540 双向光流场，源像素格式切换高速 32BGRA（带宽砍半，摆脱 64-bit RGhA 拖慢）",
                "运行时真机光流向量自校准 (FlowVectorCalibrator)：首次出现动态帧即自动实测前后帧 SAD，实时锁定光流分量符号与像素/归一化单位，彻底根治向量轴向偏差引发的轮廓模糊",
                "Metal 5-tap 联合光度边缘吸附着色器 + 14 帧紧凑 4K 解码缓冲上限：边缘与遮挡区域自动对齐前景/背景最清晰原始 4K 纹理消除光晕重影，并释放空闲 4K 硬解表面彻底消除卡顿，日志实测上报真实 GPU 耗时"
            ]
        ),
        ReleaseNoteEntry(
            version: "v0.1.0-beta.12",
            date: "2026-11-28",
            highlights: [
                "画质与流畅度全面止损回稳：默认下线引发边沿重影模糊与 4K 解码池抢占卡顿的试验性 FlowWarp，恢复并强化稳定清晰的 ANE 硬件光流 + MetalFX 通道（2× 1080p、60/96/100fps 810p/720p、120fps 锁定 720p 并全面剔除 540p/480p 糊档）；25fps 片源选择 96fps 档自动对齐 100fps (4×) 整数甜点并解锁最高 2560×1440 MetalFX 重建",
                "彻底修复「无法切换画质流」与「切画质后卡死无画面」：播放器底栏新增一键「画质流切换」胶囊菜单并会在切换夸克片源时自动刷新直链防过期；QuarkDriveClient 按真实 format/扩展名判定 HLS 与 fMP4；LocalHTTPStreamProxy 根据 Content-Type/长度/#EXT 头嗅探自动将误标为 HLS 的二进制流退化为直传并在切流时立即清理旧缓存预读",
                "彻底消除初播界面按钮重叠 + 扩充 macOS 模拟器 E2E 自测门禁：PlayerOverlayLayoutPolicy 统一居中加载态并在预热/报错期避让中央播控按键、顶部续播提示自动避让左上 HUD，且切流不再清空遥测时间线；CI 新增 HLS/误标 fMP4 切换与双流端到端实播自测"
            ]
        ),
        ReleaseNoteEntry(
            version: "v0.1.0-beta.11",
            date: "2026-11-28",
            highlights: [
                "全新混合 4K 原生光流变形架构 (Hybrid 4K Flow-Warp)：彻底根治「60/96/120fps 4K 发糊」与「120fps 自动跌档 96fps」——针对 >1080p SDR 多倍补帧流，ANE 使用 iOS 26 VTOpticalFlowConfiguration 每次仅计算 1 次轻量级双向光流场 (640×360/854×480)，不再受 2^x-1 全像素合成 40ms 算力天花板掣肘",
                "全分辨率 4K 双向遮挡感知 Metal Warp Shader (displayFlowWarpYUVFragment)：GPU 直接以零拷贝采样前后两帧原始 3840×2160 YUV 纹理生成任意中间相位帧（原帧与插帧同为真 4K 原生输出、零降采样糊化），内置前向/后向一致性校验与转场瞬间保护机制防止撕裂重影",
                "保留已被实机验证无损的 2× (LowLatency 1080p + MetalFX 1440p) 及 HDR/Dolby Vision 安全回退通道，并对 4K 原始帧一并解锁 2560px 全屏 Retina 绘制上限"
            ]
        ),
        ReleaseNoteEntry(
            version: "v0.1.0-beta.10",
            date: "2026-11-27",
            highlights: [
                "根治「开 120fps 依然模糊」：RemoteOpticalFlowBudgetPlanner 淘汰 480p 糊档并锁定 120fps 从 720p(1280×720) 起跑、最低 540p；VTOpticalFlowEngine 对降采样光流解除 1600px 图层封顶解锁 2560px 全屏渲染；MetalVideoEnhancer 将原画 MetalFX 重建提升至 1080p/1440p 并叠加零光晕轻量下采样纹理恢复",
                "根治「120fps 仅 28ms 却连降三级到 60fps」与卡顿恢复跌至 2fps：修复降档后误调用 budgetGuard.reset() 抹除 30 对冷却期的 Bug，增加 isCatchUpOverload 耗时门限、6 帧输入队列与 8 对冷启动预热；handleRemoteDisplayTick 冻结缓冲暂停时钟并一次性跳过突发陈旧帧",
                "根治 5.86GB 真 4K 每 9 秒卡死 4~6 秒：LocalHTTPStreamProxy 新增 ProxyRouteChunkCache（4 路并发 2MB 预读 + 32MB LRU 缓存）与 ParallelChunkedStreamRelay 拉取流式直传，修复挂起态 cancel() 连接池锁死并提升前向缓冲至 20s"
            ]
        ),
        ReleaseNoteEntry(
            version: "v0.1.0-beta.9",
            date: "2026-11-27",
            highlights: [
                "彻底消除 4K 高刷「一闪一闪发糊」频闪：RemoteStreamOpticalFlowWorker 原帧输出与插帧同分辨率基准对齐（消除 480p/360p ×4 ↔ 4K ×1 的 25Hz 锐度闪烁），移除 360p/288p 劣化档并抬高底线至 2×(1080p/720p)、60/96fps(720p/540p)、120fps(540p/480p)，同步增加 4 帧对冷启动预热豁免",
                "原画降采样光流自动 MetalFX 重建：MetalVideoEnhancer 针对原画+降采样光流帧自动启用硬件 MTLFXSpatialScaler 零锐化感知重建，显著拉回 4K→720p/540p/480p 补帧观感",
                "彻底优化 5.86GB 真 4K 加载卡顿与开关补帧假死 30s：LocalHTTPStreamProxy 新增 MP4 Box-Aware 状态机零拷贝跳过多 GB mdat 数据块并接入 NWConnection 4MB/1MB 滑动窗口背压；OpticalFlowPlayerController 支持云端流在线热开关补帧、10s 前向缓冲及 0.5s 关键帧快跳"
            ]
        ),
        ReleaseNoteEntry(
            version: "v0.1.0-beta.8",
            date: "2026-11-27",
            highlights: [
                "彻底根治「夸克实时流开 120fps 原画必须开画质增强才能满帧」的三重真因（基于 212117 实机黑匣子日志）：(1) VTOpticalFlowEngine 将 96/120fps 的 ProMotion 刷新率下限由 80Hz 锁死至 120Hz，消除隐藏 HUD 后系统自动跌至 80Hz 的半速掉帧",
                "(2) RemoteStreamOpticalFlowWorker 缓存上一帧 480p 预处理缓冲（eliminating 2× 4K->480p 重复缩放，sourceNormPool 扩容至 6、pendingInputs 扩容至 3），并将预处理耗时纳入 BudgetGuard 真实计时",
                "(3) MetalVideoEnhancer 为 65fps 以上原画接入无锐化无偏色的 3×3 中性 Mitchell-Netravali 立方采样直绘（compareMode == 3，原画高刷直绘），防止极轻 1-tap Shader 导致 GPU/内存总线降频拖慢 ANE 至 35ms+"
            ]
        ),
        ReleaseNoteEntry(
            version: "v0.1.0-beta.7",
            date: "2026-11-27",
            highlights: [
                "深度对标 Infuse 8 商业级信息架构：全新原生 3 Tab 底部导航（「首页」继续观看+收藏夹+本地离线片库 / 「片源」NavigationStack 原生推入浏览 / 「设置」独立分组配置），支持任意云盘/Emby/WebDAV 目录右上角一键星标钉选到首页收藏，两步直达追剧",
                "彻底重塑极简影院级播放 HUD 与统一齿轮面板：移除底部杂乱 10 颗彩色胶囊，引入上下影院暗角渐变、4~5 键克制底栏，将视频增强/画质流切换/多音轨/字幕样式/倍速/片头设定统一收口进 Infuse 风格「⚙️ 视频｜音频｜字幕｜播放」四分区设置面板",
                "补齐核心追剧微交互闭环：默认开启连续播放下一集（片尾 15s 自动浮现「即将播放下一集」倒计时卡片）、双指捏合屏幕缩放比例（适应↔铺满）、可按剧集目录记忆秒数的「跳过片头」胶囊，以及 10s/15s/30s 自定义快进退步长"
            ]
        ),
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
