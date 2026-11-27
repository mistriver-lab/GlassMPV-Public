# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `a8d8028` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `a8d8028` | 最新交付 IPA `dist/GlassMPV-0.1.0-beta.5-b27-unsigned.ipa`）
- **当前阶段**：`已完成 v0.1.0-beta.5 (Build 27)：零滤镜 CAMetalLayer 原画 120fps 直通 + 全面对标 Infuse 8 影院体验（5 路协调多手势、屏幕防误触锁、首页 2 列片源网格+C位继续观看大卡、云盘选集抽屉与连播、多音轨切换）；CI Run 45992651188 全绿 39/39，IPA 已校验并投递微信「文件传输助手」`
- **最后活跃时间**：`2026-11-27 19:53:45` | **最近安全快照**：`a8d8028`（CI Run `45992651188` 绿灯出包）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 v0.1.0-beta.5 (Build 27)：零滤镜 CAMetalLayer 原画 120fps 直通 + 对标 Infuse 8 原生手势/首页/选集连播/多音轨，CI Run 45992651188 全绿 39/39 并已投递微信「文件传输助手」；等待用户实机验收`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
    - **原画关闭增强也能锁满 120.0 fps (`MetalVideoEnhancer` + `VTOpticalFlowEngine`)**：`192203` 实机日志证实开增强时 `CAMetalLayer` 直绘稳跑 `120.0fps`，关回原画走 `AVSampleBufferDisplayLayer` 因 `656×480 ↔ 2960×2160` 跳变背压跌至 ~100fps。现通过 `renderToLayerStatus(..., allowPassthrough: true)` 让高刷原画走零滤镜 Shader 直出路径彻底拉齐满帧。
    - **对标 Infuse 8 影院手势与交互 (`PlayerGestureOverlay` + `LiquidGlassPlayerView` + `CloudMediaLibraryView`)**：左/右双击 ±10s 连击叠加、中间双击/双指轻点播放暂停、长按 2.0× 临时快进、水平滑精准拖进度、左滑亮度/右滑系统音量、独立防误触锁、极简首页 + 2 列片源网格、云盘选集抽屉与自动连播、多音轨切换及点击切换剩余时长。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV v0.1.0-beta.5`（`mistriver-lab/GlassMPV-Public` @ `a8d8028`，CI Run `45992651188`，耗时 `8m21s`）iOS 模拟器 `GlassMPVTests` 39/39 通过（`Executed 39 tests, with 0 failures (0 unexpected) in 8.589 (8.756) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-0.1.0-beta.5-b27-unsigned.ipa`（`3,725,130` bytes，`CFBundleIdentifier=com.glassmpv.player`，`CFBundleShortVersionString=0.1.0`，`CFBundleVersion=27`，含 `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.35s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 `GlassMPVTests 39/39` 与 Release Beta IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-0.1.0-beta.5-b27-unsigned.ipa`（`3,725,130` bytes）。
  - 最新实机定因日志：`GlassMPV-Log-20261127-192203.txt`。
- **待办清单**：
  - [x] 完成 `v0.1.0-beta.5 (Build 27)` 零滤镜 Metal 120fps 原画直通与对标 Infuse 8 全面体验重塑（CI Run `45992651188`，39/39 PASS，`8m21s`）。
  - [x] 下载校验 `dist/GlassMPV-0.1.0-beta.5-b27-unsigned.ipa`（`3,725,130` bytes）并发送至微信「文件传输助手」。
  - [ ] 用户安装 `v0.1.0-beta.5-b27` 真机实测：验证「原画关闭增强」120fps 锁满、多手势操控、防误触锁、剧集选集连播与新首页体验。
