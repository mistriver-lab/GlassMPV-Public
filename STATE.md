# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `ab8ec57` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `5567335` | 最新交付 IPA `dist/GlassMPV-2026.11.27-202611271153-unsigned.ipa`）
- **当前阶段**：`已根治隐藏控制栏掉回 24Hz（UIUpdateLink + 120Hz VSync 锁定）、72fps 起步分辨率与重启日志保留，并重构为两行极简底栏 + 智能源适配帧率弹窗；CI Run 45936597804 全绿（22/22）、IPA 已下载校验（2.68MB）并投递微信「文件传输助手」，待真机验证`
- **最后活跃时间**：`2026-11-27 11:55:30` | **最近安全快照**：`5567335`（CI Run `45936597804` 绿灯出包，`ab8ec57` 为私有主线代码与单测同步点）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已解决隐藏控制栏掉回 24Hz、72fps 起步超限与两行极简底栏+智能源适配帧率弹窗（CI Run 45936597804 全绿 22/22），新版 IPA 已下载校验并投递微信「文件传输助手」，待真机实测`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
  * [x] 响应 `095509` 实机日志（`3a30121` / `ed3e252`）：修复 `OpticalFlowTargetFPS` `id: Self` 切档失效、新增热切换与杜比视界/HDR EDR 支持、移除内置 3 秒测试并重塑 UI（CI Run `45927575289`，22/22 PASS）。
  * [x] 响应实机截图与 `112252` 反馈（`d061a84`、`ab8ec57` / 公开镜像 `5567335`）：在 `SampleBufferDisplayContainerView.didMoveToWindow()` 接入 `UIUpdateLink(requiresContinuousUpdates=true, wantsImmediatePresentation=true)` + `1×1` 微扰层并在补帧时锁定 120Hz 区间 `(80, 120, 120)` 根治隐藏 HUD 后掉回 24Hz；`buildCandidatePlan` 将 `maxInterp >= 2`（含 72fps/3×）统一改为 720p 起跑；底栏精简为两行 + 智能源适配 `FrameRatePresetStrip` 弹窗并持久化最近会话日志；CI Run `45936597804`（`2m18s`）`GlassMPVTests` 22/22 全绿交付 `2,808,232` bytes IPA。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV 2026.11.27`（公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `5567335`，CI Run `45936597804`，耗时 `2m18s`）iOS 模拟器 `GlassMPVTests` 22/22 通过（`Executed 22 tests, with 0 failures (0 unexpected) in 13.989 (14.643) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-2026.11.27-202611271153-unsigned.ipa`（`2,808,232` bytes，纯原生系统框架 + `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.37s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 `GlassMPVTests 22/22` 与 Release IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-2026.11.27-202611271153-unsigned.ipa`（`2,808,232` bytes；`Info.plist` 校验 `CFBundleIdentifier=com.glassmpv.player`、`CFBundleShortVersionString=2026.11.27`、`CFBundleVersion=202611271153`，含 `Assets.car`，0 个 `.glsl` 着色器）。
  - 最新实机诊断反馈：实机对比截图（隐藏控制栏掉至 `23.4 fps`）与 `GlassMPV-Log-20261127-112252.txt`（Build `202611271024`）。
  - **已定因根因与本轮已核验架构约束**：
    1. **隐藏控制栏 ProMotion 24Hz 退化根因与保活红线**：`AVSampleBufferDisplayLayer` 不触发 CoreAnimation 图层提交，导致 HUD 隐藏后系统降至 24Hz；须使用 `UIUpdateLink(view:)` + `1×1` 微扰层，且 **严禁在 `init(frame:)`（`window == nil`）前设置 `requiresContinuousUpdates = true`**，必须在 `didMoveToWindow()` 且 `window?.windowScene != nil` 后激活。
    2. **多相 2× 以上统一 720p 起步与智能源适配帧率 UI**：`buildCandidatePlan` 中 `maxInterpolatedFrames >= 2` 统一走 `720p→540p→480p`；降档链 `120 -> 96 -> 60 -> 2×`；`OpticalFlowTargetFPS.smartPresets(forSourceFPS:)` 按片源帧率与 120Hz 整分频生成直观选项（24p→原画/48/60/96/120 fps；30p→原画/60/120 fps；60p→原画/120 fps）。
    3. **补帧热切换、杜比视界与持久化日志**：`updateTargetConfiguration` + `applyUserSwitchInPlace` 原地切换 `VTFrameProcessor`；`HEVCFormatNormalizer` 保留 `dvh1`/`dvcC`/`dvvC` 与 HDR 元数据，`preferredDynamicRange = .high`；`persistedLastReportURL` 保留上次会话黑匣子日志。
    4. **Swift 6 与门禁红线**：`selectPrimaryVideoTrack` 用 `#isolation`、`selectPlayableAudioTrack` 标 `@MainActor`；内存采样用 `task_self_trap()`，`VTOpticalFlowEngine.swift` 的 `runOpticalFlowTask..#endif` 区间内严禁直接出现 `.lock()`/`.unlock()`（锁辅助统一写在区间外）。
- **待办清单**：
  - [x] 完成 HUD 隐藏 120Hz 保活、`72fps` 720p 起步修复、两行极简底栏 + 智能帧率弹窗及会话日志持久化；本地 `pytest`（`6 passed`）与 CI Run `45936597804`（`GlassMPVTests 22/22 PASS`、`2m18s`）全绿。
  - [x] 下载校验 `dist/GlassMPV-2026.11.27-202611271153-unsigned.ipa`（`2,808,232` bytes）并通过微信「文件传输助手」投递，待真机侧载验证全屏/隐藏控制栏稳定性与智能帧率菜单体验。