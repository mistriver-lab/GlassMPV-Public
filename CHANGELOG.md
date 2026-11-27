# 更新日志 (Changelog)

本项目采用初始 Beta 语义版本规范（`v0.1.0-beta.x`，Bundle 内部短版本号 `0.1.0` + 递增 Build 号）。

## [v0.1.0-beta.5] - 2026-11-27

### 新增与优化 (Added & Improved)
- **零滤镜 `CAMetalLayer` 原画 120fps 直通 (`MetalVideoEnhancer` + `VTOpticalFlowEngine`)**：
  - 针对 `192203` 实机日志定位的「关闭画质增强时 `AVSampleBufferDisplayLayer` 因 `656×480 ↔ 2960×2160` 分辨率频繁切换产生背压导致帧率跌至 ~100fps」，为 `renderToLayerStatus` 新增 `allowPassthrough` 零滤镜直绘路径（命中 Shader `compareMode == 2` 纯 YUV→RGB/BGRA 硬件直出），使高刷原画与原画对比同样全程稳定锁满 `120.0 fps`。
- **对标 Infuse 8 的完整影院手势与防误触锁 (`PlayerGestureOverlay` + `PlayerGestureFeedbackOverlay`)**：
  - 实现 5 路协调原生手势：左/右双击 ±10s 连击叠加、中间双击 / 双指轻点播放暂停、长按 2.0× 临时快进（松手自动恢复）、水平滑动非线性精准 Seek、左半屏上下滑调亮度、右半屏上下滑调系统音量，并配备独立屏幕锁与精美半透明反馈浮层。
- **全面对标 Infuse 8 首页、剧集连播与多音轨 (`LiquidGlassPlayerView` + `CloudMediaLibraryView` + `MediaSourceModels`)**：
  - **首页重塑**：极简顶栏 + 首屏 C 位 `248×140`「继续观看」卡片墙 + 2 列「我的片源」网格 + 紧凑三联快速打开 + 单行增强预设胶囊。
  - **播放体验细节**：顶栏展示影片标题与来源/分辨率/HDR 标签；居中大号盲按播控（快退/播放/快进/上集/下集）；底栏支持点击切换总时长/剩余时长、多音轨选择（`AVMediaSelectionGroup.audible`）与云盘目录剧集抽屉（`EpisodePlaylistSheet`），非循环模式下播完自动连播下一集。

## [v0.1.0-beta.4] - 2026-11-27

### 新增与修复 (Added & Fixed)
- **根治 `184353` 实机日志定位的在线视频高刷补帧失效 (`RemoteStreamOpticalFlowWorker` + `VTOpticalFlowEngine`)**：
  - **分级远程分辨率规划 (`RemoteOpticalFlowBudgetPlanner`)**：`2×` 保持 720p 起步；`60fps / 96fps` 收敛至 `540p → 480p → 360p`；`120fps` 收敛至 `480p → 360p → 288p`，并接入 `OpticalFlowBudgetGuard` 在推理超源帧间隔时自动降分辨率或降档稳帧，防止 `58~61ms` 推理打穿 `41.7ms` 帧预算。
  - **有界双帧输入队列 + 动态 Pacer 时钟滞后 + 切档扩容**：将单槽覆盖升级为 2 帧 FIFO；在 `enqueueRemoteInterpolatedFrames` 根据实测 `avgMs` 平滑调节 `remotePacerLagSeconds`（`0.095~0.195s`）并放宽 `OpticalFlowFramePacer` 宽限窗至 `75ms`，同步在在线切换档位时重算 `maxQueuedFrames`，彻底消除成批丢帧与帧率坍缩。
- **新增纯原生字幕系统 (`SubtitleModels` + `SubtitleManager` + `LiquidGlassPlayerView` + `MediaSourceClients`)**：
  - 支持 UTF-8 / UTF-16 / GB18030 自动解码与 `.srt` / `.vtt` / `.ass` / `.ssa` 完整解析、二分检索区间匹配；支持视频内嵌 `legible` 软字幕（远程 `AVPlayerItemLegibleOutput` + 本地 `AVAssetReader`）、云盘同目录字幕自动发现（夸克 / WebDAV / Emby）及外挂文件导入。
  - 播放底栏新增「字幕」面板，支持开关、轨道切换及字号/底边距/颜色/背景不透明度/时间偏移（±0.25s）实时调节。
- **新增 Infuse 风格直观观看记录 (`WatchHistoryStore` + `LiquidGlassPlayerView` + `CloudMediaLibraryView`)**：
  - 首页新增「继续观看」横向 16:9 剧照卡片墙（显示片源标签、剩余时长、进度条与上下文菜单）及「全部记录」管理面板；云盘目录行内置进度条与「续播 MM:SS / ✓ 已看完」标记。
  - 自动截取播放画面剧照、每 6 秒及暂停/切后台/退出时实时落盘 `watch_history.json`，支持点击一键断点续播或从头播放。

## [v0.1.0-beta.3] - 2026-11-27

### 变更与修复 (Changed & Fixed)
- **彻底解决 `172520` 实机日志定位的夸克云端原画有声黑屏 (`Decoder: hev1`, `pres=0`, `0×0`) (`LocalHTTPStreamProxy` + `VTOpticalFlowEngine` + `LiquidGlassPlayerView` + `MediaSourceModels`)**：
  - **流式 MP4 `hev1 → hvc1` 在线重封装 (`patchHEV1ToHVC1` + `MP4HEV1StreamPatcher`)**：基于 ISO BMFF `VisualSampleEntry` 结构约束（Box 长度、`reserved[6]`、`data_reference_index`、合理分辨率、`depth=0x0018`、`pre_defined=0xFFFF` 与 `hvcC`）在 `127.0.0.1` 代理滑动窗口内将 `hev1` 原地改写为 `hvc1`（零长度漂移、零 `mdat` 误伤），使 `AVPlayer` 可直接硬解夸克 `hev1` HEVC MP4。
  - **云端 `AVPlayerItemVideoOutput` 与黑屏看门狗自动切流**：为 `AVPlayerItemVideoOutput` 显式声明 `kCVPixelBufferPixelFormatTypeKey = 420v`、移除无 `AVPlayerLayer` 时的 `suppressesPlayerRendering`、在 `.readyToPlay` 按轨道 `naturalSize` 兜底元数据，并在 `itemTime(forHostTime:)` 无效时回退 `player.currentTime()`；新增 3.5s 无画面看门狗，自动切换至未尝试的 `夸克 4K / 1080P` HLS 流或给出精准引导；全面传递 `PlaybackMediaRequest.isHLS`。
  - **版本一致性加固 (`AppReleaseInfo` + `test_project_integrity.py`)**：将 `AppReleaseInfo.releaseTag` 同步至 `0.1.0-beta.3` 并补全 `beta.2`/`beta.3` 更新日志，门禁新增 `VERSION` 与 `AppReleaseInfo.releaseTag` 强一致断言。

## [v0.1.0-beta.2] - 2026-11-27

