# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `3d8d6ac` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `0d6e384` | 最新交付 IPA `dist/GlassMPV-0.1.0-beta.3-b22-unsigned.ipa`）
- **当前阶段**：`已完成 v0.1.0-beta.3 (Build 22)：针对 172520 实机日志定位的夸克有声黑屏（Decoder: hev1, pres=0, 0×0），在 127.0.0.1 代理实现 ISO BMFF 流式 hev1→hvc1 在线重封装、修复 AVPlayerItemVideoOutput 像素格式与时序回退并上线 3.5s 黑屏看门狗自动切流，同步 AppReleaseInfo.releaseTag；CI Run 45975933134 全绿（34/34），IPA 已校验并投递微信「文件传输助手」`
- **最后活跃时间**：`2026-11-27 17:52:00` | **最近安全快照**：`0d6e384`（CI Run `45975933134` 绿灯出包，`3d8d6ac` 为私有主线代码与单测同步点）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 v0.1.0-beta.3 (Build 22)：流式 MP4 hev1→hvc1 重封装 + AVPlayerItemVideoOutput 修复 + 3.5s 黑屏自动切流，CI Run 45975933134 全绿 34/34 并已投递微信「文件传输助手」；等待用户实机验收夸克直链有声黑屏彻底解决及 120fps 展开控制栏表现`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
    - **夸克原画有声黑屏根治**：`172520` 日志证实登录、目录、直链及 127.0.0.1 代理全通，但两部夸克 MP4 均因 `hev1` 标签导致 `AVPlayer` 拒解视频轨（`0×0, pres=0`）。现通过 `LocalHTTPStreamProxy.patchHEV1ToHVC1` + `MP4HEV1StreamPatcher`（256B 滑动窗口严格校验 `VisualSampleEntry` 与 `hvcC`）无损流式改写为 `hvc1`，并显式配置 `AVPlayerItemVideoOutput` 为 `420v`、移除 `suppressesPlayerRendering`、回退 `player.currentTime()` 及上线 `3.5s` 自动切换夸克 HLS 看门狗。
    - **版本与门禁防漂移**：`VERSION` 与 `AppReleaseInfo.releaseTag` 均更新为 `0.1.0-beta.3`，并在 `tests/test_project_integrity.py` 增加两者一致断言。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV v0.1.0-beta.3`（公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `0d6e384`，CI Run `45975933134`，耗时 `8m28s`）iOS 模拟器 `GlassMPVTests` 34/34 通过（`Executed 34 tests, with 0 failures (0 unexpected) in 41.181 (41.418) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-0.1.0-beta.3-b22-unsigned.ipa`（`3,323,005` bytes，纯原生系统框架 + `Assets.car`，0 个 `.glsl` 着色器，已启用 `NSAppTransportSecurity`、`NSPhotoLibraryAddUsageDescription` 与 `LSApplicationQueriesSchemes`）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.74s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 `GlassMPVTests 34/34` 与 Release Beta IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-0.1.0-beta.3-b22-unsigned.ipa`（`3,323,005` bytes；`Info.plist` 校验 `CFBundleIdentifier=com.glassmpv.player`、`CFBundleShortVersionString=0.1.0`、`CFBundleVersion=22`，含 `Assets.car`，0 个 `.glsl` 着色器，`NSAllowsArbitraryLoads=true`、`NSPhotoLibraryAddUsageDescription`、`LSApplicationQueriesSchemes=[quark, weixin]`）。
  - 最新实机闭环日志：`GlassMPV-Log-20261127-172520.txt`（`v0.1.0-beta.1 Build 20` 标题显示问题由旧 `AppReleaseInfo.releaseTag` 硬编码导致并已修复；日志证实夸克直链代理全程无 403 且音频正常推进，唯 `Decoder: hev1` 导致 `AVPlayer` 拒解视频画面，已在 `beta.3` 通过代理流式改写 `hvc1` + 输出管线重整解决）。
  - **已定因根因与本轮已核验架构约束**：
    1. **流式 `hev1 → hvc1` 代理重写**：`LocalHTTPStreamProxy.patchHEV1ToHVC1` 必须严格校验 ISO BMFF `VisualSampleEntry` 全部结构位（含 `boxSize`、`reserved[6]`、`depth=0x0018`、`pre_defined=0xFFFF` 与 `hvcC`）并通过 `MP4HEV1StreamPatcher` 256B 滑动重叠窗口处理分块边界；`patchHEV1ToHVC1` 基于 `data.startIndex` 索引以兼容切片 `Data`。
    2. **云端 `AVPlayerItemVideoOutput` 约定**：不挂载 `AVPlayerLayer` 时禁止设置 `suppressesPlayerRendering = true`，必须显式声明 `420v` 像素格式并在 `itemTime(forHostTime:)` 无效时回退 `player.currentTime()`。
    3. **Swift 6 与门禁红线**：`RemoteStreamOpticalFlowWorker` 后台队列使用 `.high` 替代已弃用 `.userInteractive`；单测中切片 `Data` 调用 `.subdata(in:)` 前须用 `Data(...)` 归一化起始下标；`VERSION` 与 `AppReleaseInfo.releaseTag` 受 `pytest` 强一致门禁约束。
- **待办清单**：
  - [x] 完成 `v0.1.0-beta.3 (Build 22)` 夸克云端 `hev1→hvc1` 代理重封装、视频输出管线修复与自动切流上线（CI Run `45975933134`，34/34 PASS，`8m28s`）。
  - [x] 下载校验 `dist/GlassMPV-0.1.0-beta.3-b22-unsigned.ipa`（`3,323,005` bytes）并投递微信「文件传输助手」。
  - [ ] 用户真机实测 `v0.1.0-beta.3`：验证夸克原画直链与云端转码流正常出画 + ANE 补帧/超分表现，及展开控制栏 120fps 稳帧效果。
