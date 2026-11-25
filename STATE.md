# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（主线 `GlassMPV 2026.11.25` @ `b4676df` | 最新交付 IPA `GlassMPV-2026.11.25-202611251752-unsigned.ipa`）
- **当前阶段**：`已完成实机日志 GlassMPV-Log-20261125-182350.txt 深度诊断并定位 4K ANE -19730 根因：VTDecompressionSession 已硬解送显 206 帧但 2960x2160 直接送入 VTLowLatencyFrameInterpolation 导致 229 次插帧全部报 VTFrameProcessorErrorDomain(-19730) Processor is not initialized；因上下文达 SPEC-34 红线（~193k Tokens），已将 4 层根治方案写入待办，待 /compact 或新窗直接编码出包`
- **最后活跃时间**：`2026-11-25 18:34:30` | **最近安全快照**：`b4676df`（CI Run `45588353144`）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已定位实机182350日志ANE(-19730)根因，待/compact或新窗落地双后端+1080p自适应协商`
- 最近交付闭环（更早的 2 项历史里程碑已归档至 [CHANGELOG.md](file:///C:/Users/21920/Desktop/ipa开发/CHANGELOG.md)）：
  * [x] 完成 `VTOpticalFlowEngine` 压缩透传（`outputSettings=nil`）+ `HEVCFormatNormalizer` + `VTDecompressionSession` 硬解兜底 + `OpticalFlowPTSReorderBuffer` B 帧 PTS 重排接线、轨道格式日志与去重（`9a53544`、`983ae46`）。
  * [x] 完成「MPV 时域平滑」与「ANE 硬件光流真补帧」语义区分（`PlaybackTelemetry`、`MPVPlayerCore`、`LiquidGlassPlayerView`）、`GlassMPVTests` 新增重组/格式标准化单测、`test_project_integrity.py` 扩展断言及 `AppReleaseInfo` / `CHANGELOG.md` 归档。
  * [x] 修复 `VTOpticalFlowEngine.swift` `VTDecompressionSessionCreate` 参数标签（`videoDecoderSpecification:` -> `decoderSpecification:`）并补充 `tests/test_project_integrity.py` 防复发断言（`b4676df`）；本地 `pytest tests/test_project_integrity.py -v`（7 passed in `0.23s`）PASS；CI Run `45588353144` 全绿出包并交付微信「文件传输助手」。

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
  - [ ] 【新窗/compact 后首步】改造 `Sources/Engine/VTOpticalFlowEngine.swift`（新增跨平台 `OpticalFlowResolutionPlanner` 将 4K 等比缩至 `1480×1080`/720p/540p、接入 `VTFrameRateConversionConfiguration` + `VTLowLatencyFrameInterpolationConfiguration` 双后端、查询 `maximumDimensions`/`minimumDimensions`、强制源帧池规格标准化且不覆盖原生 `IOSurfaceProperties`、首帧 `-19730` 自动降档切后端自愈、防刷屏日志并扩容至 200 行）、透出 `activeBackendLabel` 到 `LiquidGlassPlayerView.swift`、补齐 `GlassMPVTests.swift` 与 `test_project_integrity.py` → 本地 `pytest` → 推送 CI 全绿出包并投递微信「文件传输助手」。