### 变更与修复 (Changed & Fixed)
- **彻底解决 `164451` 实机日志定位的展开控制栏掉帧 (`120fps → 81.4/46.5fps`) (`MetalVideoEnhancer` + `VTOpticalFlowEngine` + `LiquidGlassPlayerView`)**：
  - **遥测 4Hz 节流 + 布局幂等防抖**：将 `presentedFrameCount`/`droppedFrames`/`interpolatedFrameCount`/`skippedInterpolationCount`/`averageInterpolationMs`/`actualOutputFPS`/`latestAVDeltaMs`/`averageQualityEnhanceMs` 收敛至内部 `raw*` 计数器，统一按 4Hz（0.25s）节流发布 `@Published`（仅首帧、暂停、切换对比或导出采样强制全量刷新），同时将音频周期时间观察器与合成时钟同步降至 4Hz，彻底消除开启 HUD 时每帧触发 SwiftUI 重排与 120×/s 无效重绘 `metalLayer`。
  - **高刷直绘分辨率上限 + 3 缓冲背压保护 (`renderToLayerStatus`)**：96/120fps 非超分直绘将 `CAMetalLayer` 长边上限从 `2560px`（~3.0M 像素）降至 `1600px`（~1.15M 像素）降低 60% 片元与合成带宽，并通过 `MetalInFlightCounter` + `renderToLayerStatus` 在 3 帧在途忙碌时跳过冗余编码（`.skippedBusy`），杜绝主线程被 `nextDrawable()` 阻塞。
  - **去嵌套高刷轻量化 HUD**：移除底栏内部 9 处嵌套 `.glassEffect(...)` 避免双层毛玻璃模糊叠加，在 96/120fps 播放期将底部控制栏与帧率/画质弹窗切换为与左上角悬浮窗同款低开销半透明描边卡片，彻底释放 GPU 合成压力。
- **重塑单台手机可用的夸克网盘扫码/网页登录与 `__puus` 兜底 (`MediaSourceClients` + `CloudMediaLibraryView` + `Info.plist`)**：
  - **原生夸克 CAS 扫码通道 (`uop.quark.cn`)**：新增 `requestQRLoginToken`、`pollQRLoginTicket` 与 `exchangeServiceTicketForCookie` 完整原生链路，内置 CoreImage 清晰二维码生成、一键「保存二维码并打开夸克 App (`quark://`)」及后台切回自动 2s 轮询兑票，无需第二台手机即可单机完成登录，并声明 `NSPhotoLibraryAddUsageDescription` 与 `LSApplicationQueriesSchemes`。
  - **移动端网页登录与 `__puus` 自动补齐 (`bootstrapSessionCookie`)**：`QuarkWebLoginSheet` 网页标签默认启用 `.mobile` 视口并补齐 `WKUIDelegate`/`WKNavigationDelegate`（支持弹窗跳转与外链拉起 `quark://`/`weixin://`），提取或验证时自动调用根目录首访触发 `Set-Cookie: __puus` 滚动补齐与持久化，扫码/提取完成后自动触发账号校验并保存退出。

## [v0.1.0-beta.1] - 2026-11-27

### 变更与修复 (Changed & Fixed)
- **切换初始 Beta 版本体系 (`VERSION` + `project.yml` + `build-ios.yml` + `AppReleaseInfo`)**：
  - 停止使用日期版本号，统一切换为 `v0.1.0-beta.1`（`MARKETING_VERSION = 0.1.0`、`CURRENT_PROJECT_VERSION` 随 CI Run Number 自动递增），IPA 统一命名为 `GlassMPV-0.1.0-beta.1-b<N>-unsigned.ipa`。
- **零拷贝异步 FP16 `CAMetalLayer` 直绘与温控重构 (`MetalVideoEnhancer` + `VTOpticalFlowEngine`)**：
  - 针对 `160642` 实机日志反馈的画质增强极速发热（`5.55ms` 同步等待 + `+36MB` 中间拷贝），将非 HDR/杜比视界画质增强切换为 `CAMetalLayer` 异步 Fragment Shader 直绘：移除 `waitUntilCompleted()` 与冗余 `copyChroma` / 中间 `CVPixelBufferPool`，采用 16-bit `half` 硬件双线性 5 点多尺度采样；`2× (48fps)` 与 `60fps` 不再锁死 `.latencyCritical`，显著降低功耗与机身发热。
- **纯原生 `LocalHTTPStreamProxy` 根治夸克 403 与 `__puus` 续期 (`LocalHTTPStreamProxy` + `MediaSourceClients` + `CloudMediaLibraryView`)**：
  - 基于 Apple `Network.framework` (`NWListener`) 构建轻量 `127.0.0.1` HTTP Range / HLS 代理，在 302 重定向与 `.m3u8` 分片期间完整透传 `Cookie / Referer / User-Agent`，并自动捕获响应头 `Set-Cookie` 回写 `__puus` 续期至 Keychain；夸克登录 WebView 切换至 `.desktop` 桌面模式并强校验 `__puus`/`__pus`。

## [v2026.11.27] - 2026-11-27

### 变更与修复 (Changed & Fixed)
- **新增原生云端片源体系：夸克网盘 / Emby / WebDAV・Alist (`MediaSourceModels` + `MediaSourceClients` + `RemoteStreamOpticalFlowWorker` + `CloudMediaLibraryView` + `VTOpticalFlowEngine`)**：
  - **夸克网盘**：内置 `WKWebView` 网页一键登录提取 Cookie（存系统 Keychain），调用 `drive-pc.quark.cn` 浏览目录与 `file/download` + `file/v2/play`，`MP4/MOV` 优先原画直链，播放底栏支持一键切换「原画直链 / 夸克 4K / 1080P」，非原生封装自动切云端流，亦支持离线高速缓存至本地以解锁完整 `AVAssetReader` 120fps。
  - **Emby & WebDAV / Alist**：支持 LAN/HTTP（配置 `NSAppTransportSecurity`）与 HTTPS 登录、海报墙、剧集季集浏览、`原画直链 / 无损 HLS` 智能切换与 `PROPFIND` 目录解析。
  - **云端流媒体 ANE + Metal 管线**：通过 `AVPlayerItemVideoOutput` + 独立并发 `RemoteStreamOpticalFlowWorker` 接入，确保远程 HTTP/HLS 视频流同样支持实时 Metal 画质增强与 ANE 光流补帧。
- **彻底修复 `153158` 实机日志反馈的过热、超分去糊微弱与对比原画不生效 (`VideoEnhancementOptions` + `MetalVideoEnhancer` + `VTOpticalFlowEngine` + `LiquidGlassPlayerView`)**：
  - 移除高耗时 8 邻域双边 `exp()`，重构为**单遍多尺度（1px+2px 半径）邻域限幅 Luma 去糊 + 死区抑制 + 防光晕 CAS + 深色描边**；`MetalFX` 新增热功耗预算守卫（`outputFPS > 65` 或过热自动降为省电直锐，日常 60fps 封顶 1080p）。
  - 修复过热保护档位：`ThermalState.serious` 由 `60fps [×4]` 下调至 `2×(48fps)` 以快速降温并保持高清晰度；`presentFrame` 缓存最近原始帧，无论**暂停或播放中**切换预设、强度、「**分屏对比（左原画|右增强）**」或「**原画对比**」均可零延迟即时刷新屏幕。
