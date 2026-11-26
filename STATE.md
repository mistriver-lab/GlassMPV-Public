# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `98ed758` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `fdb7e02` | 最新交付 IPA `dist/GlassMPV-2026.11.26-202611261855-unsigned.ipa`）
- **当前阶段**：`已完成 105144 实机日志 5 项修复与诊断日志升级、代码脱敏与公开 CI 镜像（mistriver-lab/GlassMPV-Public）、本地 pytest 7/7、CI Run 45804341550 全绿（GlassMPVTests 24/24）、IPA 下载校验及微信「文件传输助手」投递；等待真机侧载验证实测反馈`
- **最后活跃时间**：`2026-11-26 18:59:00` | **最近安全快照**：`fdb7e02`（CI Run `45804341550` 绿灯出包，`98ed758` 为私有主线同步点）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成105144实机日志5项修复与诊断升级（CI Run 45804341550 全绿 24/24），新版 IPA 已下载校验并投递微信「文件传输助手」，待真机实测`
- 最近交付闭环（更早的 4 项历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
  * [x] 完成 ANE 多档位目标帧率（`2×/60/72/96/120fps`）全栈落地（`1b09b44`、`dbaaca2`）：`OpticalFlowTargetFPS`、`OpticalFlowPhaseScheduler`（整倍等分 + 非整倍栅格重采样）、`OpticalFlowBudgetGuard`（先降分辨率再降目标帧率）、单次多缓冲多相插帧、控制台分段选择器与 2× 超分互斥、遥测与 `GlassMPVTests` 单测；CI Run `45743332104` 绿灯出包并已下载校验 `dist/GlassMPV-2026.11.26-202611261041-unsigned.ipa`。
  * [x] 完成 `105144` 实机日志 5 项修复与诊断日志升级编码（`49c3423`）：VTLowLatency 2^x-1 指数映射、原生像素格式优先级与硬解减负、双拷贝消除、片源透传缓存、降档冷却期 + 时钟追平护栏、暂停挂起 `CADisplayLink` + 动态帧率区间 + `ThermalState` 限档、4K 非放大着色器放行 + 开关状态保留、以及 `lastSessionSummary`/`[ui-switch]`/毫秒级 500 条缓冲/设备内存采样的诊断升级；本地 `pytest tests/test_project_integrity.py -v`（7/7 PASS）。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV 2026.11.26`（公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `fdb7e02`，CI Run `45804341550`，耗时 `11m10s`）iOS 模拟器 `GlassMPVTests` 24/24 通过（`Executed 24 tests, with 0 failures (0 unexpected) in 34.911 (36.039) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-2026.11.26-202611261855-unsigned.ipa`（`21,875,397` bytes，含 58 个 GLSL 着色器 & `Assets.car`）；主仓本地 `pytest tests/test_project_integrity.py -v`（7 passed in `0.17s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 7/7`、远程 `GlassMPVTests 24/24` 与 Release IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-2026.11.26-202611261855-unsigned.ipa`（`21,875,397` bytes；`Info.plist` 校验 `CFBundleIdentifier=com.glassmpv.player`、`CFBundleShortVersionString=2026.11.26`、`CFBundleVersion=202611261855`，内含 58 个 GLSL 着色器与 `Assets.car`）。
  - 最新实机诊断日志：`GlassMPV-Log-20261126-105144.txt`（实机导出日志，Build `202611261041`，`2960×2160` HEVC 23.98fps）。
  - **已定因根因与下轮已核验实施约束（含全部 5 项红线）**：
    1. **VTLowLatency 指数规则**：`VTLowLatencyFrameInterpolationConfiguration(numberOfInterpolatedFrames:)` 按 Apple 官方 $2^x - 1$ 规则传指数 $x$（1 帧→`1`，2~3 帧如 96fps→`2`，4~7 帧→`3`），避免传 3 误开 7 级流水线。
    2. **像素格式与硬解减负**：`selectOptimalPixelFormat` 补齐 `xf20` / `420f` / Lossless YUV / 32-bit 并同步用于 `makeDestinationPool`，将 `RGhA`/`RGfA` 排至最末；`VTDecompressionSession` 强制以原生 `420v`/`x420` 硬解 4K（禁止直接硬解出 51MB `RGhA`）；若 `FRC` 仅支持 `RGhA` 且多相插帧，初始直接从 720p 候选起跑并收敛队列上限（`<= 30`）；`processDecodedFrame` 消除 L2803/L3048 双重 `VTPixelTransferSession` 冗余拷贝；按片源 URL 缓存 `AVAssetReader` 不可用（`-12906`）直走压缩透传。
    3. **降档风暴治理与热限档**：移除 `downgrade` 后的 `budgetGuard.reset()`（保留 `cooldownRemaining`），新增 `awaitingClockCatchUpAfterSwitch` 排空旧时钟落后帧后再恢复预算计数；暂停时挂起 `CADisplayLink` 并按目标帧率动态设置 `preferredFrameRateRange`；接入 `ThermalState` `.serious`/`.critical` 主动限档。
    4. **开关联动与 4K 门控精度**：保留 `SuperResolutionPolicy.isAlready4K(2960, 2160) == true`（兼容 `GlassMPVTests:L809`），通过 `SingleShaderOption.isUpscaler` 放行 4K 下的 `KrigBilateral` / `Adaptive Sharpen` 并同步复位 `coordinator` 超分预设；修复 MPV ↔ ANE 切换覆盖 `.off` 及暂停态调用 `load()` 擅自起播。
    5. **Swift 6 与门禁红线 + 5 项诊断日志升级**：内存采样用 `task_self_trap()`（禁 `mach_task_self_` 全局可变引用）与 `MemoryLayout.size(ofValue: sysinfo.machine)`；`VTOpticalFlowEngine.swift` 的 `runOpticalFlowTask..#endif` 区间内严禁直接出现 `.lock()`/`.unlock()`（兼容 `test_project_integrity.py:L280-285`）；保留 `lastSessionSummary` 修复退回主界面导出摘要归零、新增 `[ui-switch]` 审计流、Timeline 补齐 `backend`/`q`/`avDelta`/`memMB`/`thermalState` 与设备头部、日志时间戳精确至 `HH:mm:ss.SSS` 并扩容环形缓冲至 500 条。
- **待办清单**：
  - [x] 通过 `cua-driver`（`Weixin.exe` `pid=27340` `window_id=1904562`）将 `dist/GlassMPV-2026.11.26-202611261041-unsigned.ipa`（`20.8M` / `21,852,092` bytes）投递至微信「文件传输助手」并经截图核验发送完成（`10:49`）。
  - [x] 完成 `105144` 实机日志 5 项修复与诊断日志升级，补充 3 项单测并跑通本地 `pytest tests/test_project_integrity.py -v`（`7 passed in 0.17s`）；脱敏本地路径后创建公开 CI 镜像 `mistriver-lab/GlassMPV-Public`（`fdb7e02`）并跑通 CI Run `45804341550`（`GlassMPVTests` 24/24 PASS）。
  - [x] 下载校验 `dist/GlassMPV-2026.11.26-202611261855-unsigned.ipa`（`21,875,397` bytes）并通过微信「文件传输助手」投递，待真机侧载复测。