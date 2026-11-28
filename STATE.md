# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `fc36368` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `fc36368` | 最新交付 IPA `dist/GlassMPV-0.1.0-beta.18-b60-unsigned.ipa`）
- **当前阶段**：`已完成 v0.1.0-beta.18 (Build 60)：4K/2K 2× 全线统一为零降采样原生 GPU 光流（消除 1920×1080 ANE 降画质 + 149 帧掉帧）、LocalHTTPStreamProxy 真流式 1MB 边下边传订阅 + 首包 65KB 后再触发 2 路前瞻 + Seek 剪除窗外僵尸连接、Seek 落地 1.5s 关键帧宽限窗消除双重清表；CI Run 46176976061 全绿 61/61（9m38s）`
- **最后活跃时间**：`2026-11-29 02:49:00` | **最近安全快照**：`fc36368`（CI Run `46176976061` 绿灯出包）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 v0.1.0-beta.18 (Build 60)：4K 2× 零降采样 GPU 光流 + 真流式分块直传代理 + Seek 关键帧宽限窗；CI Run 46176976061 全绿 61/61`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
    - **4K 2× 零降采样光流 + 真流式代理 + Seek 双重重置消除 (`v0.1.0-beta.18`)**：基于 `GlassMPV-Log-20261129-022714.txt` 定因，在 `RemoteOpticalFlowBudgetPlanner.shouldUseHybridFlowWarp` 中将 `>1920px` 的 `2×` 档位全线切换至零降采样原生 GPU 光流并加入高刷 Metal 保持直绘，彻底根除 `1920×1080 → MetalFX 2560×1440` 降画质与 `30.0ms` 延迟造成的 149 帧掉帧；将 `LocalHTTPStreamProxy` 重构为 `ChunkStreamSubscriber` + `streamChunk` 1MB 边下边传流式分块模型（移除 `bytes=0-1` 探测盲目预取、首包 65KB 再开 2 路前瞻、`pruneOutOfWindowTasks` 剪除窗外僵尸任务、10s 空闲超时），并将 `AVPlayerItem.preferredForwardBufferDuration` 调至 `15s`；为 `RemoteClockContinuityGuard` 增加 `postSeekKeyframeGraceUntilPTS` 1.5s 关键帧回退容忍窗口。
    - **中点光流泼溅消虚影 + 748MB 内存封顶 + 4K HDR10 与自动降级修复 (`v0.1.0-beta.17`)**：引入 3-Pass 中点 Z-Order 前向泼溅与方向性可见性 `(vis0, vis1)` 消除高刷边缘虚影；封顶 `1440×810` 画布、加密 `CVMetalTextureCacheFlush`、`load()` 保留自动降级回调并解锁 `8-bit 420v/420f` HDR10 补帧与 PQ 色调映射。
    - **快速运动提速 + 向后 Seek 恢复 + HUD 最优化 (`v0.1.0-beta.16`)**：精简 `displayFlowWarpYUVFragment` 采样、扩宽 `L0` 搜索半径至 `±4` 并收紧 `evaluateSceneCut`；引入 `RemoteClockContinuityGuard` 修复向后 Seek 锁死，并优化 HUD 原画与耗时显示。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV v0.1.0-beta.18`（`mistriver-lab/GlassMPV-Public` @ `fc36368`，CI Run `46176976061`，总耗时 `9m38s`）iOS 模拟器 `GlassMPVTests` 61/61 通过（`Executed 61 tests, with 0 failures (0 unexpected) in 33.155 (35.823) seconds`，新增 `testProgressiveChunkStreamingTTFBAndPostSeekKeyframeGrace` 真流式 16KB TTFB 首包 + Seek 关键帧宽限窗，并更新 `4K 2×` 走零降采样原生 GPU 光流回归用例）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-0.1.0-beta.18-b60-unsigned.ipa`（`4,001,867` bytes，`CFBundleIdentifier=com.glassmpv.player`，`CFBundleShortVersionString=0.1.0`，`CFBundleVersion=60`，含 `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.61s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 macOS `GlassMPVTests 61/61` 与 Release Beta IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-0.1.0-beta.18-b60-unsigned.ipa`（`4,001,867` bytes）。
  - 最新实机定因日志：`GlassMPV-Log-20261129-022714.txt`。
- **待办清单**：
  - [x] 完成 `v0.1.0-beta.18 (Build 60)` 4K 2× 零降采样 GPU 光流 + 真流式 1MB 边下边传代理 + Seek 落地 1.5s 关键帧宽限窗，CI Run `46176976061`（61/61 PASS，`9m38s`）。
  - [x] 下载校验 `dist/GlassMPV-0.1.0-beta.18-b60-unsigned.ipa`（`4,001,867` bytes）并准备投递至微信「文件传输助手」。
  - [ ] 用户安装 `v0.1.0-beta.18-b60` 真机实测：验证 4K `2×` 走原生画质且零掉帧、大文件 Seek 与播放缓冲流畅度，以及《环太平洋》自动降级至可播放流表现。