- **新增实时 Metal + MetalFX GPU 画质增强引擎 (`VideoEnhancementOptions` + `MetalVideoEnhancer` + `VTOpticalFlowEngine` + `LiquidGlassPlayerView`)**：
  - 针对「假 4K 高压缩发糊老片」：上线纯亮度通道（Y-Plane）保边双边去噪 + 对比度自适应锐化（Luma CAS）+ 去灰微反差管线，直通 `420v/420f/x420/xf20`（零彩边光晕且完整保留 10-bit HDR10/HLG 亮度空间）。
  - 针对「480p/720p/1080p 低清视频」及「60/96/120fps 高帧率 720p 光流帧」：在 `MTLCommandBuffer` 单次提交链中串联 `YUV→BGRA 预降噪` → `MTLFXSpatialScaler` 感知重建（最高 2560×1440，模拟器自动回退双三次超分）→ `CAS` 收尾锐化。
  - 提供「原画 / 老片去糊 / 动漫强化 / 低清超分」4 档预设 + 「轻度 / 标准 / 强力」3 级强度及底栏 **`画质` 快捷弹窗 + `按住对比原画`**，杜比视界自动旁路保护原厂映射。
- **最终敲定实用帧率档位体系、按档位精准锁屏与低电量保护 (`OpticalFlowOptions` + `VTOpticalFlowEngine` + `LiquidGlassPlayerView`)**：
  - 结合 ProMotion 物理分频（`240Hz` 整除限制）与 A17 Pro ANE 指数算力阶梯，正式移除非整除微颤的 `72fps` 鸡肋档位，确立「24p→原画 / 48(2×清晰省电) / 60 / 96(4×高刷甜点) / 120 fps；30p→原画 / 60 / 120 fps；60p→原画 / 120 fps」最终矩阵。
  - `recommendedDisplayFrameRateRange` 改为按档位精准锁频：`48fps` 锁原生 `(48, 48, 48)`、`60fps` 锁原生 `(60, 60, 60)`、`96/120fps` 锁 `(80, 120, 120)`，减少中低档 50%~60% 主线程唤醒与屏幕功耗；新增 `effectivePowerThermalCap` 监听 `NSProcessInfoPowerStateDidChange`，iOS 低电量模式下自动封顶 `60fps` 并锁 60Hz，杜绝 60Hz 屏幕上限下 ANE 白烧 `120fps` 算力；`OpticalFlowFramePacer` 同步将 `earlySnapSeconds` 微调至 `0.006s` 巩固 48/60Hz 锁相。
- **彻底解决隐藏操作栏掉帧与「截图后短暂恢复又降回 24fps」问题 (`VTOpticalFlowEngine`)**：
  - `131253` 实机日志证实：一方面 `handleUpdateLinkTick()` 与 `onDisplayTick()` 在同一 RunLoop 事务内双次调用 `pulseProMotionCommit()` 导致透明度翻转互相抵消且 `(0,0,1,1)` 被 OLED 圆角裁切；另一方面 HID/HUD 隐去后系统 CLPC 降低能效配额，使 4K 串行「硬解→缩放→ANE」单对周期从 `<35ms` 滑向 `>42ms`，队列耗尽后批量到达的帧在 `onDisplayTick` 同帧丢光中间帧导致帧率悬崖坍缩。
  - 修复：① 将 `proMotionPulseLayer` 移至安全区活跃视口内（`x >= 64, y >= 12, 2×2`）并确保每 VSync 仅提交 1 次位姿+透明度变化；② 开启光流期间激活 `.latencyCritical` Activity、4K 解码期即启用 `1920×1080` 硬件缩放、通过 `OpticalFlowDecodedFramePipe` 将硬解 (VDEC) 与 ANE 推理拆分为高优先级并行生产者-消费者流水线；③ 新增 `OpticalFlowFramePacer`（55ms 容错 + 每 VSync 至多送显 1 帧）与 `-45ms / +85ms` 迟滞追赶，并在预算守卫计入全周期墙钟耗时。
- **根治隐藏控制栏后掉回 24Hz 与 `72fps` 起步分辨率过高，重构智能源适配帧率菜单 (`OpticalFlowOptions` + `VTOpticalFlowEngine` + `LiquidGlassPlayerView`)**：
  - 实机截图证实隐藏控制栏（`showHUD = false`）后 `AVSampleBufferDisplayLayer` 未产生 CoreAnimation 图层提交，导致 iPhone 15 Pro Max ProMotion 与 `CADisplayLink` 被系统降至 24Hz（`actualOutputFPS` 从 `57.9` 跌至 `23.4` 而 `droppedFrames` 暴涨）。现通过 `UIUpdateLink(requiresContinuousUpdates=true, wantsImmediatePresentation=true)` + `1×1` 微扰层保活，并在开启补帧且 120Hz 屏幕下锁定 `(80, 120, 120)` 刷新率区间，彻底消除 HUD 隐藏退化与 60Hz 拍频丢帧。
  - 修复 `buildCandidatePlan` 中 `maxInterpolatedFrames == 2`（`72fps`/`3×`）误从 `1080p` 起步问题（现与 `60/96/120fps` 一致从 `720p` 起跑），降档链 `120 -> 96 -> 60 -> 2×` 自动避开非 120Hz 整除的 `72fps`。
  - 播放底栏精简为两行 + 弹出式 **智能源适配帧率选单 (`FrameRatePresetStrip`)**：自动按片源帧率展示清晰目标帧率卡片（24p→原画/48/60/96/120 fps；30p→原画/60/120 fps；60p→原画/120 fps），支持原地无感热切换与重启保留上次完整运行黑匣子日志。
- **根治补帧档位切换失效与热切换卡顿 (`OpticalFlowOptions` + `VTOpticalFlowEngine` + `LiquidGlassPlayerView`)**：
  - `095509` 实机日志证实 `UI Switch Audit` 零条 `setOpticalFlowTargetFPS` 记录，根因为 `OpticalFlowTargetFPS`/`InterpolationMode` 的 `id: String` 导致 SwiftUI `Picker + ForEach` 隐式 Tag 失配、点选 `60/72/96/120` 全部静默丢弃。现将 `id` 改为 `Self`，全面撤除 `Picker` 并改用直点式 `FrameRatePillStrip` 胶囊按钮条（支持首页预设、控制栏直切与控制台同步联动）。
  - 新增 `updateTargetConfiguration` + `applyUserSwitchInPlace`，播放中切换 `2×/60/72/96/120` 与 `2×超分` 时原地热替换 `VTFrameProcessor` 会话，不再重建 `AVPlayer` 音轨与 `AVAssetReader`。
