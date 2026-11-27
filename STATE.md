# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `017fffa` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `017fffa` | 最新交付 IPA `dist/GlassMPV-0.1.0-beta.10-b35-unsigned.ipa`）
- **当前阶段**：`已完成 v0.1.0-beta.10 (Build 35)：根治真 4K 开 120fps 模糊、28ms 误降档至 60fps、缓冲恢复跌 2.0fps 丢帧与 5.86GB 每 9s 卡死 4~6s；CI Run 46031263382 全绿 45/45（9m53s），IPA 已校验并投递微信「文件传输助手」`
- **最后活跃时间**：`2026-11-28 00:21:00` | **最近安全快照**：`017fffa`（CI Run `46031263382` 绿灯出包）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 v0.1.0-beta.10 (Build 35)：120fps 抬至 720p 起步+2560px 全屏 MetalFX+纹理恢复、修复冷却期被抹除导致误降档与时钟撕裂、LocalHTTPStreamProxy 新增 4 路 2MB 并发预读 + 32MB LRU 缓存；CI Run 46031263382 全绿 45/45 并已投递微信`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
    - **根治 120fps 模糊与连环误降档 (`v0.1.0-beta.10`)**：`RemoteOpticalFlowBudgetPlanner` 淘汰 480p 糊档并锁定 120fps 从 `1280×720` 起跑、最低 `960×540`（`60/96fps` `810p→720p→540p`）；解除降采样光流 `1600px` 封顶；`MetalVideoEnhancer` 为原画自动 MetalFX 提至 `1080p/1440p` 并接入 `opticalFlowDownsampleRestoreParameters()` 轻量细节还原；删除误抹除 30 对冷却期的 `budgetGuard.reset()`、引入 `isCatchUpOverload` 真实耗时门限、6 帧队列与 8 对预热。
    - **并发 2MB 分块预读代理与时钟稳定 (`v0.1.0-beta.10`)**：`LocalHTTPStreamProxy` 新增 `ProxyRouteChunkCache`（`2MB × 4` 并发预读 + `32MB` 固定片头 LRU 缓存）与 `ParallelChunkedStreamRelay` 拉取直传，修复 `cancelAll()` 挂起态 `task.cancel()` 连接池锁死并抬高 `preferredForwardBufferDuration = 20s`；`handleRemoteDisplayTick` 冻结等待缓冲时钟并一次跳过突发旧帧。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV v0.1.0-beta.10`（`mistriver-lab/GlassMPV-Public` @ `017fffa`，CI Run `46031263382`，总耗时 `9m53s`）iOS 模拟器 `GlassMPVTests` 45/45 通过（`Executed 45 tests, with 0 failures (0 unexpected) in 31.236 (32.592) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-0.1.0-beta.10-b35-unsigned.ipa`（`3,901,772` bytes，`CFBundleIdentifier=com.glassmpv.player`，`CFBundleShortVersionString=0.1.0`，`CFBundleVersion=35`，含 `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.38s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 `GlassMPVTests 45/45` 与 Release Beta IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-0.1.0-beta.10-b35-unsigned.ipa`（`3,901,772` bytes）。
  - 最新实机定因日志：`GlassMPV-Log-20261127-220859.txt`。
- **待办清单**：
  - [x] 完成 `v0.1.0-beta.10 (Build 35)` 解决 120fps 模糊（720p 起步 + 2560px MetalFX + 无光晕还原）、误降档/缓冲跌 2fps、5.86GB 四路 2MB 并发预读缓存代理（CI Run `46031263382`，45/45 PASS，`9m53s`）。
  - [x] 下载校验 `dist/GlassMPV-0.1.0-beta.10-b35-unsigned.ipa`（`3,901,772` bytes）并发送至微信「文件传输助手」。
  - [ ] 用户安装 `v0.1.0-beta.10-b35` 真机实测：播放 `3840×2160` 5.86GB 夸克原画直链验证 120fps 清晰度、防误降档与长程加载无卡顿；后续视需要进入阶段 B（TMDB 刮削海报墙与剧集详情页）。
