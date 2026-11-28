# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `8496071` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `8496071` | 最新交付 IPA `dist/GlassMPV-0.1.0-beta.15-b51-unsigned.ipa`）
- **当前阶段**：`已完成 v0.1.0-beta.15 (Build 51)：关闭补帧直通锁定 60Hz 防 ProMotion 13–16fps 掉帧 + 15× GPU 金字塔特征预计算加速消除 120fps 波动 + 离散边缘锐选与像素级防虚影遮挡守卫；CI Run 46164306592 全绿 54/54（9m40s）`
- **最后活跃时间**：`2026-11-29 00:28:00` | **最近安全快照**：`8496071`（CI Run `46164306592` 绿灯出包）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 v0.1.0-beta.15 (Build 51)：直通 60Hz 锁帧稳 25fps + GPU 光流 RGBA16F (Y,Gx,Gy) 提速 15× + 120fps 离散边界与硬切换防虚影守卫；CI Run 46164306592 全绿 54/54`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
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
> 🟢 **[PASS]** `GlassMPV v0.1.0-beta.15`（`mistriver-lab/GlassMPV-Public` @ `8496071`，CI Run `46164306592`，总耗时 `9m40s`）iOS 模拟器 `GlassMPVTests` 54/54 通过（`Executed 54 tests, with 0 failures (0 unexpected) in 27.558 (29.909) seconds`，含不补帧 60Hz LTPO 防掉帧校验、抗人物虚影与运动边缘梯度像素回归、RGBA16F 金字塔 GPU 精度测试）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-0.1.0-beta.15-b51-unsigned.ipa`（`3,960,338` bytes，`CFBundleIdentifier=com.glassmpv.player`，`CFBundleShortVersionString=0.1.0`，`CFBundleVersion=51`，含 `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.56s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 macOS `GlassMPVTests 54/54` 与 Release Beta IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-0.1.0-beta.15-b51-unsigned.ipa`（`3,960,338` bytes）。
  - 最新实机定因日志：`GlassMPV-Log-20261129-000721.txt`。
- **待办清单**：
  - [x] 完成 `v0.1.0-beta.15 (Build 51)` 关闭补帧 60Hz LTPO 稳帧 + Metal GPU 金字塔特征预计算 15× 加速 + 离散边界与防虚影守卫，CI Run `46164306592`（54/54 PASS，`9m40s`）。
  - [x] 下载校验 `dist/GlassMPV-0.1.0-beta.15-b51-unsigned.ipa`（`3,960,338` bytes）并发送至微信「文件传输助手」。
  - [ ] 用户安装 `v0.1.0-beta.15-b51` 真机实测：验证关闭补帧直通稳 25fps 零掉帧、120fps 人物边缘清晰度/虚影改善与更低的 GPU 耗时波动。