- **全面打通杜比视界 (Dolby Vision) 与 HDR10 / HLG 播放 (`VTOpticalFlowEngine` + `PlaybackTelemetry` + `Info.plist`)**：
  - `HEVCFormatNormalizer` 优先保留 `dvh1` / `dvcC` / `dvvC` / `dvwC` 与主控/亮度静动态元数据（`MasteringDisplayColorVolume`、`ContentLightLevelInfo`、`AmbientViewingEnvironment`），`VTDecompressionSession` 启用 `kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata`。
  - 修复 Profile 5 杜比视界（无显式 PQ Transfer）被误判为 8-bit SDR 的问题，解码输出强制 `10-bit`（`x420`）并在缺失色彩附件时回填 BT.2020/PQ；`AVSampleBufferDisplayLayer` 开启 `preferredDynamicRange = .high` 与防休眠。
- **重塑美观极简 Liquid Glass 界面并移除内置 3 秒测试 (`LiquidGlassPlayerView`)**：
  - 移除首页与诊断中心中的「内置 3 秒自测视频」入口；默认隐藏参数浮窗（点右上角分辨率/杜比视界徽章显隐），控制栏播放 4.5s 自动淡出，并新增 `HDR/EDR`、`铺满全屏 (AspectFill)` 与 `循环播放` 快捷开关。
- **彻底移除 MPV 引擎与着色器 (`project.yml` + `VTOpticalFlowEngine`)**：
  - 移除 `MPVUI`/`MPVKit`、`MPVPlayerCore.swift` 与 58 个 `.glsl` 着色器；`120fps` 与全档位优先 `LowLatency (420v)`，关闭补帧时走跨平台 `AVAssetReader + VTDecompressionSession` 原帧率硬解直通。

## [v2026.11.26] - 2026-11-26

### 修复与增强 (Fixed & Enhanced)
- **ANE 光流能效优化、降档风暴治理与 4K 开关/日志全链路升级 (`ShaderPreset` + `PlaybackTelemetry` + `DiagnosticLogExporter` + `MPVPlayerCore` + `VTOpticalFlowEngine` + `LiquidGlassPlayerView`)**：
  - 修复 `VTLowLatencyFrameInterpolationConfiguration` 帧数参数按 Apple $2^x - 1$ 指数规则传值，避免 96fps 误开 7 级流水线；补齐 `selectOptimalPixelFormat`（`xf20`/`420f`/Lossless YUV/`32-bit` 优先，将 `RGhA`/`RGfA` 置末），强制 `VTDecompressionSession` 使用原生 `420v`/`x420` 硬解 4K，FRC 多相仅支持 `RGhA` 时直接从 720p 候选起跑并收敛队列上限（`<= 30`），消除 `processDecodedFrame` 双次 `VTPixelTransferSession` 冗余拷贝，并按片源 URL 缓存 `-12906` 透传跳过重复试探。
  - 移除降档后的 `budgetGuard.reset()` 保留冷却计数并新增 `awaitingClockCatchUpAfterSwitch` 护栏消除降档风暴；暂停时挂起 `CADisplayLink` 并按目标帧率动态设置 `preferredFrameRateRange`；接入 `ProcessInfo.ThermalState` `.serious`/`.critical` 主动限档。
  - 精细化 4K 门控（保留 `2960×2160` 判定，放行 `KrigBilateral`/`Adaptive Sharpen` 非放大着色器并同步复位 `coordinator` 预设），修复 MPV ↔ ANE 切换覆盖 `.off` 与暂停态调节设置擅自起播。
  - 升级诊断系统：新增 `DeviceDiagnosticsSampler`（`task_self_trap()` 内存采样与设备型号）、`lastSessionSummary` 停播防归零、`[ui-switch]` 交互审计流、Timeline 补齐 `backend`/`q`/`avDelta`/`mem`、日志精确至 `HH:mm:ss.SSS` 并扩容环形缓冲至 500 条。
- **新增 ANE 光流核多档位目标帧率（`2× / 60 / 72 / 96 / 120fps`）、相位时间栅格重采样与算力预算守卫 (`ShaderPreset` + `VTOpticalFlowEngine` + `PlaybackTelemetry` + `LiquidGlassPlayerView`)**：
  - 新增 `OpticalFlowTargetFPS` 五档目标帧率选择器，约束仅 `2×` 允许 `spatial2x` 空间超分，并按倍率自动调度双后端优先级（2 的幂倍率优先 `LowLatency`，非 2 的幂如 `24→60/72/120` 优先 `FRC`）。
  - 新增跨平台 `OpticalFlowPhaseScheduler`（整倍等分 + 非整倍时间栅格重采样）与单次多缓冲 `process` 调用，配合 `OpticalFlowResolutionPlanner.recommendedQueueLimits` 动态队列上限与 `OpticalFlowBudgetGuard`（「先降分辨率、再降帧率档位」滑窗过载/追帧自愈）。
  - 在控制台（分段选择器）、HUD、黑匣子采样、真机 5 项体检与诊断导出中全链路透出目标/实测档位（如 `120fps→96fps`）。
- **根治 ANE 4K 光流 `-19730` (`Processor is not initialized`) 与双后端自适应自愈 (`VTOpticalFlowEngine` + `LiquidGlassPlayerView`)**：
  - 新增跨平台 `OpticalFlowResolutionPlanner` 与 `OpticalFlowCandidate`，自动将 4K 片源（如 `2960×2160`、`3840×2160`）等比偶对齐降档至 `1080p` / `720p` / `540p`，并结合 `VTFrameProcessorConfiguration.minimumDimensions`/`maximumDimensions` 边界过滤。
  - 打通 `VTLowLatencyFrameInterpolationConfiguration` 与 `VTFrameRateConversionConfiguration`（`VTFrameRateConversionParameters` `.sequential`/`.random` 提交模式）双后端协商及 `ActiveOpticalFlowConfiguration` 状态机；修复 `CVPixelBufferPool` 池属性不覆盖 `IOSurfaceProperties`，并升级 `normalizeSourceBufferIfNeeded` 支持尺寸不匹配时硬件缩放对齐。
  - 新增首帧 `-19730` 运行期自动自愈链路（先启用源帧标准化池重试，再逐级降档并切换 FRC 后端，全部耗尽后熔断直通且防刷屏节流日志），并在 HUD、真机 5 项体检与诊断中心实时透出 `activeBackendLabel`。

## [v2026.11.25] - 2026-11-25

