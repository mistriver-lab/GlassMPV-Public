# 更新日志 (Changelog)

本项目遵循日期时间版本规范（东八区 `YYYY.MM.DD` + `YYYYMMDDHHMM`）。

## [v2026.11.25] - 2026-11-25

### 变更与修复 (Changed & Fixed)
- **新增 MPV 风格常驻关键信息 HUD (`PlaybackTelemetry` + `LiquidGlassPlayerView`)**：在未开启补帧（原帧率）状态下亦可实时显示视频编码、分辨率、原帧率/实时输出帧率（补齐 `estimatedDecodedFramesPerSecond` 与 `AVSampleBufferDisplayLayer` 实测帧率采样）、色深/HDR（10-bit / HDR10 / HLG）、硬解/软解状态、丢帧计数与设备实时温度（`ProcessInfo.ThermalState`），精简布局且不受主控制栏自动隐藏影响，支持顶部 `info.circle` 按钮或右上角参数徽章一键显隐。
- **沉淀桌面端插帧深度剖析与 iOS 端稳定架构调研 (`docs/INTERPOLATION_ARCHITECTURE_RESEARCH.md`)**：完整拆解 `mpvnet-20231122.zip`（`mpv.conf` / `profiles.conf` / `k7sfunc.py` + `MVTools`/`SVPFlow`/`RIFE` 四套 VapourSynth `.vpy` 管线），横向对比 `MPVUI`、`VideoToolbox VTFrameProcessor`、`CoreML RIFE` 与 `MetalFX`，确立「MPV 时域平滑全格式主轨 + VideoToolbox ANE 硬件光流真补帧轨 + `k7sfunc` 护栏移植」的 iOS 端稳定落地架构。
- **全面切换日期时间版本号体系 (CalVer)**：工作流与构建规则统一采用东八区 `YYYY.MM.DD` 作为 `MARKETING_VERSION`、`YYYYMMDDHHMM` 作为 `CURRENT_PROJECT_VERSION`，IPA 产物命名为 `GlassMPV-YYYY.MM.DD-YYYYMMDDHHMM-unsigned.ipa`。
- **修复系统 VT ML (`systemML-fi`) `Processor is not initialized` 死循环阻塞**：移除每帧 `usleep(30000)` 同步死等重试，失败时立即销毁重建会话并自动降级 2×；连续失败 3 次触发 15 秒熔断直通冷却，消除 38–39ms/帧零产出白烧发热。
- **优化 RIFE 多帧缩放与帧预算稳帧**：iOS 端在 `insertedCount >= 2` 时进一步降低推理长边并收紧过载保护阈值，新增多帧帧预算超时自动降倍（3× → 2×），防止 24fps 4K 视频因超预算阻塞把输入帧率拖垮至 ~13fps。

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

- [x] **本轮已实证排查结论（来源：`C:\Users\21920\Documents\xwechat_files\wxid_8mhh4tfklkan22_9a3a\msg\file\2026-11\GlassMPV-Diagnostics 2.txt` + `CinePlayer-repo` 源码与 IPA 二进制核验）**：
  1. **1080p 杜比视界全部增强 `inFrames=0` 不生效**：片源 `hevc 1920x1080 @ 30.00fps 10bit Dolby Vision`（`iPhone16,2` / iOS `27.0.1` / `thermal=serious`）。`CinePlayerSDK` 架构对杜比视界默认走 AVFoundation `AVPlayer` 原生直通（见 `README-zh.md:36`），`FrameCallbackCenter` 跳过 `isDovi` 回调，故 `metalFX`/`systemML-fi`/`opticalFlow` 即使 `warmupReady` 也全程 `inFrames=0`。已核验 `CinePlayerConfig.dynamicRange`（`DynamicRange?` 含 `.sdr`）可写、`controller.currentPlaybackTime` 可取，可通过「转 SDR 兼容增强」按当前进度 `controller.replace(config:)` 重载为 SDR 解锁全链路增强。
  2. **功能被置灰禁用**：`PlayerEnhancementModel.swift:786` `rifeSectionVisible = !isHDR && ...` 禁用 HDR/DV 的 RIFE；`:842` `width * height < 1920 * 1080` 严格小于导致 1080p 直接禁用 Anime4K（需改为 `<=`）。
  3. **策略切换 6 连击重置 Bug**：`applyMutualExclusion(for:)` 修改多个 `@Published` 属性未抑制 `notifyRuntimeConfigChanged`，且 `SiderEnhancementView` 二次赋值子开关，导致每次切策略同一毫秒触发 5–6 次 `makeFrameCallbackConfiguration` 与 `EnhancementTelemetryCollector.reset`。
  4. **多帧 API 已核验**：`RifeStream.push(_ frame: CVPixelBuffer, timesteps: [Float]) throws -> [CVPixelBuffer]` 可直接支持多相位（首帧返回 `[]` 需走 anchor 段，空 `timesteps` 做 cache-rebase）。
  5. **当前代码状态**：`CinePlayer-repo` 工作区干净无未提交修改（HEAD `397db87`），已完成全量方案定稿。
