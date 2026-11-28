# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `75290db` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `75290db` | 最新交付 IPA `dist/GlassMPV-0.1.0-beta.17-b58-unsigned.ipa`）
- **当前阶段**：`已完成 v0.1.0-beta.17 (Build 58)：中点 Z-Order 前向泼溅光流 + 真方向性可见性消虚影、1440×810 切流 748MB 内存峰值根治、4K HDR10 (SMPTE_ST_2084_PQ/420v) 补帧启用与 PQ→SDR709 色调映射、超大 4K -1001 自动降级回调保活与夸克 4K HLS 400 重试；CI Run 46174384254 全绿 60/60（6m59s）`
- **最后活跃时间**：`2026-11-29 02:18:00` | **最近安全快照**：`75290db`（CI Run `46174384254` 绿灯出包）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 v0.1.0-beta.17 (Build 58)：Midpoint Z-Order Splatting 消高刷边缘虚影 + 切流 748MB 内存治理 + 4K HDR10 补帧修复 + 自动降级恢复；CI Run 46174384254 全绿 60/60`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
    - **中点光流泼溅消虚影 + 748MB 内存封顶 + 4K HDR10 与自动降级修复 (`v0.1.0-beta.17`)**：基于 `GlassMPV-Log-20261129-013953.txt` 与 `015344.txt` 定因，在 `MetalVideoEnhancer` 引入 3-Pass 中点 Z-Order 前向泼溅与方向性可见性 `(vis0, vis1)` 消除 `60/96/120fps` 运动边缘虚影；将 `CVMetalTextureCacheFlush` 加密至 `4 对/12 帧`、`recommendedFlowWarpMetalMaxLongSide` 对 `1440×810` 原画封顶 `1440px`、`LocalHTTPStreamProxy` 切流立即取消在途连接并限制 LRU `10×2MB`；新增 `canUseMetalDirectPath` + `isPQTransferBuffer` 解锁 `8-bit 420v/420f` HDR10 补帧与着色器 PQ→SDR 709 色调映射；修复 `OpticalFlowPlayerController.load()` 误清空 `onRemoteStreamFailed` 回调与双重 seek 时钟重置，并强化 HLS `.ts` HTTP 400 鉴权重试及 5 并发 20s 预取。
    - **快速运动提速 + 向后 Seek 恢复 + HUD 最优化 (`v0.1.0-beta.16`)**：基于 `GlassMPV-Log-20261129-003610.txt` 定因，精简 `displayFlowWarpYUVFragment` 采样、扩宽 `L0` 搜索半径至 `±4` 并收紧 `evaluateSceneCut`；引入 `RemoteClockContinuityGuard` 修复向后 Seek 锁死，并优化 HUD 原画与耗时显示。
    - **直通 60Hz 稳帧 + GPU 光流 15× 提速 + 防人物虚影 (`v0.1.0-beta.15`)**：`OpticalFlowResolutionPlanner` 在关闭补帧直通时锁定 `60Hz` 并保持连续 `UIUpdateLink` 与 `samplePTS` 去重，根除 ProMotion LTPO 节流造成的 13–16fps 掉帧；`MetalPyramidOpticalFlowEngine` 预计算 `RGBA16F` `(Y, Gx, Gy)` 特征金字塔（2 次 FP16 采样替代 10 次 FP32），测试耗时缩短 2.6×；`displayFlowWarpYUVFragment` 新增 `nearest` 边缘离散矢量锐选、静态零矢量候选与严格单帧遮挡硬切换。
    - **零降采样 Metal GPU 金字塔光流 + 切画质闪烁/泄漏根治 (`v0.1.0-beta.14`)**：强制 `sourceNormPool` 标准化并加入 `1280×720` 候选、2 次异常熔断与 `RemoteDisplayCadenceGuard` 单调 PTS 守卫，高刷队列上限恢复至 24/30/36 帧。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV v0.1.0-beta.17`（`mistriver-lab/GlassMPV-Public` @ `75290db`，CI Run `46174384254`，总耗时 `6m59s`）iOS 模拟器 `GlassMPVTests` 60/60 通过（`Executed 60 tests, with 0 failures (0 unexpected) in 23.800 (28.831) seconds`，新增中点 Z-Order 前向泼溅全相位消虚影、1440×810 画布封顶/代理 10 块内存门禁与 HLS HTTP 400 重试、`8-bit 420v/420f` HDR10 Metal 通道与 `load()` 降级回调保活回归测试）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-0.1.0-beta.17-b58-unsigned.ipa`（`3,986,634` bytes，`CFBundleIdentifier=com.glassmpv.player`，`CFBundleShortVersionString=0.1.0`，`CFBundleVersion=58`，含 `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.54s` / `0.43s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 macOS `GlassMPVTests 60/60` 与 Release Beta IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-0.1.0-beta.17-b58-unsigned.ipa`（`3,986,634` bytes）。
  - 最新实机定因日志：`GlassMPV-Log-20261129-013953.txt`、`GlassMPV-Log-20261129-015344.txt`。
- **待办清单**：
  - [x] 完成 `v0.1.0-beta.17 (Build 58)` 中点光流泼溅消高刷边缘虚影 + 切流 748MB 内存峰值治理 + 4K HDR10 补帧与 PQ 色调映射 + `-1001` 自动降级回调保活与 HLS 400 恢复，CI Run `46174384254`（60/60 PASS，`6m59s`）。
  - [x] 下载校验 `dist/GlassMPV-0.1.0-beta.17-b58-unsigned.ipa`（`3,986,634` bytes）并准备投递至微信「文件传输助手」。
  - [ ] 用户安装 `v0.1.0-beta.17-b58` 真机实测：验证 120fps 人物边缘无虚影、切换 `1440×810` 内存稳定、`Iron.Man.2008` 4K HDR10 `60/96/120fps` 补帧生效、以及超大 4K 卡顿超时自动降级与夸克 4K HLS 重试效果。