### 变更与修复 (Changed & Fixed)
- **修复 iOS 26 本地视频选择器点击无反应 (`NativeDocumentPickerPresenter` + `LocalMediaImporter` + `Info.plist`)**：移除在 Liquid Glass 与多层弹窗下偶发失效的 SwiftUI `.fileImporter`，改用原生 `UIDocumentPickerViewController(asCopy: true)` 并扩展 `.contentShape` 点击热区；补齐 `NSPhotoLibraryUsageDescription` 相册权限描述，同时收敛 `LocalMediaImporter` 缓存命中路径确保 Inbox 临时副本必经文件名净化拷贝至沙盒目录。
- **新增 MPV 风格常驻关键信息 HUD (`PlaybackTelemetry` + `LiquidGlassPlayerView`)**：在未开启补帧（原帧率）状态下亦可实时显示视频编码、分辨率、原帧率/实时输出帧率（补齐 `estimatedDecodedFramesPerSecond` 与 `AVSampleBufferDisplayLayer` 实测帧率采样）、色深/HDR（10-bit / HDR10 / HLG）、硬解/软解状态、丢帧计数与设备实时温度（`ProcessInfo.ThermalState`），精简布局且不受主控制栏自动隐藏影响，支持顶部 `info.circle` 按钮或右上角参数徽章一键显隐。
- **沉淀桌面端插帧深度剖析与 iOS 端稳定架构调研 (`docs/INTERPOLATION_ARCHITECTURE_RESEARCH.md`)**：完整拆解 `mpvnet-20231122.zip`（`mpv.conf` / `profiles.conf` / `k7sfunc.py` + `MVTools`/`SVPFlow`/`RIFE` 四套 VapourSynth `.vpy` 管线），横向对比 `MPVUI`、`VideoToolbox VTFrameProcessor`、`CoreML RIFE` 与 `MetalFX`，确立「MPV 时域平滑全格式主轨 + VideoToolbox ANE 硬件光流真补帧轨 + `k7sfunc` 护栏移植」的 iOS 端稳定落地架构。
- **全面切换日期时间版本号体系 (CalVer)**：工作流与构建规则统一采用东八区 `YYYY.MM.DD` 作为 `MARKETING_VERSION`、`YYYYMMDDHHMM` 作为 `CURRENT_PROJECT_VERSION`，IPA 产物命名为 `GlassMPV-YYYY.MM.DD-YYYYMMDDHHMM-unsigned.ipa`。
- **修复系统 VT ML (`systemML-fi`) `Processor is not initialized` 死循环阻塞**：移除每帧 `usleep(30000)` 同步死等重试，失败时立即销毁重建会话并自动降级 2×；连续失败 3 次触发 15 秒熔断直通冷却，消除 38–39ms/帧零产出白烧发热。
- **优化 RIFE 多帧缩放与帧预算稳帧**：iOS 端在 `insertedCount >= 2` 时进一步降低推理长边并收紧过载保护阈值，新增多帧帧预算超时自动降倍（3× → 2×），防止 24fps 4K 视频因超预算阻塞把输入帧率拖垮至 ~13fps。
- **修复 MPV 120Hz 时域平滑与 ANE 光流真补帧不生效**：`MPVPlayerController` 启用 `interpolation-threshold=-1` 与 `tscale=linear`（解除整数倍刷新率如 24fps@120Hz 不插帧限制）；`OpticalFlowPlayerController` 修复 `destinationPixelBufferAttributes` 数组像素格式、自动降级 `spatialScaleFactor=2` 失败回退、按首帧实测分辨率重建会话、延迟音频时钟启动至首帧入队并补全完整诊断日志采集。
- **新增 4K 片源自动禁用超分门控 (`SuperResolutionPolicy`)**：片源长边 ≥ 3840 或短边 ≥ 2160 时自动禁用 MPV GLSL 超分与 ANE 2× 空间超分，UI 控制台与 HUD 同步提示门控原因。
- **新增默认横屏、返回主界面与 `.txt` 诊断日志导出 (`OrientationController` + `DiagnosticLogExporter`)**：进入播放页默认横屏并支持手动旋转切换；支持一键返回主界面并恢复竖屏；诊断中心支持导出包含自检报告、MPV 日志与 ANE 光流日志的 `.txt` 文件并调起系统分享表单。
- **消除播放页顶部 Liquid Glass 粘黏并精简顶栏 (`LiquidGlassPlayerView`)**：移除导致邻近胶囊融合的 `GlassEffectContainer`，将双核切换改为一体化单胶囊分段控件；移除顶栏中与首页重复的打开文件/相册/串流按钮，保留返回、旋转、诊断与信息显隐 4 颗简洁按钮（10pt 间距）。
- **根治 ANE 光流核黑屏失效并升级 MPV 时域平滑 (`VTOpticalFlowEngine` + `MPVPlayerCore`)**：为 `AVSampleBufferDisplayLayer` 绑定 `controlTimebase` 并对齐送显 PTS，修复切换引擎时 `load()` 与 `seek()` 竞态、规范源像素格式选择、检查 `AVAssetReader.startReading()`、传播 `CVBufferPropagateAttachments` 色彩附件并加入追帧跳过插帧保护；HUD 如实显示实测帧率；MPV 核升级 `tscale=mitchell` + `interpolation-preserve=yes`。
- **双引擎补帧架构深度重构与真实遥测闭环 (`VTOpticalFlowEngine` + `MPVPlayerCore` + `LiquidGlassPlayerView`)**：ANE 光流核改用子图层宿主支持 `preferredTransform` 旋转排版、新增无音轨单调合成时钟 (`OpticalFlowSyntheticClock`) 与自动循环重播、修复首帧早于图层挂载的竞态 (`pendingFirstFrame`)、补齐 `requiresFlushToResumeDecoding` 自动恢复、10-bit 像素格式与对齐属性继承及 6 帧预缓冲；MPV 核新增播放期 `ProMotionDisplayLinkKeeper` 120Hz 刷新率保活，移除 `displaySyncFPS` 屏幕上限伪造兜底，透出重绘 Pass/失步帧/延迟帧及 ANE 加载态与平均耗时遥测。
- **运行期黑匣子采样、MPV 探针判定与 ANE 解码链路加固 (`PlaybackTelemetry` + `MPVPlayerCore` + `VTOpticalFlowEngine` + `LiquidGlassPlayerView`)**：新增每 2 秒采集一次且停播不清空的 `RuntimeTelemetrySample` 黑匣子时间轴；`MPVPlayerController` 启用 `logLevel: .info` 过滤采样 `[mpv-probe]`（`display-sync-active`/`interpolation`/`tscale`/`vsync-ratio`）与客观判定 `InterpolationVerdict`，4K 片源自适应切为 `tscale=linear`，切入 ANE 时调用 `releaseMediaForExternalEngine()` 彻底释放硬解会话；`OpticalFlowPlayerController` 改用纯音轨 `AVMutableComposition`、移除违规对齐键的 5 级 `AVAssetReader` 安全回退与源帧标准化缓冲池。
- **ANE `-11833/-12906` 压缩透传硬解兜底与双核补帧语义澄清 (`VTOpticalFlowEngine` + `PlaybackTelemetry` + `MPVPlayerCore` + `LiquidGlassPlayerView`)**：在常规 `AVAssetReader` 全档位失败时自动切换为压缩透传（`outputSettings=nil`）+ `HEVCFormatNormalizer`（`hev1→hvc1`/参数集重建）+ `VTDecompressionSession` 硬解兜底与 `OpticalFlowPTSReorderBuffer` B 帧 PTS 重排；新增轨道 `describeFormat` 日志、去重 `stopInternal()`/`releaseMediaForExternalEngine()` 重复日志，并将 `InterpolationVerdict` 与控制台文案明确区分为「MPV 时域平滑」与「ANE 硬件光流真补帧」。

