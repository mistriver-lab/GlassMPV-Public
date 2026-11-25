# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（主线 `GlassMPV 2026.11.25` @ `1da60cc` 交付 `GlassMPV-2026.11.25-202611251140-unsigned.ipa` | 衍生 `mistriver-lab/CinePlayer` `glassmpv-ios` 分支交付 `GlassMPV-2026.11.25-202611250952-unsigned.ipa`）
- **当前阶段**：`GlassMPV 2026.11.25（MPV/ANE 补帧修复 + 4K 自动禁超分门控 + 默认横屏/旋转 + 返回主界面 + .txt 诊断日志导出）已通过本地 7/7 完整性校验、CI 10/10 XCTest 与 Release 构建并交付 dist/`
- **最后活跃时间**：`2026-11-25 11:42:52` | **最近安全快照**：`1da60cc`（主线 `mistriver-lab/GlassMPV` CI Run `45540910746`）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 GlassMPV MPV/ANE 补帧修复、4K禁超分、默认横屏与手动旋转、返回主界面与 .txt 日志导出，CI Run 45540910746 全绿并交付 dist/GlassMPV-2026.11.25-202611251140-unsigned.ipa`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](file:///C:/Users/21920/Desktop/ipa开发/CHANGELOG.md)）：
  * [x] **修复 MPV 120Hz 时域平滑与 ANE 光流真补帧不生效**：`MPVPlayerCore.swift` 配置 `interpolation-threshold=-1` + `tscale=linear`（解除整数倍刷新率屏蔽插帧）；`VTOpticalFlowEngine.swift` 修复像素格式池数组键异常、`spatialScaleFactor=2` 失败回退、按实测解码尺寸重建会话、首帧入队后再启动音频时钟，并补全 ANE 诊断日志采集。
  * [x] **新增 4K 片源自动禁用超分门控 (`SuperResolutionPolicy`)**：`width/height` 达 `3840×2160` 及以上时自动屏蔽 MPV GLSL 超分与 ANE 2× 空间超分，UI 控制台、HUD 与自检报告同步透出原因。
  * [x] **新增默认横屏起播、手动旋转、返回主界面与 `.txt` 诊断日志导出 (`OrientationController` + `DiagnosticLogExporter` + `LiquidGlassPlayerView`)**：打开视频默认进横屏并支持工具栏旋转切换；支持一键返回主界面与错误横幅返回；诊断中心支持分享/导出完整 `.txt` 日志文件。
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
> 🟢 **[PASS]** `GlassMPV 2026.11.25`（主线 `mistriver-lab/GlassMPV` @ `1da60cc`，CI Run `45540910746`，耗时 `7m35s`）iOS 模拟器 `GlassMPVTests` 10/10 通过（`10.144s`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-2026.11.25-202611251140-unsigned.ipa`（`21,689,113` bytes，含 58 个 GLSL 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（7/7 in `0.17s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（`GlassMPV 2026.11.25` 全绿出包；当前无待办）
- **交付与工作区归档**：
  - 主线交付 IPA：`dist/GlassMPV-2026.11.25-202611251140-unsigned.ipa`（`21,689,113` bytes；`Info.plist` 校验 `CFBundleIdentifier=com.glassmpv.player`、`CFBundleShortVersionString=2026.11.25`、`CFBundleVersion=202611251140`、`CFBundleDisplayName=GlassMPV`，内含 58 个 GLSL 着色器）。
  - 衍生 `glassmpv-ios` 最新工作仓库：`C:\Users\21920\.gemini\antigravity\brain\f72f0ae8-3254-4317-a0be-ff892bc49a0f\scratch\CinePlayer-repo`（`glassmpv-ios` @ `feb753a`，CI Run `45527540874` 交付 `dist/GlassMPV-2026.11.25-202611250952-unsigned.ipa`）。
- **待办清单**：无待办。