# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（主线 `GlassMPV 2026.11.26` @ `1014b2b` | 最新交付 IPA `dist/GlassMPV-2026.11.26-202611260950-unsigned.ipa`）
- **当前阶段**：`已完成 ANE 4K 双后端规划/运行期自愈改造（cf3d397）、Hashable 修复（42a9739）与模拟器播放轮询窗口调整（1014b2b），云端 CI Run 45737880768 全绿出包（XCTest 20/20 PASS），已下载校验并投递微信「文件传输助手」，待实机验证 4K ANE 补帧日志`
- **最后活跃时间**：`2026-11-26 09:57:00` | **最近安全快照**：`1014b2b`（CI Run `45737880768` 绿灯出包）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`CI Run 45737880768 绿灯出包（dist/GlassMPV-2026.11.26-202611260950-unsigned.ipa），已投递微信「文件传输助手」，待实机验证 4K ANE 补帧`
- 最近交付闭环（更早的 2 项历史里程碑已归档至 [CHANGELOG.md](file:///C:/Users/21920/Desktop/ipa开发/CHANGELOG.md)）：
  * [x] 修复 `VTOpticalFlowEngine.swift` `VTDecompressionSessionCreate` 参数标签与 `test_project_integrity.py` 断言（`b4676df`）；CI Run `45588353144` 全绿出包并交付微信「文件传输助手」。
  * [x] 完成 `VTOpticalFlowEngine.swift` 跨平台 `OpticalFlowResolutionPlanner`、双后端 `ActiveOpticalFlowConfiguration`（LowLatency + FRC）、边界查询、不覆盖 `IOSurfaceProperties`、首帧 `-19730` 自动降档切后端自愈、`LiquidGlassPlayerView.swift` `activeBackendLabel` 透出、`VERSION`/`project.yml`/`CHANGELOG.md`/`AppReleaseInfo.swift` 升级 `2026.11.26`（`cf3d397`）。
  * [x] 修复 `OpticalFlowCandidate` / `OpticalFlowBackendKind` `Hashable`（`42a9739`）与 `testMPVUIControllerPlaybackWithWindowHost` 慢跑器轮询窗口放宽至 30s（`1014b2b`），CI Run `45737880768` 全绿出包并交付微信「文件传输助手」。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV 2026.11.26`（主线 `mistriver-lab/GlassMPV` @ `1014b2b`，CI Run `45737880768`，耗时 `7m23s`）iOS 模拟器 `GlassMPVTests` 20/20 通过（`9.866 (9.938) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-2026.11.26-202611260950-unsigned.ipa`（`21,828,153` bytes，含 58 个 GLSL 着色器 & `Assets.car`）；主仓本地 `pytest tests/test_project_integrity.py -v`（7 passed in `0.64s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（全量单测与无签 IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 主线最新交付 IPA：`dist/GlassMPV-2026.11.26-202611260950-unsigned.ipa`（`21,828,153` bytes；`Info.plist` 校验 `CFBundleIdentifier=com.glassmpv.player`、`CFBundleShortVersionString=2026.11.26`、`CFBundleVersion=202611260950`，内含 58 个 GLSL 着色器与 `Assets.car`）。
  - 最新实机诊断日志：`C:\Users\21920\Documents\xwechat_files\wxid_8mhh4tfklkan22_9a3a\msg\file\2026-11\GlassMPV-Log-20261125-182350.txt`（Build `202611251752`，`2960×2160` HEVC 23.98fps：`MPV` 仅线性帧混合非光流且 4K `mis=25/del=42`；`ANE` 成功硬解送显 `pres=206`，但 `interp=0, fail=229` 全部报 `VTFrameProcessorErrorDomain(-19730): Processor is not initialized`）。
- **待办清单**：
  - [x] 拉取 `45735826023` 与 `45736501105` 失败日志并完成双轮修复：`OpticalFlowCandidate`/`OpticalFlowBackendKind` 遵循 `Hashable`（`42a9739`），放宽 `testMPVUIControllerPlaybackWithWindowHost` 轮询窗口至 30s（`1014b2b`）；CI Run `45737880768` 全绿出包，已下载校验 `dist/GlassMPV-2026.11.26-202611260950-unsigned.ipa` 并投递微信「文件传输助手」。
  - [ ] 使用 `GlassMPV-2026.11.26-202611260950-unsigned.ipa` 进行真机安装与 4K ANE 补帧实测（核验双后端自愈降档与实际补帧输出）。