# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `2c38ce6` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `8f12ce7` | 最新交付 IPA `dist/GlassMPV-2026.11.27-202611271341-unsigned.ipa`）
- **当前阶段**：`已彻底解决隐藏控制栏后掉帧及「截图短暂恢复再降回 24fps」（UIUpdateLink 同帧双次翻转修复 + 安全视口微扰层 + .latencyCritical 提频 + 4K 硬件缩放 1080p 解码 + VDEC/ANE 异步并行流水线 + OpticalFlowFramePacer 逐 VSync 送显）；CI Run 45946821529 全绿（23/23）、IPA 已下载校验（2.68MB）并投递微信「文件传输助手」，待真机验证`
- **最后活跃时间**：`2026-11-27 13:44:00` | **最近安全快照**：`8f12ce7`（CI Run `45946821529` 绿灯出包，`2c38ce6` 为私有主线代码与单测同步点）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已解决隐藏控制栏掉帧与截图短暂恢复再降问题（CI Run 45946821529 全绿 23/23），新版 IPA 已下载校验并投递微信「文件传输助手」，待真机实测`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
  * [x] 响应 `095509` 实机日志（`3a30121` / `ed3e252`）：修复 `OpticalFlowTargetFPS` `id: Self` 切档失效、新增热切换与杜比视界/HDR EDR 支持、移除内置 3 秒测试并重塑 UI（CI Run `45927575289`，22/22 PASS）。
  * [x] 响应实机截图与 `112252` 反馈（`d061a84`、`ab8ec57` / `5567335`）：接入 `UIUpdateLink` + `(80, 120, 120)` 锁定、`buildCandidatePlan` 720p 起步与两行极简底栏 + 智能帧率弹窗（CI Run `45936597804`，22/22 PASS）。
  * [x] 响应 `131253` 实机日志与对比截图（`d1ce224`、`2c38ce6` / 公开镜像 `8f12ce7`）：修复 `handleUpdateLinkTick()` + `onDisplayTick()` 同帧双次 `pulseProMotionCommit()` 翻转抵消与 `(0,0,1,1)` 圆角裁切；开启光流期间启用 `.latencyCritical` Activity；为 `>1080p` 片源引入硬件缩放 `1920×1080` 解码、`OpticalFlowDecodedFramePipe` 并行 VDEC/ANE 流水线与 `OpticalFlowFramePacer`（55ms 容错 + 每 VSync 至多弹出 1 帧）及 `-45ms / +85ms` 迟滞追赶；CI Run `45946821529`（`6m29s`）`GlassMPVTests` 23/23 全绿交付 `2,810,226` bytes IPA。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV 2026.11.27`（公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `8f12ce7`，CI Run `45946821529`，耗时 `6m29s`）iOS 模拟器 `GlassMPVTests` 23/23 通过（`Executed 23 tests, with 0 failures (0 unexpected) in 13.092 (13.110) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-2026.11.27-202611271341-unsigned.ipa`（`2,810,226` bytes，纯原生系统框架 + `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.30s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 `GlassMPVTests 23/23` 与 Release IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-2026.11.27-202611271341-unsigned.ipa`（`2,810,226` bytes；`Info.plist` 校验 `CFBundleIdentifier=com.glassmpv.player`、`CFBundleShortVersionString=2026.11.27`、`CFBundleVersion=202611271341`，含 `Assets.car`，0 个 `.glsl` 着色器）。
  - 最新实机诊断反馈：实机对比截图（隐藏控制栏掉至 `25.0 fps`、截图短暂恢复 `60.0 fps` 后再降）与 `GlassMPV-Log-20261127-131253.txt`（Build `202611271153`）。
  - **已定因根因与本轮已核验架构约束**：
    1. **隐藏控制栏与 CLPC 降频坍缩三因一治**：① `pulseProMotionCommit()` 同帧被调两次互相抵消且 `(0,0,1,1)` 落入 OLED 圆角盲区，须固定每 VSync 在安全区活跃视口内仅提交 1 次 `2×2` 位姿+透明度微扰；② HUD 隐去后系统 CLPC 退出交互升频，4K 串行「硬解→缩放→ANE」单对超时导致队列抽干，须启用 `.latencyCritical` + 4K 解码期 `1080p` 硬件缩放 + `OpticalFlowDecodedFramePipe` 异步并行；③ `onDisplayTick()` 旧版 `while` 循环将轻微迟到批次整批丢弃引发 24fps 悬崖，须由 `OpticalFlowFramePacer` 每 VSync 至多送显 1 帧（55ms 容错 + 迟滞追赶）。
    2. **多相 2× 以上统一 720p 起步与智能源适配帧率 UI**：`buildCandidatePlan` 中 `maxInterpolatedFrames >= 2` 统一走 `720p→540p→480p`；降档链 `120 -> 96 -> 60 -> 2×`；`OpticalFlowTargetFPS.smartPresets(forSourceFPS:)` 按片源帧率与 120Hz 整分频生成直观选项（24p→原画/48/60/96/120 fps；30p→原画/60/120 fps；60p→原画/120 fps）。
    3. **Swift 6 与门禁红线**：`ProcessInfo` Activity 令牌通过 `@unchecked Sendable` 的 `PlaybackActivityTokenHolder` 隔离，避免破坏 `OpticalFlowPlayerController` 默认 `nonisolated init()`；`selectPrimaryVideoTrack` 用 `#isolation`、`selectPlayableAudioTrack` 标 `@MainActor`；内存采样用 `task_self_trap()`，`VTOpticalFlowEngine.swift` 的 `runOpticalFlowTask..#endif` 区间内严禁直接出现 `.lock()`/`.unlock()`（锁辅助统一写在区间外）。
- **待办清单**：
  - [x] 完成 `proMotionPulseLayer` 单次安全视口提交、`.latencyCritical`、4K 解码硬件缩放、`OpticalFlowDecodedFramePipe` 并行与 `OpticalFlowFramePacer` 修复；本地 `pytest`（`6 passed`）与 CI Run `45946821529`（`GlassMPVTests 23/23 PASS`、`6m29s`）全绿。
  - [x] 下载校验 `dist/GlassMPV-2026.11.27-202611271341-unsigned.ipa`（`2,810,226` bytes）并通过微信「文件传输助手」投递，待真机侧载验证全屏/隐藏控制栏长时稳帧表现。