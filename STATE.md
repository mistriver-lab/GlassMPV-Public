# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `875cd93` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `73b9092` | 最新交付 IPA `dist/GlassMPV-2026.11.27-202611271458-unsigned.ipa`）
- **当前阶段**：`已最终敲定实用帧率档位体系（24p→原画/48/60/96/120fps，正式移除非整除 72fps）、按档位精准锁定 ProMotion 物理刷新率（48Hz/60Hz/120Hz）与 iOS 低电量模式 60Hz 上限；CI Run 45955062278 全绿（23/23）、IPA 已下载校验（2.68MB）并投递微信「文件传输助手」`
- **最后活跃时间**：`2026-11-27 15:01:00` | **最近安全快照**：`73b9092`（CI Run `45955062278` 绿灯出包，`875cd93` 为私有主线代码与单测同步点）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已敲定最终帧率档位矩阵（24p→原画/48/60/96/120fps，移除 72fps）+ 48/60/120Hz 精准锁屏与低电量 60Hz 上限保护（CI Run 45955062278 全绿 23/23），定版 IPA 已下载校验并投递微信「文件传输助手」`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
  * [x] 响应 `131253` 实机日志与对比截图（`d1ce224`、`2c38ce6` / 公开镜像 `8f12ce7`）：修复 `proMotionPulseLayer` 同帧双次翻转与圆角裁切，接入 `.latencyCritical`、4K 解码硬件缩放 `1080p`、`OpticalFlowDecodedFramePipe` 并行与 `OpticalFlowFramePacer`；`135235` 真机实测 4K `120fps` 稳定 `118.7~120.3fps`、`q=60` 零丢帧、内存降至 `~150MB`。
  * [x] 最终敲定档位矩阵与能效优化（`875cd93` / 公开镜像 `73b9092`）：正式移除非 120Hz 整分频的 `72fps`，24p 收敛为 `原画 / 48(2×清晰省电) / 60 / 96(4×高刷甜点) / 120 fps`；`recommendedDisplayFrameRateRange` 对 `48fps` 精准锁 `(48,48,48)`、`60fps` 锁 `(60,60,60)`、`96/120fps` 锁 `(80,120,120)`；新增 `effectivePowerThermalCap` + `NSProcessInfoPowerStateDidChange` 低电量模式封顶 `60fps`；CI Run `45955062278`（`2m48s`）`GlassMPVTests` 23/23 全绿交付 `2,811,759` bytes 定版 IPA。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV 2026.11.27`（公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `73b9092`，CI Run `45955062278`，耗时 `2m48s`）iOS 模拟器 `GlassMPVTests` 23/23 通过（`Executed 23 tests, with 0 failures (0 unexpected) in 7.324 (7.562) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-2026.11.27-202611271458-unsigned.ipa`（`2,811,759` bytes，纯原生系统框架 + `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.43s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 `GlassMPVTests 23/23` 与 Release IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-2026.11.27-202611271458-unsigned.ipa`（`2,811,759` bytes；`Info.plist` 校验 `CFBundleIdentifier=com.glassmpv.player`、`CFBundleShortVersionString=2026.11.27`、`CFBundleVersion=202611271458`，含 `Assets.car`，0 个 `.glsl` 着色器）。
  - 最新实机闭环日志：`GlassMPV-Log-20261127-135235.txt`（`Build 202611271341`，4K HEVC `23.98 → 120.3 fps`，`LowLatency 986×720 [×5]`、`hwScale=1480x1080`、`q=60` 零丢帧）。
  - **已定因根因与本轮已核验架构约束**：
    1. **最终档位体系与 ProMotion 精准锁频**：移除 `fps72`，保留 `x2 / fps60 / fps96 / fps120`；`48fps` 锁 `(48, 48, 48)`、`60fps` 锁 `(60, 60, 60)`、`96/120fps` 锁 `(80, 120, 120)`；`effectivePowerThermalCap` 在低电量模式/严重过热下封顶 `60fps` / `2×`，避免 60Hz 屏幕上限空烧 120fps ANE 算力。
    2. **隐藏控制栏与 CLPC 降频坍缩三因一治**：微扰层安全区单次提交（`x >= 64, y >= 12`）、`.latencyCritical` + 4K 硬件缩放 `1080p` 解码 + `OpticalFlowDecodedFramePipe` 并行、`OpticalFlowFramePacer`（`55ms` 容错 / `0.006s` 早判 + 逐 VSync 单帧弹出 + `-45ms / +85ms` 迟滞追赶）。
    3. **Swift 6 与门禁红线**：`ProcessInfo` Activity 令牌通过 `PlaybackActivityTokenHolder` 隔离；`selectPrimaryVideoTrack` 用 `#isolation`、`selectPlayableAudioTrack` 标 `@MainActor`；内存采样用 `task_self_trap()`，`VTOpticalFlowEngine.swift` 的 `runOpticalFlowTask..#endif` 区间内严禁直接出现 `.lock()`/`.unlock()`。
- **待办清单**：
  - [x] 完成实用档位定版、精准锁频（48/60/120Hz）、低电量 60Hz 上限及全绿单测与 Release 打包（CI Run `45955062278`，23/23 PASS，`2m48s`）。
  - [x] 下载校验 `dist/GlassMPV-2026.11.27-202611271458-unsigned.ipa`（`2,811,759` bytes）并投递微信「文件传输助手」。