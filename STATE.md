# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `3a30121` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `ed3e252` | 最新交付 IPA `dist/GlassMPV-2026.11.27-202611271024-unsigned.ipa`）
- **当前阶段**：`已修复补帧档位切换失效（Picker id 改为 Self + 直点胶囊热切换）、打通杜比视界/HDR10 EDR 峰值亮度、移除内置 3 秒测试并重构极简 Liquid Glass 界面；CI Run 45927575289 全绿（22/22）、IPA 已下载校验（2.65MB）并投递微信「文件传输助手」，待真机验证`
- **最后活跃时间**：`2026-11-27 10:28:30` | **最近安全快照**：`ed3e252`（CI Run `45927575289` 绿灯出包，`3a30121` 为私有主线代码与单测同步点）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已修复补帧档位切换失效并支持热切换、杜比视界/HDR EDR 峰值亮度、移除 3 秒测试并重构极简交互界面（CI Run 45927575289 全绿 22/22），IPA 已投递微信「文件传输助手」，待真机实测`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
  * [x] 完成去 MPV/58着色器清理与 `120fps LowLatency` 优先修复（`cf1e70b` / `f8dcb6b`），CI Run `45924168545` 全绿 21/21，IPA 瘦身至 `2,750,992` bytes。
  * [x] 响应 `095509` 实机日志（`864324e`、`fe341a3`、`3a30121` / 公开镜像 `ed3e252`）：修复 `OpticalFlowTargetFPS` / `InterpolationMode` `id: Self` 导致的 SwiftUI Picker 切档零响应问题，彻底撤除 `Picker` 改用直选胶囊条并新增播放中 `VTFrameProcessor` 原地热切换；打通杜比视界（`dvh1`/`dvhe`/`dvcC`/`dvvC`、`x420` 10-bit、逐帧 HDR 元数据透传、`preferredDynamicRange = .high` 与 BT.2020/PQ 回填）；移除内置 3 秒测试并重塑极简播放界面与快捷开关；CI Run `45927575289`（`6m44s`）`GlassMPVTests` 22/22 全绿交付 `2,778,480` bytes IPA。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV 2026.11.27`（公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `ed3e252`，CI Run `45927575289`，耗时 `6m44s`）iOS 模拟器 `GlassMPVTests` 22/22 通过（`Executed 22 tests, with 0 failures (0 unexpected) in 11.436 (14.560) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-2026.11.27-202611271024-unsigned.ipa`（`2,778,480` bytes，纯原生系统框架 + `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.22s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 `GlassMPVTests 22/22` 与 Release IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-2026.11.27-202611271024-unsigned.ipa`（`2,778,480` bytes；`Info.plist` 校验 `CFBundleIdentifier=com.glassmpv.player`、`CFBundleShortVersionString=2026.11.27`、`CFBundleVersion=202611271024`，含 `Assets.car`，0 个 `.glsl` 着色器）。
  - 最新实机诊断日志：`GlassMPV-Log-20261127-095509.txt`（实机导出日志，Build `202611270948`，`2960×2160` `hev1`）。
  - **已定因根因与本轮已核验架构约束**：
    1. **补帧切档零响应根因与热切换**：`095509` 审计流零条 `setOpticalFlowTargetFPS` 记录，根因为 `OpticalFlowTargetFPS`/`InterpolationMode` 的 `id: String` 与 SwiftUI `Picker` 隐式 Tag 失配；现改 `id: Self` 并在 `LiquidGlassPlayerView` 全面采用直选胶囊条 `FrameRatePillStrip`（首页预设 / 播放底栏 / 控制台），播放期通过 `updateTargetConfiguration` + `applyUserSwitchInPlace` 原地热替换 `VTFrameProcessor`（零中断音轨与读取器）。
    2. **杜比视界与 HDR 全链路**：`HEVCFormatNormalizer` 优先保留 `dvh1`/`dvcC`/`dvvC` 与静动态 HDR 元数据，`VTDecompressionSession` 启用 `kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata`，`extractTrackMetrics` 与 `makeSampleBuffer` 修复 Profile 5 `10-bit` 与 `BT.2020/PQ` 附件识别/回填，`SampleBufferDisplayContainerView` 默认启用 `preferredDynamicRange = .high` 与防休眠；开放 `HDR/EDR`、`画面铺满(AspectFill)` 与 `循环` 快捷开关。
    3. **极简界面与去 MPV/去 3 秒测试**：移除首页与日志中心内置 3 秒自测视频入口（保留 `TestVideoGenerator.swift` 专供 XCTest）；HUD 播放 4.5s 自动隐藏、默认收敛浮窗仅在右上角徽章点击时展开；保留 `LowLatency` 全分辨率优先与关闭补帧原生硬解直通模式。
    4. **Swift 6 与门禁红线**：`selectPrimaryVideoTrack` 用 `#isolation`、`selectPlayableAudioTrack` 标 `@MainActor`；内存采样用 `task_self_trap()`，`VTOpticalFlowEngine.swift` 的 `runOpticalFlowTask..#endif` 区间内严禁直接出现 `.lock()`/`.unlock()`（锁辅助统一写在区间外）。
- **待办清单**：
  - [x] 完成 `095509` 实机日志补帧切换、杜比视界/HDR、去 3 秒测试与极简界面改造；本地 `pytest tests/test_project_integrity.py -v`（`6 passed`）与 CI Run `45927575289`（`GlassMPVTests 22/22 PASS`、`6m44s`）全绿。
  - [x] 下载校验 `dist/GlassMPV-2026.11.27-202611271024-unsigned.ipa`（`2,778,480` bytes）并通过微信「文件传输助手」投递，待真机侧载验证全档位热切换、杜比视界与新界面体验。