## [v1.1.0] - 2026-11-24

### 重构与变更 (Changed)
- **切换成熟开源播放器底座 `LePips/MPVUI (0.11.0)`**：以 Swift 6 原生 `MPVPlayer` / `MPVVideoPlayer`（`videoOutput: .metal`）替代手写 C 回调桥接与自定义 `MPVMetalLayer`，消除跨线程回调隐患并保持 58 个 GLSL 着色器与 `display-fps-override=120` 完整兼容。

### 新增 (Added)
- **系统相册视频直选 (`PhotosPicker`) 与异步文件导入引擎 (`LocalMediaImporter`)**：新增 `MovieFileTransferable` 流式拷贝与后台 `NSFileCoordinator` 协调读取，支持含中文/空格/`#` 等特殊字符路径及 iCloud/FileProvider 文件，杜绝主线程卡顿与沙盒权限拦截。
- **端内「一键真机 5 项体检」台**：在播放诊断中心支持一键校验屏幕 ProMotion 最大帧率、58 个 GLSL 着色器完整性、MPVUI 解码器/硬解状态、ANE 光流支持性与补帧成功/失败实测计数，支持一键复制完整体检报告。

### 修复 (Fixed)
- **修复 ANE 硬件光流渲染同步与静默吞错 (`VTOpticalFlowEngine`)**：为送入 `AVSampleBufferDisplayLayer` 的 `CMSampleBuffer` 挂载 `kCMSampleAttachmentKey_DisplayImmediately`，并实时暴露 `interpolatedFrameCount`、`failedInterpolationCount` 与 `lastInterpolationError`，连续失败主动弹窗告知原因；同时确保 `spatial2x` 模式下输出分辨率一致。

## [v1.0.2] - 2026-11-24

### 修复 (Fixed)
- **根治“能进入但无法播放”与主线程死锁隐患**：移除 `MPVMetalLayer` 中 `DispatchQueue.main.sync` 同步切主线程逻辑（改用 `DispatchQueue.main.async`），消除 MoltenVK 渲染线程与主线程互等死锁风险。
- **对齐 MPVKit 官方子图层模型**：`MPVMetalContainerView` 改用 `layer.addSublayer(metalLayer)` 独立子图层宿主并显式关闭隐式动画与同步 `drawableSize`，替代覆写 `layerClass`。
- **补齐非阻塞命令与全生命周期事件监听**：将 `loadfile`、`seek`、`change-list` 改为 `mpv_command_async`；新增 `MPV_EVENT_START_FILE`、`MPV_EVENT_FILE_LOADED`、`MPV_EVENT_PLAYBACK_RESTART`、`MPV_EVENT_END_FILE`、`MPV_EVENT_LOG_MESSAGE` 事件解析；`hwdec` 改为 `auto-safe` 并在默认状态启用原画直出，避免无报错静默黑屏。
- **修复本地 FileProvider 权限文件读取**：当文件选择器返回的路径暂不可直读时，自动通过 `NSFileCoordinator` 协调拷贝至沙盒临时区再播放。

### 新增 (Added)
- **内置 3 秒测试视频生成器与一键自测**：新增 `TestVideoGenerator`，首页与诊断面板均可一键生成 640×360 H.264 MP4 彩条测试片并拉起播放。
- **端内播放诊断中心 (`DiagnosticLogSheet`) & 错误横幅**：实时显示内核状态、分辨率、FPS、着色器计数与最近 100 条 `libmpv` 警告日志，支持一键关闭超分重试与一键复制诊断日志。
- **CI iOS 模拟器 `xcodebuild test` 自测**：新增 `GlassMPVTests` 单元测试靶标，每次 CI 打包前自动在可用最高版本 iPhone 模拟器上运行 58 个着色器解析、MP4 生成、Headless 实播解码及 EDR 线程安全测试。
- **踩坑经验沉淀文档**：新增 `docs/LESSONS_LEARNED.md`，系统归纳 7 类核心踩坑与防复发门禁。

## [v1.0.1] - 2026-11-24

### 新增 (Added)
- 新增 iOS 26 Liquid Glass 晶透质感应用图标（`Assets.xcassets/AppIcon` 1024×1024）。
- 建立仓库级 `VERSION` 与 `CHANGELOG.md` 版本管理体系，CI 构建自动按 `github.run_number` 递增 `CFBundleVersion` 并输出带版本号的 IPA 产物（`GlassMPV-v{VERSION}-b{BUILD}-unsigned.ipa`）。
- 应用首页与控制台新增当前版本号展示及可点击的「更新日志」弹窗面板。

### 修复 (Fixed)
- 修复启动闪退问题：延迟挂载视频表面至实际打开视频、确保图层接入 `UIWindow` 且尺寸有效后才初始化 `mpv`，并补齐 `setlocale(LC_NUMERIC, "C")` 与前后台切换生命周期管理。
- 修复 `project.yml` 导致 `Sources/Info.plist` 被覆盖及 58 个 GLSL 着色器未打入 IPA 的构建配置缺陷。
- 在 GitHub Actions 打包阶段核验静态链接并剔除 26 个无用的 `MinimumOSVersion: 100.0` 占位 `.framework`。
- 将 `VTLowLatencyFrameInterpolationConfiguration.isSupported` 探测延后至实际进入 ANE 光流核加载时执行。

## [v1.0.0] - 2026-11-23

### 新增 (Added)
- 初始化 iOS 26+ 双核播放器架构：
  - **MPV 超分核**：基于 `MPVKit` (`libmpv` + `MoltenVK` + `gpu-next` + `VideoToolbox`)，内置 58 个 Anime4K / FSRCNNX / AMD FSR / KrigBilateral / NNEDI3 / RAVU GLSL 着色器与 120Hz 时域平滑插帧。
  - **ANE 光流核**：基于 Apple `VideoToolbox` `VTFrameProcessor` 硬件光流真补帧 (2×) 与 ANE 2× 硬件超分。
- 构建 iOS 26 Liquid Glass 悬浮控制台、本地文件导入、网络串流与横竖屏自适应界面。

- [x] **已完成事项**：

- [x] `GlassMPV v1.1.0` 通过本地 `pytest`（7/7）与 CI Run `45319794144`（5/5 `XCTest`），无签 IPA 已下载至 [dist/GlassMPV-v1.1.0-b16-unsigned.ipa](dist/GlassMPV-v1.1.0-b16-unsigned.ipa)（`21,599,242` bytes）。

- [x] 已将 `cinemore/CinePlayer` Fork 至 GitHub `mistriver-lab/CinePlayer`（默认分支 `main`）。

