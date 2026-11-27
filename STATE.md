# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `ba872d4` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `3f51ddf` | 最新交付 IPA `dist/GlassMPV-2026.11.27-202611271522-unsigned.ipa`）
- **当前阶段**：`已完成 Phase 1（实时 Metal + MetalFX GPU 画质增强引擎：老片去糊 / 动漫强化 / 低清超分 / 按住对比原画 / 杜比视界直通保护）；CI Run 45957449192 全绿（24/24）、IPA 已下载校验（2,874,087 bytes）并投递微信「文件传输助手」，下一步进入 Phase 2（WebDAV / Alist 云端网盘片库）`
- **最后活跃时间**：`2026-11-27 15:25:00` | **最近安全快照**：`3f51ddf`（CI Run `45957449192` 绿灯出包，`ba872d4` 为私有主线代码与单测同步点）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 Phase 1 实时 Metal + MetalFX GPU 画质增强引擎（原画 / 老片去糊 / 动漫强化 / 低清超分，轻度/标准/增强三档，按住对比原画，杜比视界直通），CI Run 45957449192 全绿 24/24 并已将定版 IPA 投递微信「文件传输助手」；下一阶段就绪：Phase 2 WebDAV / Alist 云端网盘片库`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
  * [x] 最终敲定档位矩阵与能效优化（`875cd93` / 公开镜像 `73b9092`）：正式移除非 120Hz 整分频的 `72fps`，24p 收敛为 `原画 / 48(2×清晰省电) / 60 / 96(4×高刷甜点) / 120 fps`；`recommendedDisplayFrameRateRange` 对 `48fps` 精准锁 `(48,48,48)`、`60fps` 锁 `(60,60,60)`、`96/120fps` 锁 `(80,120,120)`；`effectivePowerThermalCap` 在低电量模式下封顶 `60fps`。
  * [x] Phase 1 实时 Metal + MetalFX 画质增强引擎上线（`ba872d4` / 公开镜像 `3f51ddf`）：新增 `VideoEnhancementOptions.swift` 与 `MetalVideoEnhancer.swift`（内置 MSL 边缘保持双边去噪 + Luma CAS 锐化 + 动漫线条增强 + 微反差 + YUV→BGRA / Catmull-Rom，真机叠加 `#if canImport(MetalFX) && !targetEnvironment(simulator)` `MTLFXSpatialScaler` 空间超分最高 `2560×1440`）；支持假 4K `老片去糊`、二次元 `动漫强化`、低分 `低清超分`、3 档强度、`按住对比原画`、杜比视界自动直通与 10-bit HDR Luma 保留；CI Run `45957449192`（`6m20s`）`GlassMPVTests` 24/24 全绿交付 `2,874,087` bytes IPA。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV 2026.11.27`（公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `3f51ddf`，CI Run `45957449192`，耗时 `6m20s`）iOS 模拟器 `GlassMPVTests` 24/24 通过（`Executed 24 tests, with 0 failures (0 unexpected) in 25.491 (25.941) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-2026.11.27-202611271522-unsigned.ipa`（`2,874,087` bytes，纯原生系统框架 + `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.18s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 `GlassMPVTests 24/24` 与 Release IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-2026.11.27-202611271522-unsigned.ipa`（`2,874,087` bytes；`Info.plist` 校验 `CFBundleIdentifier=com.glassmpv.player`、`CFBundleShortVersionString=2026.11.27`、`CFBundleVersion=202611271522`，含 `Assets.car`，0 个 `.glsl` 着色器）。
  - 最新实机闭环日志：`GlassMPV-Log-20261127-135235.txt`（`Build 202611271341`，4K HEVC `23.98 → 120.3 fps`，`LowLatency 986×720 [×5]`、`hwScale=1480x1080`、`q=60` 零丢帧）。
  - **已定因根因与本轮已核验架构约束**：
    1. **Metal / MetalFX SDK 边界与 Swift 6 隔离**：`MetalFX` 仅真机 `iphoneos` SDK 提供，必须保留 `#if canImport(MetalFX) && !targetEnvironment(simulator)` 隔离；`OpticalFlowPlayerController` 保持 `nonisolated init()`，通过 `@MainActor private var metalEnhancerStorage: MetalVideoEnhancer? = nil` 懒加载。
    2. **最终档位体系与 ProMotion 精准锁频**：移除 `fps72`，保留 `x2 / fps60 / fps96 / fps120`；`48fps` 锁 `(48, 48, 48)`、`60fps` 锁 `(60, 60, 60)`、`96/120fps` 锁 `(80, 120, 120)`；`effectivePowerThermalCap` 在低电量模式/严重过热下封顶 `60fps` / `2×`。
    3. **Swift 6 与门禁红线**：`ProcessInfo` Activity 令牌通过 `PlaybackActivityTokenHolder` 隔离；`selectPrimaryVideoTrack` 用 `#isolation`、`selectPlayableAudioTrack` 标 `@MainActor`；内存采样用 `task_self_trap()`，`VTOpticalFlowEngine.swift` 的 `runOpticalFlowTask..#endif` 区间内严禁直接出现 `.lock()`/`.unlock()`；内嵌 MSL 字符串禁用 `"` 字符。
- **待办清单**：
  - [x] 完成 Phase 1 实时 Metal + MetalFX 画质增强引擎、全绿单测与 Release 打包（CI Run `45957449192`，24/24 PASS，`6m20s`）。
  - [x] 下载校验 `dist/GlassMPV-2026.11.27-202611271522-unsigned.ipa`（`2,874,087` bytes）并投递微信「文件传输助手」。
  - [ ] Phase 2：接入 WebDAV / Alist 云端网盘片库（阿里云盘 / 夸克 / 115 / 百度 / OneDrive）。