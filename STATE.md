# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（主线 `GlassMPV 2026.11.25` @ `fe9fdf4` | 最新交付 IPA `GlassMPV-2026.11.25-202611251421-unsigned.ipa`）
- **当前阶段**：`双引擎补帧重构与 Swift 6 并发修复（fe9fdf4）已通过本地 7/7 完整性校验、CI Run 45558978591 15/15 XCTest 与 Release 构建并交付 dist/，已同步发送至微信「文件传输助手」`
- **最后活跃时间**：`2026-11-25 14:26:35` | **最近安全快照**：`fe9fdf4`（CI Run `45558978591`）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成双引擎补帧重构 Swift 6 并发修复 fe9fdf4，CI Run 45558978591 全绿出包并交付 dist/GlassMPV-2026.11.25-202611251421-unsigned.ipa，已通过 cua-driver 发送至微信「文件传输助手」`
- 本轮已落地并验证（commit `05372cf` -> `fe9fdf4`）：
  * [x] **重构 `Sources/Engine/VTOpticalFlowEngine.swift` 并修复 Swift 6 `iphoneos` 并发编译**：`SampleBufferDisplayContainerView` 改用 `addSublayer(displayLayer)` 支持 `preferredTransform` 旋转排版；新增 `OpticalFlowSyntheticClock` 无音轨合成时钟与自动循环重播；补齐 `pendingFirstFrame` 首帧延迟挂载缓存、`requiresFlushToResumeDecoding` 恢复、10-bit 像素格式与对齐属性继承、相邻帧 PTS 区间校验（`0.004...0.5s`）、6 帧预缓冲与 `averageInterpolationMs` 遥测；将 `isQuarterTurnTransform` / `normalizedRotationTransform` 标为 `nonisolated`，并将 `runOpticalFlowTask` 内 `bufferLock` 隔离至同步辅助函数 `markReaderEOF()`。
  * [x] **升级 `Sources/Engine/MPVPlayerCore.swift`**：新增 `ProMotionDisplayLinkKeeper` 120Hz 刷新率保活与实测采样；移除 `displaySyncFPS` 屏幕上限伪造兜底；新增 `targetDisplaySyncFPS`、`measuredProMotionFPS`、`redrawRenderPassCount`、`mistimedFrames`、`delayedFrames`。
  * [x] **升级 UI 遥测与防复发测试套件（`LiquidGlassPlayerView.swift`、`DiagnosticLogExporter.swift`、`AppReleaseInfo.swift`、`CHANGELOG.md`、`GlassMPVTests.swift`、`test_project_integrity.py`）**：补齐 ANE 加载胶囊、完整 `.txt` 插帧遥测导出与 4 项新增单测；`test_project_integrity.py` 新增 `nonisolated` 旋转助手及 `runOpticalFlowTask` 禁调 `.lock()/.unlock()` 断言。
  * [x] **CI 全绿出包与微信交付**：CI Run `45558978591` 耗时 `10m17s` 全绿，`GlassMPVTests` 15/15 PASS（`5.297s`），已下载并校验 `dist/GlassMPV-2026.11.25-202611251421-unsigned.ipa`（`21,720,475` bytes），并通过 `cua-driver` 发送至微信「文件传输助手」。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV 2026.11.25`（主线 `mistriver-lab/GlassMPV` @ `fe9fdf4`，CI Run `45558978591`，耗时 `10m17s`）iOS 模拟器 `GlassMPVTests` 15/15 通过（`5.297s`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-2026.11.25-202611251421-unsigned.ipa`（`21,720,475` bytes，含 58 个 GLSL 着色器 & `Assets.car`）；主仓本地 `pytest tests/test_project_integrity.py -v`（7/7 in `0.73s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（`GlassMPV 2026.11.25` 全绿出包并微信发包完成；当前无待办）
- **交付与工作区归档**：
  - 主线最新交付 IPA：`dist/GlassMPV-2026.11.25-202611251421-unsigned.ipa`（`21,720,475` bytes；`Info.plist` 校验 `CFBundleIdentifier=com.glassmpv.player`、`CFBundleShortVersionString=2026.11.25`、`CFBundleVersion=202611251421`、`CFBundleDisplayName=GlassMPV`，内含 58 个 GLSL 着色器与 `Assets.car`）。
  - 衍生 `glassmpv-ios` 最新工作仓库：`C:\Users\21920\.gemini\antigravity\brain\f72f0ae8-3254-4317-a0be-ff892bc49a0f\scratch\CinePlayer-repo`（`glassmpv-ios` @ `feb753a`，CI Run `45527540874` 交付 `dist/GlassMPV-2026.11.25-202611250952-unsigned.ipa`）。
- **待办清单**：无待办。