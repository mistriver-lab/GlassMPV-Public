# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（主线 `GlassMPV 2026.11.25` CalVer 已接入 | 衍生 `mistriver-lab/CinePlayer` `glassmpv-ios` 分支交付 `GlassMPV-2026.11.25-202611250952-unsigned.ipa`）
- **当前阶段**：`GlassMPV 2026.11.25（日期时间版本号 + System VT ML 死循环熔断修复 + RIFE 多帧降边稳帧）已通过 5 轮模拟器冒烟与 Release 构建并交付 dist/`
- **最后活跃时间**：`2026-11-25 11:03:03` | **最近安全快照**：`feb753a`（`mistriver-lab/CinePlayer` `glassmpv-ios` CI Run `45527540874`）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`续修GlassMPV的MPV与ANE光流补帧不生效、4K禁超分、默认横屏、返回主界面与日志导出(已完成OrientationController/DiagnosticLogExporter/SuperResolutionPolicy/AppDelegate,待改MPVPlayerCore/VTOpticalFlowEngine/LiquidGlassPlayerView/测试并出IPA)`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](file:///C:/Users/21920/Desktop/ipa开发/CHANGELOG.md)）：
  * [x] **全面切换东八区日期时间版本号（CalVer）**：主仓（`VERSION`、`project.yml`、`.github/workflows/build-ios.yml`、`CHANGELOG.md`、`.agents/rules/GEMINI.md`）与 `CinePlayer-repo`（`project.pbxproj`、`.github/workflows/build-ios-ipa.yml`）统一以 `TZ=Asia/Shanghai` 的 `YYYY.MM.DD` 作为 `MARKETING_VERSION`、`YYYYMMDDHHMM` 作为 `CURRENT_PROJECT_VERSION`，IPA 命名 `GlassMPV-YYYY.MM.DD-YYYYMMDDHHMM-unsigned.ipa`。
  * [x] **修复 System VT ML (`systemML-fi`) `Processor is not initialized` 死循环与每帧 `usleep(30ms)` 阻塞**：移除 `SystemVideoEnhancementAdapter.swift` 同步 `usleep(30000)` 重试，错误后立即 `resetLLFISessionOnQueue()`、多帧初始化失败自动降级 2×，连续失败 3 次触发 15 秒直通冷却熔断。
  * [x] **优化 RIFE 多帧分辨率缩边与帧预算稳帧**：`RifeFrameInterpolationAdapter.swift` 收紧 iOS 长边（`fast=640` / `balanced=896` / `hq=896`）并在 `insertedCount >= 2` 时再乘 `0.80`（`2960×2160` 降为 `512×352`），新增连续 6 帧超出 `0.90 × budget` 自动降倍（3× → 2×）与更严的过载冷却。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV 2026.11.25`（`mistriver-lab/CinePlayer` `glassmpv-ios` @ `feb753a`，CI Run `45527540874`，耗时 `15m4s`）5 轮模拟器冒烟与 Release `iphoneos` 构建全绿通过，交付 `dist/GlassMPV-2026.11.25-202611250952-unsigned.ipa`（`36,481,962` bytes）；主仓本地 `pytest tests/test_project_integrity.py -v`（7/7 in `0.46s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（`GlassMPV 2026.11.25` 全绿出包；当前无待办）
- **交付与工作区归档**：
  - `glassmpv-ios` 最新工作仓库：`C:\Users\21920\.gemini\antigravity\brain\f72f0ae8-3254-4317-a0be-ff892bc49a0f\scratch\CinePlayer-repo`（`glassmpv-ios` @ `feb753a`）。
  - CI Run `45527540874` 冒烟报告：`C:\Users\21920\.gemini\antigravity\brain\f72f0ae8-3254-4317-a0be-ff892bc49a0f\scratch\run-45527540874\GlassMPV-sim-smoke-report\`（Round 1 PID `4951`、`baseline` PID `10352` `errorEvents=0`、`anime4k` PID `10986` `320x240->1920x1440` `replacedFrames=7` `errorEvents=0`、`rife` PID `11817` `detail=fast·2x` `inputFrames=201` `passthroughFrames=198` `measuredInputFPS=15.02` `measuredOutputFPS=15.02` `errorEvents=0`、`opticalFlow` PID `12524` `detail=2x` `inputFrames=43` `replacedFrames=39` `outputFrames=79` `measuredOutputFPS=9.08` `errorEvents=0`，`DiagnosticReports` 无崩溃）。
  - 交付 IPA：`dist/GlassMPV-2026.11.25-202611250952-unsigned.ipa`（`36,481,962` bytes；`Info.plist` 校验 `CFBundleIdentifier=cn.com.cinemore.cineplayer`、`CFBundleShortVersionString=2026.11.25`、`CFBundleVersion=202611250952`、`CFBundleDisplayName=GlassMPV`、`MinimumOSVersion=17.0`、`CADisableMinimumFrameDurationOnPhone=True`；包内包含 `RifeMetal_RifeMetal.bundle/rife-v4.26.rmw`、`RifeMetal_RifeMetalCore.bundle/default.metallib`、`Anime4KMetal_Anime4KMetalCore.bundle/default.metallib`、`default.metallib`）。
- **待办清单**：无待办。