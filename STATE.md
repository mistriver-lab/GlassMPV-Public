# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（主线 `GlassMPV 2026.11.25` @ `fe9fdf4` | 最新交付 IPA `GlassMPV-2026.11.25-202611251421-unsigned.ipa`）
- **当前阶段**：`已完成微信日志 GlassMPV-Log-20261125-143242.txt 根因定位（ANE AVAssetReader 解码失败 + MPV 缺运行期采样/探针），因上下文触及 191k 红线熔断，待新窗或 /compact 后直接按方案落码出包`
- **最后活跃时间**：`2026-11-25 14:49:00` | **最近安全快照**：`fe9fdf4`（CI Run `45558978591`）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成微信日志根因定位，待新窗落地运行期黑匣子采样+ANE解码回退+MPV探针并出包`
- **已验证交付（`fe9fdf4` / CI Run `45558978591`）**：
  * [x] 修复 `VTOpticalFlowEngine.swift` Swift 6 `noasync` 锁与 `nonisolated` 并发编译，CI 全绿（`10m17s`，`GlassMPVTests` 15/15 PASS），交付 `dist/GlassMPV-2026.11.25-202611251421-unsigned.ipa` 并发送至微信「文件传输助手」。
- **本轮从微信日志 `GlassMPV-Log-20261125-143242.txt`（`001.mp4` 2960×2160 HEVC 23.98fps）实锤定位的 2 类根因**：
  1. **ANE 光流核起播失败（`[14:31:46] [ane][error] AVAssetReader startReading 失败: 无法解码`）**：
     - `VTOpticalFlowEngine.swift` `buildReaderOutputSettings` 将 `VTFrameProcessor` 的 `PlaneAlignment` / `ExtendedPixels*` 对齐键直接传入 `AVAssetReaderTrackOutput`，`canAdd` 静态放行导致 `minimalSettings` 回退未触发，`startReading()` 失败后未重建 `AVAssetReader` 重试，且仅输出 `localizedDescription` 吞掉 `NSError.domain/code`；
     - `LiquidGlassPlayerView.swift` 切入 `.opticalFlow` 时仅调用 `mpvController.pause()` 未调用 `stop()` 释放 MPV 的 4K HEVC VT 硬解会话，且 `VTOpticalFlowEngine` 使用原视频 URL 构建 `AVPlayerItem` 而非纯音轨 `AVMutableComposition`。
  2. **诊断缺少运行期检测 & MPV 120Hz 生效真伪无法核实**：
     - `DiagnosticLogExporter` / `PlaybackDiagnosticsSheet` 仅在导出瞬间抓静态快照（停播回首页后导出时，MPV 状态与 `measuredProMotionFPS` 已归零，且 `handlePlaybackEvent` 停播后回流旧事件）；
     - `MPVUI` 的 `freshRenderPasses` / `redrawRenderPasses` 是渲染管线 Pass 数（`3 / 1`），`estimated-display-fps`（`111.3 Hz`）是估算显示器刷新率，均不证明 `display-sync-active == yes`；`MPVPlayerCore` 未查询 `display-sync-active` / `interpolation` / `vsync-ratio`（`logLevel` 设为 `.warning`，未下发 `expand-properties print-text` 探针）。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV 2026.11.25`（主线 `mistriver-lab/GlassMPV` @ `fe9fdf4`，CI Run `45558978591`，耗时 `10m17s`）iOS 模拟器 `GlassMPVTests` 15/15 通过（`5.297s`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-2026.11.25-202611251421-unsigned.ipa`（`21,720,475` bytes，含 58 个 GLSL 着色器 & `Assets.car`）；主仓本地 `pytest tests/test_project_integrity.py -v`（7/7 in `0.13s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（基线可出包；待执行新一轮补帧修复与运行期黑匣子采样落地）
- **交付与工作区归档**：
  - 主线最新交付 IPA：`dist/GlassMPV-2026.11.25-202611251421-unsigned.ipa`（`21,720,475` bytes；`Info.plist` 校验 `CFBundleIdentifier=com.glassmpv.player`、`CFBundleShortVersionString=2026.11.25`、`CFBundleVersion=202611251421`、`CFBundleDisplayName=GlassMPV`，内含 58 个 GLSL 着色器与 `Assets.car`）。
  - 已分析最新实机日志：`C:\Users\21920\Documents\xwechat_files\wxid_8mhh4tfklkan22_9a3a\msg\file\2026-11\GlassMPV-Log-20261125-143242.txt`。
- **待办清单**：
  - [ ] 新窗执行已定位修复方案并出包：
    1. `Sources/Models/PlaybackTelemetry.swift`：新增 `MPVProbeSnapshot`、`InterpolationVerdict`、`RuntimeTelemetrySample`（含 `formatLogLine()`）。
    2. `Sources/Engine/MPVPlayerCore.swift`：设 `logLevel: .info`（过滤仅留探针与关键日志）、新增 `probeInterpolationState()`（`expand-properties print-text [mpv-probe] sync_active=${display-sync-active} video_sync=${video-sync} interp=${interpolation} tscale=${tscale} vsync_ratio=${vsync-ratio} disp_fps=${display-fps} est_disp=${estimated-display-fps}`）、`releaseMediaForExternalEngine()`、`lastMeasuredProMotionFPS`、停播后防事件回流 `isStoppedByUser`，4K 片源切换 `tscale=linear`。
    3. `Sources/Engine/VTOpticalFlowEngine.swift`：新增 `formatDetailedError(_:)`、纯音轨 `AVMutableComposition`（`try await audioTrack.load(.timeRange)`）、移除 `AVAssetReaderTrackOutput` 中 `PlaneAlignment`/`ExtendedPixels*` 键、新增 `openAssetReaderWithFallback` 重建多级回退及按需 `makeSourceNormalizationPool` + `VTPixelTransferSession` 源帧标准化（严格遵守 `runOpticalFlowTask` 异步体内禁调 `.lock()/.unlock()`）。
    4. `Sources/UI/DiagnosticLogExporter.swift` & `LiquidGlassPlayerView.swift`：增加 2 秒运行期 `RuntimeTelemetrySample` 采样轨迹（`--- Runtime Telemetry Timeline ---`，停播返回首页不清空）、切入 ANE 调用 `mpvController.releaseMediaForExternalEngine()`、诊断 UI 展示补帧生效判定与实报探针。
    5. 补充 `tests/GlassMPVTests.swift` 与 `tests/test_project_integrity.py` 断言，本地 `pytest` 通过后推送 `main`，等 CI 全绿下载新 IPA 至 `dist/` 并用 `cua-driver` 发送至微信「文件传输助手」。