- [x] 完成 `CinePlayer v2.0.0` 排障确认：Run `45322902101` 缺失 iOS 27.1 API（commit `9d75acb` 隔离后通过类型检查），Run `45323578930` 在 `Xcode 26.6`（Swift `6.3.3`）触发 `swift-frontend` IRGen 内部崩溃；经用户确认改建 `v1.0.1` + `v1.0.0/Frameworks.zip`。

- [x] 已定位 `b7` 根因并推送补丁 commit `3d565f8` 至 `mistriver-lab/CinePlayer` `main`（将 `.fileImporter([.item])` 改为原生 `UIDocumentPickerViewController(..., asCopy: true)` 放开 `[.movie, .video, .audiovisualContent, .data]`、在 `.sheet(onDismiss:)` 退场后打开、新增 `PhotosPicker` 相册选片及 `lastOpenError` 可视化告警）。

- [x] 首版 `v1.0.1` 构建 Run `45341593198`（`fc71cb8`）全绿通过并下载 [dist/CinePlayer-v1.0.1-b6-unsigned.ipa](dist/CinePlayer-v1.0.1-b6-unsigned.ipa)（`29,122,357` bytes）。

- [x] 修复 iOS 真机本地视频打开并发报错、退场竞态与相册直读通道（`mistriver-lab/CinePlayer` commit `e1a639b`，CI Run `45355868539` `https://github.com/mistriver-lab/CinePlayer/actions/runs/45355868539` 全绿耗时 `18m19s`）：
    - 在 `PlayerOpenView.swift` 为 `cinePlayerImportsDirectory`、`sanitizeCinePlayerFilename`、`pruneCinePlayerImports`、`stageCinePlayerImportedFile` 与 `CinePlayerMovieTransferable`（增补 `.audiovisualContent` 回退）全面标记 `nonisolated`，`stageCinePlayerImportedFile` 先尝试可读直拷（APFS clonefile）再回退 `NSFileCoordinator`，编译期 `PlayerOpenView`/`PlayerSessionStore` 报错与并发警告清零（0 diagnostics）。
    - 新增 `PhotosPickerLabelView`（`nonisolated init`）承接非隔离 `PhotosPicker` label 闭包，去除 `photoLibrary: .shared()` 并启用 `preferredItemEncoding: .current` 原编码直读；新增 `schedulePickedFileOpen` 消除 `UIDocumentPickerViewController(asCopy: true)` 与 `.sheet(onDismiss:)` 退场竞态；`Info.plist` 增补 `NSPhotoLibraryUsageDescription`。

- [x] 新版无签 IPA 已下载并校验：[dist/CinePlayer-v1.0.1-b13-unsigned.ipa](dist/CinePlayer-v1.0.1-b13-unsigned.ipa)（`29,174,763` bytes / `27.82 MiB`；主二进制 `28,771,744` bytes；`Info.plist` 含 `UIFileSharingEnabled: True`、`LSSupportsOpeningDocumentsInPlace: True`、`NSPhotoLibraryUsageDescription`）。

- [x] `GlassMPV v1.2.0-b21` 全流水线通过（`mistriver-lab/CinePlayer` `glassmpv-ios` @ `e6c81ac`，CI Run `45388180829`，耗时 `5m21s`）：`085f964` 增加 per-round 日志采集后精确定位 Round 4 RIFE 崩溃为 iOS Simulator 上 `MPSGraphDevice(mtlDevice:)` 触发 `NSInvalidArgumentException`；`e6c81ac` 在 `RifeFrameInterpolationAdapter.swift` 为 Simulator 添加安全 passthrough 防护（真机 `iphoneos` 保留完整 `RifeInterpolator` + `rife-v4.26.rmw` 推理），随后 5 轮模拟器冒烟（`cold launch` / `baseline` / `anime4k` / `rife` / `opticalFlow`）全部存活且无崩溃报告，已落地 `dist/GlassMPV-v1.2.0-b21-unsigned.ipa`（`36,402,674` bytes）。

- [x] 抑制系统「安装字体?」弹窗：新增 `CinePlayer/Player/App/CTFontDownloadSuppressor.m`（iOS 下覆盖 `CTFontDescriptorMatchFontDescriptorsWithProgressHandler` 异步回调完成态），并在 `.github/workflows/build-ios-ipa.yml` 增加模拟器/Release 二进制 `nm -u` 符号校验。

- [x] 修复 `RifeFrameInterpolationAdapter.swift` 第 361 行作用域遮蔽编译错误（`8c03150` 在 `processTemporalOnQueue` 中 `stream = nil` 误引用局部 `let stream` 导致 Run `45419757937` 报错；`397db87` 改为 `self.stream = nil` / `self.streamKey = nil` 后全绿通过）。

- [x] 核验 CoreText 弹窗拦截与 4K RIFE 优化发布：`CTFontDownloadSuppressor.m` 已在 Release 二进制静态定义 `_CTFontDescriptorMatchFontDescriptorsWithProgressHandler`，5 轮模拟器冒烟无崩溃，`dist/GlassMPV-v1.2.0-b24-unsigned.ipa` 校验通过。

- [x] **本轮已实证排查结论（来源：`GlassMPV-Diagnostics 2.txt`（实机导出日志） + `CinePlayer-repo` 源码与 IPA 二进制核验）**：
  1. **1080p 杜比视界全部增强 `inFrames=0` 不生效**：片源 `hevc 1920x1080 @ 30.00fps 10bit Dolby Vision`（`iPhone16,2` / iOS `27.0.1` / `thermal=serious`）。`CinePlayerSDK` 架构对杜比视界默认走 AVFoundation `AVPlayer` 原生直通（见 `README-zh.md:36`），`FrameCallbackCenter` 跳过 `isDovi` 回调，故 `metalFX`/`systemML-fi`/`opticalFlow` 即使 `warmupReady` 也全程 `inFrames=0`。已核验 `CinePlayerConfig.dynamicRange`（`DynamicRange?` 含 `.sdr`）可写、`controller.currentPlaybackTime` 可取，可通过「转 SDR 兼容增强」按当前进度 `controller.replace(config:)` 重载为 SDR 解锁全链路增强。
  2. **功能被置灰禁用**：`PlayerEnhancementModel.swift:786` `rifeSectionVisible = !isHDR && ...` 禁用 HDR/DV 的 RIFE；`:842` `width * height < 1920 * 1080` 严格小于导致 1080p 直接禁用 Anime4K（需改为 `<=`）。
  3. **策略切换 6 连击重置 Bug**：`applyMutualExclusion(for:)` 修改多个 `@Published` 属性未抑制 `notifyRuntimeConfigChanged`，且 `SiderEnhancementView` 二次赋值子开关，导致每次切策略同一毫秒触发 5–6 次 `makeFrameCallbackConfiguration` 与 `EnhancementTelemetryCollector.reset`。
  4. **多帧 API 已核验**：`RifeStream.push(_ frame: CVPixelBuffer, timesteps: [Float]) throws -> [CVPixelBuffer]` 可直接支持多相位（首帧返回 `[]` 需走 anchor 段，空 `timesteps` 做 cache-rebase）。
  5. **当前代码状态**：`CinePlayer-repo` 工作区干净无未提交修改（HEAD `397db87`），已完成全量方案定稿。

