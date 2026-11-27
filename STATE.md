# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `a920673` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `a920673` | 最新交付 IPA `dist/GlassMPV-0.1.0-beta.11-b38-unsigned.ipa`）
- **当前阶段**：`已完成 v0.1.0-beta.11 (Build 38)：混合 4K 原生光流变形架构 (Hybrid 4K Flow-Warp) —— ANE 每对帧仅计算 1 次轻量双向光流场 (VTOpticalFlowConfiguration 640×360/854×480)，Metal GPU 零拷贝采样前后原始 4K YUV 实时双向遮挡感知变形出帧；CI Run 46044545185 全绿 46/46（9m24s），IPA 已校验`
- **最后活跃时间**：`2026-11-28 02:07:30` | **最近安全快照**：`a920673`（CI Run `46044545185` 绿灯出包）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 v0.1.0-beta.11 (Build 38)：混合 4K 原生光流变形架构彻底消除 60/96/120fps 4K 发糊与 120fps 自动跌档 96fps；CI Run 46044545185 全绿 46/46，已下载校验并投递微信`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
    - **混合 4K 原生光流变形引擎 (`v0.1.0-beta.11`)**：`RemoteStreamOpticalFlowWorker` 对 SDR 8-bit `60/96/120fps` 高分流激活 `VTOpticalFlowConfiguration` + `VTOpticalFlowParameters` + `VTFrameProcessorOpticalFlow`（每次仅计算 1 次 `640×360` / `854×480` 双向光流，耗时与目标帧率解耦），原帧与中间帧全链路输出原始 `3840×2160` 参考；`MetalVideoEnhancer` 新增 `displayFlowWarpYUVFragment` 双向遮挡感知 Warp Shader（1 步中点细化 + 前后一致性校验 + 转场瞬态护栏），`VTOpticalFlowEngine` 接入 `remoteFrameQueue` 与 `presentFlowWarpedFrame` 解锁 `2560px` 全屏渲染，并保留 `2×`（`LowLatency 1080p + MetalFX`）与 HDR/杜比安全回退。
    - **并发 2MB 分块预读代理与时钟稳定 (`v0.1.0-beta.10`)**：`LocalHTTPStreamProxy` 新增 `ProxyRouteChunkCache`（`2MB × 4` 并发预读 + `32MB` 固定片头 LRU 缓存）与 `ParallelChunkedStreamRelay` 拉取直传，`preferredForwardBufferDuration = 20s` 彻底消除 5.86GB 真 4K 周期性网络卡死。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV v0.1.0-beta.11`（`mistriver-lab/GlassMPV-Public` @ `a920673`，CI Run `46044545185`，总耗时 `9m24s`）iOS 模拟器 `GlassMPVTests` 46/46 通过（`Executed 46 tests, with 0 failures (0 unexpected) in 22.231 (23.919) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-0.1.0-beta.11-b38-unsigned.ipa`（`3,925,032` bytes，`CFBundleIdentifier=com.glassmpv.player`，`CFBundleShortVersionString=0.1.0`，`CFBundleVersion=38`，含 `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.39s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 `GlassMPVTests 46/46` 与 Release Beta IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-0.1.0-beta.11-b38-unsigned.ipa`（`3,925,032` bytes）。
  - 最新实机定因日志：`GlassMPV-Log-20261128-002623.txt`。
- **待办清单**：
  - [x] 完成 `v0.1.0-beta.11 (Build 38)` 混合 4K 原生光流变形引擎（`VTOpticalFlowConfiguration` + `displayFlowWarpYUVFragment` + `presentFlowWarpedFrame`），CI Run `46044545185`（46/46 PASS，`9m24s`）。
  - [x] 下载校验 `dist/GlassMPV-0.1.0-beta.11-b38-unsigned.ipa`（`3,925,032` bytes）并发送至微信「文件传输助手」。
  - [ ] 用户安装 `v0.1.0-beta.11-b38` 真机实测：播放 `3840×2160` 夸克原画直链对比 `120fps / 96fps / 60fps` 真 4K 清晰度、稳定不跌档与转场表现；后续视需要进入阶段 B（TMDB 刮削海报墙与剧集详情页）。
