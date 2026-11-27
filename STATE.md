# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `cf1e70b` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `f8dcb6b` | 最新交付 IPA `dist/GlassMPV-2026.11.27-202611270948-unsigned.ipa`）
- **当前阶段**：`已完成 MPV/58着色器彻底移除（保留跨平台原生硬解直通模式）与 120fps LowLatency 优先补帧修复、本地 pytest 6/6、CI Run 45924168545 全绿（GlassMPVTests 21/21）、IPA 下载校验（2.62MB）及微信「文件传输助手」投递；等待真机侧载验证 120fps`
- **最后活跃时间**：`2026-11-27 09:52:00` | **最近安全快照**：`f8dcb6b`（CI Run `45924168545` 绿灯出包，`cf1e70b` 为私有主线代码与单测同步点）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成去 MPV/58着色器清理与 120fps LowLatency 优先修复（CI Run 45924168545 全绿 21/21），2.62MB 纯原生 IPA 已下载校验并投递微信「文件传输助手」，待真机实测`
- 最近交付闭环（更早的 4 项历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
  * [x] 完成 `105144` 实机日志 5 项修复、公开 CI 镜像（`mistriver-lab/GlassMPV-Public` @ `fdb7e02`）与 CI Run `45804341550`（`GlassMPVTests 24/24`）交付 `dist/GlassMPV-2026.11.26-202611261855-unsigned.ipa`。
  * [x] 响应 `092105` 实机日志（`7dee727`、`cf1e70b` / 公开镜像 `f8dcb6b`）：彻底移除 `MPVKit`/`MPVUI`、`MPVPlayerCore.swift`、`ShaderPreset.swift` 及 58 个 `.glsl` 着色器，保留跨平台原生 `AVAssetReader + VTDecompressionSession` 硬解直通模式（`InterpolationMode.off`）；修正 `120fps` 候选队列禁用 `preferFRC` 并严格将所有 `LowLatency` 档位（`720p→540p→480p`）排在 `FRC` 之前；补充 SwiftUI Picker 幂等守卫与允许 `120fps` 降档至 `96fps` 后再次手动重选；CI Run `45924168545`（`6m24s`）`GlassMPVTests` 21/21 全绿并交付 `2,750,992` bytes 纯原生 IPA。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV 2026.11.27`（公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `f8dcb6b`，CI Run `45924168545`，耗时 `6m24s`）iOS 模拟器 `GlassMPVTests` 21/21 通过（`Executed 21 tests, with 0 failures (0 unexpected) in 6.095 (6.188) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-2026.11.27-202611270948-unsigned.ipa`（`2,750,992` bytes，纯原生系统框架 + `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.64s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 `GlassMPVTests 21/21` 与 Release IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-2026.11.27-202611270948-unsigned.ipa`（`2,750,992` bytes；`Info.plist` 校验 `CFBundleIdentifier=com.glassmpv.player`、`CFBundleShortVersionString=2026.11.27`、`CFBundleVersion=202611270948`，含 `Assets.car`，0 个 `.glsl` 着色器）。
  - 最新实机诊断日志：`GlassMPV-Log-20261127-092105.txt`（实机导出日志，Build `202611261855`，`iPhone16,2` iOS `27.0.1`）。
  - **已定因根因与本轮已核验架构约束**：
    1. **去 MPV 化与纯原生直通**：彻底移除 `MPVKit`/`MPVUI` 依赖及 58 个 `.glsl` 着色器，`OpticalFlowOptions.swift` 定义纯原生 `InterpolationMode`（`.off` / `.vtOpticalFlow`）与 `OpticalFlowTargetFPS`（`x2`/`fps60`/`fps72`/`fps96`/`fps120`）；`InterpolationMode.off` 走跨平台 `AVAssetReader` + 片源透传缓存 + `VTDecompressionSession` 原帧率硬解直通（支持真机与模拟器）。
    2. **120fps `LowLatency` 优先与 Picker 幂等**：`092105` 日志证实 `120fps` 跳入 `FRC`（`RGhA`，内存 `591.3MB`、平均耗时 `68.4ms`）而 `96fps` `LowLatency 986×720` 仅 `215MB`、稳跑 `95.8fps`；`OpticalFlowResolutionPlanner` 现禁用 `preferFRC` 并将全量 `LowLatency`（`720p→540p→480p`）排在 `FRC` 之前；修复 SwiftUI Picker 重复 `2×→2×`/`120fps→120fps` 重载，并允许 `effectiveTargetFPS == .fps96` 时再次手动重试 `.fps120`。
    5. **Swift 6 与门禁红线 + 5 项诊断日志升级**：内存采样用 `task_self_trap()`（禁 `mach_task_self_` 全局可变引用）与 `MemoryLayout.size(ofValue: sysinfo.machine)`；`VTOpticalFlowEngine.swift` 的 `runOpticalFlowTask..#endif` 区间内严禁直接出现 `.lock()`/`.unlock()`（兼容 `test_project_integrity.py:L280-285`）；保留 `lastSessionSummary` 修复退回主界面导出摘要归零、新增 `[ui-switch]` 审计流、Timeline 补齐 `backend`/`q`/`avDelta`/`memMB`/`thermalState` 与设备头部、日志时间戳精确至 `HH:mm:ss.SSS` 并扩容环形缓冲至 500 条。
- **待办清单**：
  - [x] 完成 `092105` 实机日志根因治理与去 MPV 化精简，本地 `pytest tests/test_project_integrity.py -v`（`6 passed`）与 CI Run `45924168545`（`GlassMPVTests 21/21 PASS`、`6m24s`）全绿。
  - [x] 下载校验 `dist/GlassMPV-2026.11.27-202611270948-unsigned.ipa`（`2,750,992` bytes，仅原生依赖）并通过微信「文件传输助手」投递，待真机侧载验证 `120fps` 实测效果。