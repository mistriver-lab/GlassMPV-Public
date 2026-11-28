# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `29d0917` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `29d0917` | 最新交付 IPA `dist/GlassMPV-0.1.0-beta.13-b44-unsigned.ipa`）
- **当前阶段**：`已完成 v0.1.0-beta.13 (Build 44)：原生 4K 120fps Flow-Warp v2 —— 60/96/120fps 全程保留真 3840×2160 原分辨率输出，接入 FlowVectorCalibrator 运行时 SAD 向量符号/单位自校准、高速 32BGRA/420v 输入与 960×540 单次光流、Metal 5-tap 联合光度边缘吸附着色器及 14 帧紧凑 4K 硬解队列；CI Run 46116118353 全绿 49/49（8m30s）`
- **最后活跃时间**：`2026-11-28 14:29:22` | **最近安全快照**：`29d0917`（CI Run `46116118353` 绿灯出包）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 v0.1.0-beta.13 (Build 44)：原生 4K 120fps Flow-Warp v2 上线（不降分辨率保持真 4K + 120fps 不跌档 + 运行时 SAD 自校准 + 5-tap 边缘吸附 + 14 帧防卡顿）；CI Run 46116118353 全绿 49/49`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
    - **原生 4K 120fps Flow-Warp v2 (`v0.1.0-beta.13`)**：`FlowVectorCalibrator` 在首个动态画面联立 `prev/curr` 亮度自校准精确 `(signX, signY)` 与坐标单位并优选 `420v/32BGRA` 避开 `64RGBAHalf` (`RGhA`)，将 ANE 光流场提升至 `960×540`；`MetalVideoEnhancer` 新增 5-tap 联合光度边缘吸附与真实 GPU 耗时遥测，`VTOpticalFlowEngine` 收紧 Flow-Warp 队列至 14 帧释放 4K 硬解 Surface 池。
    - **HLS / 误标 fMP4 切流与底栏换源、UI 防重叠闭环 (`v0.1.0-beta.12`)**：`QuarkDriveClient` 改用 `m3u8,fmp4` 优先并区分 `isHLS`；`LocalHTTPStreamProxy` 取消对无后缀 HLS 路由强拼 `.m3u8` 改用 `.stream` 并通过 `UpstreamStreamRelay` 嗅探 `Content-Type` / `#EXT` 前缀避免 `AVPlayer -1002`，切流立即 `cancelActiveChunkCaches()`；`LiquidGlassPlayerView` 底部内置画质流切换菜单 + `PlayerOverlayLayoutPolicy` 严格隔离加载/播控/续播提示。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV v0.1.0-beta.13`（`mistriver-lab/GlassMPV-Public` @ `29d0917`，CI Run `46116118353`，总耗时 `8m30s`）iOS 模拟器 `GlassMPVTests` 49/49 通过（`Executed 49 tests, with 0 failures (0 unexpected) in 30.194 (31.272) seconds`，含 `FlowVectorCalibrator` 真值合成符号/单位校准测试与 5-tap Metal Warp 渲染校验）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-0.1.0-beta.13-b44-unsigned.ipa`（`3,954,371` bytes，`CFBundleIdentifier=com.glassmpv.player`，`CFBundleShortVersionString=0.1.0`，`CFBundleVersion=44`，含 `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.56s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 macOS `GlassMPVTests 49/49` 与 Release Beta IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-0.1.0-beta.13-b44-unsigned.ipa`（`3,954,371` bytes）。
  - 最新实机定因日志：`GlassMPV-Log-20261128-140944.txt`。
- **待办清单**：
  - [x] 完成 `v0.1.0-beta.13 (Build 44)` 原生 4K 120fps Flow-Warp v2（`FlowVectorCalibrator` 运行时自校准 + `32BGRA`/`420v` + `960×540` + Metal 5-tap 边缘吸附 + 14 帧队列），CI Run `46116118353`（49/49 PASS，`8m30s`）。
  - [x] 下载校验 `dist/GlassMPV-0.1.0-beta.13-b44-unsigned.ipa`（`3,954,371` bytes）并发送至微信「文件传输助手」。
  - [ ] 用户安装 `v0.1.0-beta.13-b44` 真机实测：播放 `3840×2160` 夸克原画直链验证「4K原生光流变形 3840×2160」清晰度、120fps 满血稳帧与 `4K光流向量自校准锁定` 日志指标。
