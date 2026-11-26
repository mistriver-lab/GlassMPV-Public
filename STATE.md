# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（主线 `GlassMPV 2026.11.26` @ `cf3d397` | 上一交付 IPA `dist/GlassMPV-2026.11.25-202611251752-unsigned.ipa`）
- **当前阶段**：`已完成 ANE 4K 双后端规划/运行期自愈改造、UI 透出、CalVer 2026.11.26 与双端测试落盘（commit cf3d397，本地 pytest 7/7 PASS）；云端 CI Run 45735826023 在 xcodebuild test 阶段 exit 65 失败，因当前上下文触及 SPEC-34 红线（~182.7k Tokens），待 /compact 或新窗首步拉取 gh run view 45735826023 --log-failed 定位编译/测试报错并修复重推`
- **最后活跃时间**：`2026-11-26 09:28:10` | **最近安全快照**：`cf3d397`（待排障 CI Run `45735826023`）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已推送cf3d397，CI Run 45735826023报错exit 65待新窗/compact后拉日志修复出包`
- 最近交付闭环（更早的 2 项历史里程碑已归档至 [CHANGELOG.md](file:///C:/Users/21920/Desktop/ipa开发/CHANGELOG.md)）：
  * [x] 完成 `VTOpticalFlowEngine` 压缩透传（`outputSettings=nil`）+ `HEVCFormatNormalizer` + `VTDecompressionSession` 硬解兜底 + `OpticalFlowPTSReorderBuffer` B 帧 PTS 重排接线、轨道格式日志与去重（`9a53544`、`983ae46`）。
  * [x] 修复 `VTOpticalFlowEngine.swift` `VTDecompressionSessionCreate` 参数标签与 `test_project_integrity.py` 断言（`b4676df`）；CI Run `45588353144` 全绿出包并交付微信「文件传输助手」。
  * [x] 完成 `VTOpticalFlowEngine.swift` 跨平台 `OpticalFlowResolutionPlanner`、双后端 `ActiveOpticalFlowConfiguration`（LowLatency + FRC）、边界查询、不覆盖 `IOSurfaceProperties`、首帧 `-19730` 自动降档切后端自愈、`LiquidGlassPlayerView.swift` `activeBackendLabel` 透出、`VERSION`/`project.yml`/`CHANGELOG.md`/`AppReleaseInfo.swift` 升级 `2026.11.26`、`GlassMPVTests.swift` 与 `test_project_integrity.py` 扩充（`cf3d397`），本地 `pytest tests/test_project_integrity.py -v`（7 passed in `0.53s`）PASS。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV 2026.11.25`（主线 `mistriver-lab/GlassMPV` @ `b4676df`，CI Run `45588353144`，耗时 `9m26s`）iOS 模拟器 `GlassMPVTests` 19/19 通过（`19.385 (19.430) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-2026.11.25-202611251752-unsigned.ipa`（`21,808,881` bytes，含 58 个 GLSL 着色器 & `Assets.car`）；主仓本地 `pytest tests/test_project_integrity.py -v`（7 passed in `0.23s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（全量单测与无签 IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 主线最新交付 IPA：`dist/GlassMPV-2026.11.25-202611251752-unsigned.ipa`（`21,808,881` bytes；`Info.plist` 校验 `CFBundleIdentifier=com.glassmpv.player`、`CFBundleShortVersionString=2026.11.25`、`CFBundleVersion=202611251752`、`CFBundleDisplayName=GlassMPV`，内含 58 个 GLSL 着色器、`Assets.car` 与 `CADisableMinimumFrameDurationOnPhone=True`）。
  - 最新实机诊断日志：`C:\Users\21920\Documents\xwechat_files\wxid_8mhh4tfklkan22_9a3a\msg\file\2026-11\GlassMPV-Log-20261125-182350.txt`（Build `202611251752`，`2960×2160` HEVC 23.98fps：`MPV` 仅线性帧混合非光流且 4K `mis=25/del=42`；`ANE` 成功硬解送显 `pres=206`，但 `interp=0, fail=229` 全部报 `VTFrameProcessorErrorDomain(-19730): Processor is not initialized`）。
- **待办清单**：
  - [x] 修复 `b4676df`（`decoderSpecification:` 标签与 `test_project_integrity.py` 断言），CI Run `45588353144` 全绿（`9m26s`），下载校验 `dist/GlassMPV-2026.11.25-202611251752-unsigned.ipa` 并投递微信「文件传输助手」。
  - [x] 读取并根因定位实机报告 `GlassMPV-Log-20261125-182350.txt`（MPV 线性混帧非运动光流；ANE 已硬解送显 206 帧但 4K `2960×2160` 触发 `VTFrameProcessor -19730`）。
  - [x] 完成 `cf3d397` 编码与本地验证：`VTOpticalFlowEngine.swift` 双后端自适应与运行期自愈、`LiquidGlassPlayerView.swift` 后端标签透出、`2026.11.26` 版本/日志、`GlassMPVTests.swift` 与 `test_project_integrity.py`（7 passed in `0.53s`）并推送 `main`。
  - [ ] 【新窗/compact 后首步】拉取 `gh run view 45735826023 --log-failed` 定位 `xcodebuild test` exit 65 报错（大概率为 `VTFrameRateConversionConfiguration` / `VTFrameRateConversionParameters` / `VTFrameProcessorConfiguration.minimumDimensions`/`maximumDimensions` 在 Xcode 26 Simulator/Device SDK 签名或 `#if !targetEnvironment(simulator)` 宏外引用问题）→ 修复后本地跑 `pytest tests/test_project_integrity.py -v` → 推送 `main` 等 CI 绿灯 → `gh run download <run_id> -n GlassMPV-unsigned-ipa -D dist` 校验 IPA 并通过 `cua-driver` 投递微信「文件传输助手」。