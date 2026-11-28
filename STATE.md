# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `b2bdc74` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `b2bdc74` | 最新交付 IPA `dist/GlassMPV-0.1.0-beta.14-b49-unsigned.ipa`）
- **当前阶段**：`已完成 v0.1.0-beta.14 (Build 49)：纯 Metal 4 级 GPU 金字塔光流引擎 + 强制 sourceNormPool 标准化与 -19740 熔断防泄漏 + 单调送显守卫 RemoteDisplayCadenceGuard + 动态高刷队列扩容（24/30/36 帧）；CI Run 46161609576 全绿 52/52（9m51s）`
- **最后活跃时间**：`2026-11-28 23:58:00` | **最近安全快照**：`b2bdc74`（CI Run `46161609576` 绿灯出包）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 v0.1.0-beta.14 (Build 49)：60/96/120fps 改由 4 级 Metal GPU 金字塔光流在原分辨率 YUV 上直算直绘（零降采样糊化、静止区域零模糊），并彻底修复切画质 1440×810 触发 -19740 会话泄漏与闪烁跳帧；CI Run 46161609576 全绿 52/52`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
    - **零降采样 Metal GPU 金字塔光流 + 切画质闪烁/泄漏根治 (`v0.1.0-beta.14`)**：下线高耗超预算的 `VTOpticalFlowConfiguration`（RGhA 32.5–45.9ms）与静态背景符号错锁，改由 4 级纯 Metal GPU 金字塔光流 (`MetalPyramidOpticalFlowEngine`) 计算归一化双向 UV 位移并在 `displayFlowWarpYUVFragment` 零降采样直绘；强制 `sourceNormPool` 标准化并加入 `1280×720` 候选、2 次异常熔断与 `RemoteDisplayCadenceGuard` 单调 PTS 守卫，高刷队列上限由 14 恢复至 24/30/36 帧。
    - **原生 4K 120fps Flow-Warp v2 (`v0.1.0-beta.13`)**：新增 5-tap 联合光度边缘吸附着色器、FP16 编解码自校准工具及真实 GPU 耗时遥测。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV v0.1.0-beta.14`（`mistriver-lab/GlassMPV-Public` @ `b2bdc74`，CI Run `46161609576`，总耗时 `9m51s`）iOS 模拟器 `GlassMPVTests` 52/52 通过（`Executed 52 tests, with 0 failures (0 unexpected) in 34.735 (34.857) seconds`，含 Metal 金字塔真 GPU 运动追踪与像素 MAE 清晰度校验、单调时钟无闪烁队列守卫、切流标准化测试）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-0.1.0-beta.14-b49-unsigned.ipa`（`3,959,184` bytes，`CFBundleIdentifier=com.glassmpv.player`，`CFBundleShortVersionString=0.1.0`，`CFBundleVersion=49`，含 `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.41s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 macOS `GlassMPVTests 52/52` 与 Release Beta IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-0.1.0-beta.14-b49-unsigned.ipa`（`3,959,184` bytes）。
  - 最新实机定因日志：`GlassMPV-Log-20261128-230804.txt`。
- **待办清单**：
  - [x] 完成 `v0.1.0-beta.14 (Build 49)` Metal GPU 金字塔光流引擎 + `1440×810` `-19740` 池标准化与熔断 + `RemoteDisplayCadenceGuard` 单调送显守卫 + `24/30/36` 动态高刷队列扩容，CI Run `46161609576`（52/52 PASS，`9m51s`）。
  - [x] 下载校验 `dist/GlassMPV-0.1.0-beta.14-b49-unsigned.ipa`（`3,959,184` bytes）并发送至微信「文件传输助手」。
  - [ ] 用户安装 `v0.1.0-beta.14-b49` 真机实测：播放夸克原画直链体验 `60/96/120fps` Metal GPU 原生光流效果，并切换 `夸克 1080P+` 等画质验证闪烁卡顿消除与内存稳态。
