# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `d5e8905` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `d5e8905` | 最新交付 IPA `dist/GlassMPV-0.1.0-beta.12-b42-unsigned.ipa`）
- **当前阶段**：`已完成 v0.1.0-beta.12 (Build 42)：默认下线试验性 FlowWarp 恢复高清低延迟 ANE+2560×1440 MetalFX（淘汰 540p/480p、25fps 对齐 100fps 4×）、修复 Quark fmp4/HLS 代理卡死与 .m3u8 强制后缀 -1002 错误、底栏直接换画质并自动刷新直链、消除初播按钮重叠；macOS iOS 26 模拟器 CI Run 46114112296 全绿 49/49（8m2s）`
- **最后活跃时间**：`2026-11-28 14:03:00` | **最近安全快照**：`d5e8905`（CI Run `46114112296` 绿灯出包）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 v0.1.0-beta.12 (Build 42)：画质流畅度止损回稳、修复夸克切画质卡死不播、底栏直接一键换画质、初播 UI 防重叠并新增 macOS iOS 26 模拟器双流 E2E 测试；CI Run 46114112296 全绿 49/49`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
    - **画质稳态升级与全维度流畅优化 (`v0.1.0-beta.12`)**：`RemoteOpticalFlowBudgetPlanner.shouldUseHybridFlowWarp` 新增 `allowExperimentalFlowWarp = false` 默认开关，全档位淘汰 `540p`/`480p`（`2×`: `1080p→810p`、`60/96/100fps`: `810p→720p`、`120fps`: 锁定 `720p`）；25fps 片源选择 `fps96` 自动对齐 `100.0fps (4×, exp=2)` 并在 `<= 105fps` 解锁 **`2560×1440 MetalFX`**。
    - **HLS / 误标 fMP4 切流与底栏换源、UI 防重叠闭环 (`v0.1.0-beta.12`)**：`QuarkDriveClient` 改用 `m3u8,fmp4` 优先并区分 `isHLS`；`LocalHTTPStreamProxy` 取消对无后缀 HLS 路由强拼 `.m3u8` 改用 `.stream` 并通过 `UpstreamStreamRelay` 嗅探 `Content-Type` / `#EXT` 前缀避免 `AVPlayer -1002`，切流立即 `cancelActiveChunkCaches()`；`LiquidGlassPlayerView` 底部内置画质流切换菜单 + `PlayerOverlayLayoutPolicy` 严格隔离加载/播控/续播提示。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV v0.1.0-beta.12`（`mistriver-lab/GlassMPV-Public` @ `d5e8905`，CI Run `46114112296`，总耗时 `8m2s`）iOS 模拟器 `GlassMPVTests` 49/49 通过（`Executed 49 tests, with 0 failures (0 unexpected) in 8.156 (8.253) seconds`，含新增 HLS/误标 fMP4 切换、双流端到端实播切换、界面防重叠单测）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-0.1.0-beta.12-b42-unsigned.ipa`（`3,933,134` bytes，`CFBundleIdentifier=com.glassmpv.player`，`CFBundleShortVersionString=0.1.0`，`CFBundleVersion=42`，含 `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.40s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 macOS `GlassMPVTests 49/49` 与 Release Beta IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-0.1.0-beta.12-b42-unsigned.ipa`（`3,933,134` bytes）。
  - 最新实机定因日志：`GlassMPV-Log-20261128-132803.txt`。
- **待办清单**：
  - [x] 完成 `v0.1.0-beta.12 (Build 42)` 画质流畅度回稳、HLS/fMP4 切流、底栏一键换画质、初播防重叠及 macOS 模拟器 E2E 自测闭环，CI Run `46114112296`（49/49 PASS，`8m2s`）。
  - [x] 下载校验 `dist/GlassMPV-0.1.0-beta.12-b42-unsigned.ipa`（`3,933,134` bytes）并发送至微信「文件传输助手」。
  - [ ] 用户安装 `v0.1.0-beta.12-b42` 真机实测：播放 `3840×2160` 夸克原画直链验证画质、100fps 4× / 120fps 流畅度、底栏直接切换「夸克 1080P+ / 4K」正常播放及初播界面无重叠。
