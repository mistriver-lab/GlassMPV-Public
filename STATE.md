# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `720d17e` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `720d17e` | 最新交付 IPA `dist/GlassMPV-0.1.0-beta.16-b55-unsigned.ipa`）
- **当前阶段**：`已完成 v0.1.0-beta.16 (Build 55)：快速运动 4K GPU 光流提速 2.5×~3× + L0 搜索扩径与切镜防误触发 + 向后拖动进度条补帧失效根治 + 视频信息 HUD 最优化；CI Run 46168240273 全绿 57/57（11m51s）`
- **最后活跃时间**：`2026-11-29 01:15:00` | **最近安全快照**：`720d17e`（CI Run `46168240273` 绿灯出包）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 v0.1.0-beta.16 (Build 55)：快速运动光流提速与跟拍增强 + Seek 向后拖动时钟隔离与自愈 + 视频信息 HUD 最优化；CI Run 46168240273 全绿 57/57`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
    - **快速运动提速 + 向后 Seek 恢复 + HUD 最优化 (`v0.1.0-beta.16`)**：基于 `GlassMPV-Log-20261129-003610.txt` 定因，将 `displayFlowWarpYUVFragment` 均值耗时 `4.79ms` 的 39-tap 全像素采样精简为惰性 UV 采样、5-tap 静止直出与仅高误差边界候选，`MetalPyramidOpticalFlowEngine` 将 `L0` 搜索半径扩至 `±4`（±480px@4K）并收紧 `evaluateSceneCut`；引入 `RemoteClockContinuityGuard` 与 `audioPlayer.seek` 完成回调代数锁彻底解决 `2940s→1601s` 回拖后时钟锁死跌至 `25fps`；重命名 `原生4K GPU光流 (矢量256×144)` + 绿标 `原画直采` 并优化 `compactStatsHUD` 展示光流/渲染耗时、队列深度、内存 MB 与 `缓冲中` 自衰减。
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
> 🟢 **[PASS]** `GlassMPV v0.1.0-beta.16`（`mistriver-lab/GlassMPV-Public` @ `720d17e`，CI Run `46168240273`，总耗时 `11m51s`）iOS 模拟器 `GlassMPVTests` 57/57 通过（`Executed 57 tests, with 0 failures (0 unexpected) in 32.380 (33.861) seconds`，新增向后 Seek 时钟守卫与 120fps 恢复、+44px 快速横移 `L0` 追踪及非误判切镜、优化版视频信息 HUD 与停滞 FPS 衰减回归测试）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-0.1.0-beta.16-b55-unsigned.ipa`（`3,972,218` bytes，`CFBundleIdentifier=com.glassmpv.player`，`CFBundleShortVersionString=0.1.0`，`CFBundleVersion=55`，含 `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.43s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 macOS `GlassMPVTests 57/57` 与 Release Beta IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-0.1.0-beta.16-b55-unsigned.ipa`（`3,972,218` bytes）。
  - 最新实机定因日志：`GlassMPV-Log-20261129-003610.txt`。
- **待办清单**：
  - [x] 完成 `v0.1.0-beta.16 (Build 55)` 快速运动 4K 光流提速与跟踪增强 + 向后拖动进度条补帧失效根治 + 视频信息 HUD 最优化，CI Run `46168240273`（57/57 PASS，`11m51s`）。
  - [x] 下载校验 `dist/GlassMPV-0.1.0-beta.16-b55-unsigned.ipa`（`3,972,218` bytes）并发送至微信「文件传输助手」。
  - [ ] 用户安装 `v0.1.0-beta.16-b55` 真机实测：验证高速运动镜头波动改善、向后拖动进度条 120fps 立即恢复、以及新版 HUD 原画/耗时显示体验。
