# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（主线 `GlassMPV 2026.11.25` @ `cd0c283` | 最新交付 IPA `GlassMPV-2026.11.25-202611251523-unsigned.ipa`）
- **当前阶段**：`已完成运行期 2s 黑匣子采样、libmpv 探针与补帧客观判定、ANE 纯音轨与 5 级 Reader 回退加固，CI 全绿出包并交付微信「文件传输助手」，待实机验证新版日志`
- **最后活跃时间**：`2026-11-25 15:29:00` | **最近安全快照**：`cd0c283`（CI Run `45566848770`）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 cd0c283 运行期黑匣子采样、MPV 探针判定与 ANE 解码回退交付，IPA 已投递微信文件传输助手`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](file:///C:/Users/21920/Desktop/ipa开发/CHANGELOG.md)）：
  * [x] 修复 `VTOpticalFlowEngine.swift` Swift 6 `noasync` 锁与 `nonisolated` 并发编译，CI 全绿（`10m17s`，`GlassMPVTests` 15/15 PASS），交付 `dist/GlassMPV-2026.11.25-202611251421-unsigned.ipa`。
  * [x] 落地运行期 2s 黑匣子遥测采样（`RuntimeTelemetrySample`）、`MPVProbeSnapshot` 探针与 `InterpolationVerdict` 客观判定、4K 自适应 `tscale=linear`、切入 ANE 调用 `releaseMediaForExternalEngine()` 释放硬解会话、以及 ANE 纯音轨 `AVMutableComposition` / 5 级 `AVAssetReader` 回退 / 源帧标准化（commit `cd0c283`），CI Run `45566848770` 全绿（`9m11s`，`GlassMPVTests` 18/18 PASS），交付 `dist/GlassMPV-2026.11.25-202611251523-unsigned.ipa` 并发送至微信「文件传输助手」。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV 2026.11.25`（主线 `mistriver-lab/GlassMPV` @ `cd0c283`，CI Run `45566848770`，耗时 `9m11s`）iOS 模拟器 `GlassMPVTests` 18/18 通过（`7.594s`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-2026.11.25-202611251523-unsigned.ipa`（`21,762,731` bytes，含 58 个 GLSL 着色器 & `Assets.car`）；主仓本地 `pytest tests/test_project_integrity.py -v`（7/7 in `0.19s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（全量单测与无签 IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 主线最新交付 IPA：`dist/GlassMPV-2026.11.25-202611251523-unsigned.ipa`（`21,762,731` bytes；`Info.plist` 校验 `CFBundleIdentifier=com.glassmpv.player`、`CFBundleShortVersionString=2026.11.25`、`CFBundleVersion=202611251523`、`CFBundleDisplayName=GlassMPV`，内含 58 个 GLSL 着色器与 `Assets.car`）。
  - 历史参考实机日志：`C:\Users\21920\Documents\xwechat_files\wxid_8mhh4tfklkan22_9a3a\msg\file\2026-11\GlassMPV-Log-20261125-143242.txt`。
- **待办清单**：
  - [x] 完成 `PlaybackTelemetry`、`MPVPlayerCore`、`VTOpticalFlowEngine`、`DiagnosticLogExporter`、`LiquidGlassPlayerView`、`AppReleaseInfo`、`CHANGELOG.md` 与单测/完整性断言并推送 `cd0c283`。
  - [x] CI Run `45566848770` 全绿，下载并校验 `dist/GlassMPV-2026.11.25-202611251523-unsigned.ipa`，已发送至微信「文件传输助手」。
  - [ ] 在 iPhone 实机安装 `GlassMPV-2026.11.25-202611251523-unsigned.ipa` 播放片源测试 MPV 120Hz 补帧与 ANE 光流核，导出 `.txt` 诊断日志回传核验。