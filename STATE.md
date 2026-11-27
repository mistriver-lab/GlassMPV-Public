# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `0fba25d` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `0fba25d` | 最新交付 IPA `dist/GlassMPV-0.1.0-beta.6-b28-unsigned.ipa`）
- **当前阶段**：`已完成 v0.1.0-beta.6 (Build 28)：定位并根治 195958 日志中夸克原画直链 -1001 请求超时与卡死（LocalHTTPStreamProxy 共享持久连接池 + 12s 快速失败返回 HTTP 504/502 + 代理日志、QuarkDriveClient 刷新 Cookie 透传与清洁媒体请求头、OpticalFlowPlayerController 主流失败自动切换 夸克 4K/2K/1080P HLS 并保留进度、异常弹窗一键切流与刷新直链）；CI Run 45996256298 全绿 40/40，IPA 已校验并投递微信「文件传输助手」`
- **最后活跃时间**：`2026-11-27 20:20:30` | **最近安全快照**：`0fba25d`（CI Run `45996256298` 绿灯出包）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 v0.1.0-beta.6 (Build 28)：夸克原画直链超时 (-1001) 自动降级 HLS 与持久连接池修复，CI Run 45996256298 全绿 40/40 并已投递微信「文件传输助手」；等待用户实机验收`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
    - **夸克直链超时根治与自动降级 HLS (`LocalHTTPStreamProxy` + `MediaSourceClients` + `VTOpticalFlowEngine` + `LiquidGlassPlayerView`)**：`195958` 实机日志证实 `beta.5` 未改代理层，失败源于 `download_url` 建连/首包 >18s 触发 `-1001`、逐 Range 新建 `URLSession` 无持久连接复用且失败时未切回 HLS。现通过共享持久连接池 `ProxyUpstreamSessionPool`（12s 快速失败返回 504/502 与首包耗时日志）、透传刷新 `__puus` Cookie 与清洁媒体头、主流失败秒切 HLS 备选流并保留续播起点、以及异常弹窗提供「切换清晰度 / 刷新直链重试」彻底解决。
    - **原画关闭增强也能锁满 120.0 fps & Infuse 8 影院重构 (`v0.1.0-beta.5`)**：`allowPassthrough` 零滤镜直绘、`PlayerGestureOverlay` 5 路原生手势 + 防误触锁、首页 C 位卡片与 2 列网格、选集抽屉与多音轨切换。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV v0.1.0-beta.6`（`mistriver-lab/GlassMPV-Public` @ `0fba25d`，CI Run `45996256298`，耗时 `10m23s`）iOS 模拟器 `GlassMPVTests` 40/40 通过（`Executed 40 tests, with 0 failures (0 unexpected) in 14.129 (15.269) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-0.1.0-beta.6-b28-unsigned.ipa`（`3,751,772` bytes，`CFBundleIdentifier=com.glassmpv.player`，`CFBundleShortVersionString=0.1.0`，`CFBundleVersion=28`，含 `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.49s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 `GlassMPVTests 40/40` 与 Release Beta IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-0.1.0-beta.6-b28-unsigned.ipa`（`3,751,772` bytes）。
  - 最新实机定因日志：`GlassMPV-Log-20261127-195958.txt`。
- **待办清单**：
  - [x] 完成 `v0.1.0-beta.6 (Build 28)` 夸克原画直链代理连接池、`__puus` 透传与主流超时自动切换 HLS（CI Run `45996256298`，40/40 PASS，`10m23s`）。
  - [x] 下载校验 `dist/GlassMPV-0.1.0-beta.6-b28-unsigned.ipa`（`3,751,772` bytes）并发送至微信「文件传输助手」。
  - [ ] 用户安装 `v0.1.0-beta.6-b28` 真机实测：验证夸克原画直链流畅起播 / 超时秒级自动切 HLS 连贯续播，以及原画 120fps 锁满与新影院交互体验。