- [x] **修复 MPV 120Hz 时域平滑与 ANE 光流真补帧不生效**：`MPVPlayerCore.swift` 配置 `interpolation-threshold=-1` + `tscale=linear`（解除整数倍刷新率屏蔽插帧）；`VTOpticalFlowEngine.swift` 修复像素格式池数组键异常、`spatialScaleFactor=2` 失败回退、按实测解码尺寸重建会话、首帧入队后再启动音频时钟，并补全 ANE 诊断日志采集。

- [x] **新增 4K 片源自动禁用超分门控 (`SuperResolutionPolicy`)**：`width/height` 达 `3840×2160` 及以上时自动屏蔽 MPV GLSL 超分与 ANE 2× 空间超分，UI 控制台、HUD 与自检报告同步透出原因。

- [x] **新增默认横屏起播、手动旋转、返回主界面与 `.txt` 诊断日志导出 (`OrientationController` + `DiagnosticLogExporter` + `LiquidGlassPlayerView`)**：打开视频默认进横屏并支持工具栏旋转切换；支持一键返回主界面与错误横幅返回；诊断中心支持分享/导出完整 `.txt` 日志文件。

- [x] **已验证交付（`fe9fdf4` / CI Run `45558978591`）**：修复 `VTOpticalFlowEngine.swift` Swift 6 `noasync` 锁与 `nonisolated` 并发编译，CI 全绿（`10m17s`，`GlassMPVTests` 15/15 PASS），产出并校验 `dist/GlassMPV-2026.11.25-202611251421-unsigned.ipa`。

- [x] **最新实机日志（`GlassMPV-Log-20261125-153115.txt`）双根因定位结论**：
  1. **MPV 120Hz 模式**：实机探针 `sync_active=yes video_sync=display-resample interp=yes tscale=linear vsync_ratio=5.00 disp_fps=120.0Hz est_disp=119.5Hz` 已实际运行，但 `libmpv` 的 `tscale` 属于无运动矢量时域帧混合（去 3:2 抖动），24fps 在 120Hz（精确 5 倍整数倍）下无运动补偿光流果冻感且 HUD `estimated-vf-fps` 恒报 `24.0`，旧标签“MPV补帧生效”造成误解。
  2. **ANE 光流真补帧核**：`VTFrameProcessor` 已为 `2960×2160` 成功启动，但 `AVAssetReader` 4 个输出档位均报 `-11833 / NSOSStatusErrorDomain(-12906)`；原因是该 HEVC MP4 容器标签为 `hev1`（苹果 `AVAssetReader` 要求 `hvc1`），须通过 `outputSettings: nil` 压缩透传 + `HEVCFormatNormalizer`（`hev1→hvc1`）+ `VTDecompressionSession` + `OpticalFlowPTSReorderBuffer` 硬解兜底。

- [x] **当前代码改动进度（工作区未提交 WIP，新窗可直接接续，无需从头重读文件）**：

- [x] 修复 `VTOpticalFlowEngine.swift` `VTDecompressionSessionCreate` 参数标签与 `test_project_integrity.py` 断言（`b4676df`）；CI Run `45588353144` 全绿出包并交付微信「文件传输助手」。

- [x] 修复 `OpticalFlowCandidate` / `OpticalFlowBackendKind` `Hashable`（`42a9739`）与 `testMPVUIControllerPlaybackWithWindowHost` 慢跑器轮询窗口放宽至 30s（`1014b2b`），CI Run `45737880768` 全绿出包并交付微信「文件传输助手」。

- [x] 响应 `095509` 实机日志（`3a30121` / `ed3e252`）：修复 `OpticalFlowTargetFPS` `id: Self` 切档失效、新增热切换与杜比视界/HDR EDR 支持、移除内置 3 秒测试并重塑 UI（CI Run `45927575289`，22/22 PASS）。

- [x] Phase 1 实时 Metal + MetalFX 画质增强引擎上线（`ba872d4` / 公开镜像 `3f51ddf`）：支持「原画 / 老片去糊 / 动漫强化 / 低清超分」，CI Run `45957449192`（24/24 PASS）。

- [x] 响应 `153158` 实机日志专项优化 + Phase 2 云端片源库上线（`a956a5c` / 公开镜像 `00fae3e`）：

- [x] **实机过热/去糊/对比修复**：移除高耗时 8 邻域双边 `exp()`，改为单遍多尺度（1px+2px）邻域限幅 Luma 去糊 + 死区门控 + 防光晕 CAS；`MetalFX` 新增高刷/高温保护（`outputFPS > 65` 或过热自动切省电直锐，60fps 封顶 1080p）；`ThermalState.serious` 限档由 `60fps` 调整为 `2×(48fps)` 快速降温；新增可点击「**分屏对比（左原画｜右增强）**」与「**对比原画**」并缓存最近原始帧以支持暂停态零延迟刷新。

- [x] Phase 1 实时 Metal + MetalFX 画质增强引擎上线（`ba872d4` / 公开镜像 `3f51ddf`）：支持「原画 / 老片去糊 / 动漫强化 / 低清超分」，CI Run `45957449192`（24/24 PASS）。

- [x] 响应 `153158` 实机日志专项优化 + Phase 2 云端片源库上线（`a956a5c` / 公开镜像 `00fae3e`）：

- [x] **实机过热/去糊/对比修复**：移除高耗时 8 邻域双边 `exp()`，改为单遍多尺度（1px+2px）邻域限幅 Luma 去糊 + 死区门控 + 防光晕 CAS；`MetalFX` 新增高刷/高温保护（`outputFPS > 65` 或过热自动切省电直锐，60fps 封顶 1080p）；`ThermalState.serious` 限档由 `60fps` 调整为 `2×(48fps)` 快速降温；新增可点击「**分屏对比（左原画｜右增强）**」与「**对比原画**」并缓存最近原始帧以支持暂停态零延迟刷新。

- [x] 响应 `153158` 实机日志专项优化 + Phase 2 云端片源库上线（`a956a5c` / 公开镜像 `00fae3e`）：重构多尺度 Luma 去糊、`.serious` 降档至 `2×(48fps)`、可点选「分屏对比 / 对比原画」暂停即时刷新及 夸克/Emby/WebDAV 云端片源（CI Run `45961120348`，28/28 PASS）。

- [x] `v0.1.0-beta.1 (Build 18)` 性能温控与夸克代理架构重构（`399bd85` / 公开镜像 `08be28d`）：

- [x] **零拷贝异步 FP16 直绘与温控减负**：针对 `160642` 日志暴露的 `waitUntilCompleted()` 与 `+36MB` 冗余拷贝，新增 `CAMetalLayer` 全异步 Fragment Shader（16-bit `half` 5 点硬件双线性采样、零 `copyChroma`、零中间缓冲池、`addCompletedHandler` 非阻塞统计 GPU 耗时）；`48/60fps` 释放 `.latencyCritical`。
