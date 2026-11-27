# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `9768748` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `9768748` | 最新交付 IPA `dist/GlassMPV-0.1.0-beta.4-b25-unsigned.ipa`）
- **当前阶段**：`已完成 v0.1.0-beta.4 (Build 25)：根治 184353 实机日志定位的在线高刷补帧失效（分级分辨率降本 + 有界 FIFO + BudgetGuard 自稳帧 + 动态 Pacer 滞后 + 切档扩容）、上线纯原生字幕系统（内嵌软字幕 + SRT/VTT/ASS + 云端同目录自动配对）及 Infuse 风格观看记录（剧照进度卡片墙 + 云盘行进度条 + 自动断点续播）；CI Run 45987364769 全绿 37/37，IPA 已下载校验完毕`
- **最后活跃时间**：`2026-11-27 19:11:30` | **最近安全快照**：`9768748`（CI Run `45987364769` 绿灯出包）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 v0.1.0-beta.4 (Build 25)：在线视频高刷补帧修复 + 纯原生字幕系统 + Infuse 风格观看记录，CI Run 45987364769 全绿 37/37，最新 IPA 已落盘 dist/GlassMPV-0.1.0-beta.4-b25-unsigned.ipa；等待用户安装实机验收`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
    - **在线高刷补帧失效根治 (`RemoteStreamOpticalFlowWorker` + `VTOpticalFlowEngine`)**：`184353` 日志证实 2× 模式 `17.2ms` 稳跑 `48fps`，但切入 `120fps / 96fps / 60fps` 后仍强跑 `978×720` 致单帧推理 `43.5~61.6ms` 打穿 `41.7ms` 预算，叠加单槽丢帧、写死 `85ms` 固定 Pacer 滞后与切档未扩容，引发 `drop=1222` 与帧率坍缩。现已通过 `RemoteOpticalFlowBudgetPlanner`（60/96fps 起步 `540p`、120fps 起步 `480p`）、2 帧 FIFO、`OpticalFlowBudgetGuard` 自稳帧、自适应 `remotePacerLagSeconds` 及切档队列扩容彻底解决。
    - **纯原生字幕系统 (`SubtitleModels` + `SubtitleManager` + `LiquidGlassPlayerView`)**：支持 UTF-8 / UTF-16 / GB18030 解码及 `.srt` / `.vtt` / `.ass` / `.ssa` 解析、内嵌软字幕（`AVPlayerItemLegibleOutput` / 本地 `AVAssetReader`）、夸克/Emby/WebDAV 同目录字幕自动发现与外挂导入，提供字号/底边距/配色/背景透明/±0.25s 时间偏移调节。
    - **Infuse 风格观看记录 (`WatchHistoryStore` + `CloudMediaLibraryView` + `LiquidGlassPlayerView`)**：首页「继续观看」16:9 剧照卡片墙 +「全部记录」面板、云盘列表行进度条与「续播 / 已看完」徽章、自动截帧剧照及暂停/退后台/退出实时落盘与一键断点续播。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV v0.1.0-beta.4`（`mistriver-lab/GlassMPV-Public` @ `9768748`，CI Run `45987364769`，耗时 `6m31s`）iOS 模拟器 `GlassMPVTests` 37/37 通过（`Executed 37 tests, with 0 failures (0 unexpected) in 39.443 (39.504) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-0.1.0-beta.4-b25-unsigned.ipa`（`3,597,766` bytes，`CFBundleIdentifier=com.glassmpv.player`，`CFBundleShortVersionString=0.1.0`，`CFBundleVersion=25`，含 `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.34s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 `GlassMPVTests 37/37` 与 Release Beta IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-0.1.0-beta.4-b25-unsigned.ipa`（`3,597,766` bytes）。
  - 最新实机定因日志：`GlassMPV-Log-20261127-184353.txt`（已彻底定位并修复在线高刷补帧降帧/丢帧问题）。
- **待办清单**：
  - [x] 完成 `v0.1.0-beta.4 (Build 25)` 在线高刷补帧修复、原生字幕系统与 Infuse 风格观看记录（CI Run `45987364769`，37/37 PASS，`6m31s`）。
  - [x] 下载并校验 `dist/GlassMPV-0.1.0-beta.4-b25-unsigned.ipa`（`3,597,766` bytes）。
  - [ ] 用户安装 `v0.1.0-beta.4-b25` 真机实测：验证夸克在线 `60/96/120fps` 补帧稳帧表现、内嵌/外挂字幕与首页「继续观看」断点续播体验。
