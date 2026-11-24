# 更新日志 (Changelog)

本项目遵循 [语义化版本规范 (Semantic Versioning)](https://semver.org/lang/zh-CN/)。

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
