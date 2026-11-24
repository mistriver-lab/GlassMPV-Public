# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（iOS App Target: `GlassMPV` `v1.1.0` 开发中 | GitHub: `mistriver-lab/GlassMPV`）
- **当前阶段**：`v1.1.0 MPVUI 开源底座重构进行中（本地工作区待完成收尾测试并提交 CI）`
- **最后活跃时间**：`2026-11-24 11:19:00` | **最近安全快照**：`基线 823422d`（CI Run `45314254206`）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`GlassMPV v1.1.0 切换 MPVUI (0.11.0) 开源底座重构收尾与 CI 验证`
- 本轮已完成工作区文件改动（尚未提交推送）：
  * [x] [project.yml](project.yml)、[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)、[VERSION](VERSION)、[CHANGELOG.md](CHANGELOG.md)、[Sources/Models/AppReleaseInfo.swift](Sources/Models/AppReleaseInfo.swift)：切换依赖至 `LePips/MPVUI (0.11.0)` 并升版 `v1.1.0`
  * [x] [Sources/Engine/MPVPlayerCore.swift](Sources/Engine/MPVPlayerCore.swift)：基于 `MPVPlayer` / `MPVVideoPlayer` (`videoOutput: .metal`) 重写播放内核与诊断流
  * [x] [Sources/Engine/LocalMediaImporter.swift](Sources/Engine/LocalMediaImporter.swift)：新增 `MovieFileTransferable` 与异步 `NSFileCoordinator` 沙盒导入器
  * [x] [Sources/Engine/VTOpticalFlowEngine.swift](Sources/Engine/VTOpticalFlowEngine.swift)：修复 `kCMSampleAttachmentKey_DisplayImmediately`、`spatial2x` 尺寸一致与补帧异常遥测透出
  * [ ] [Sources/UI/LiquidGlassPlayerView.swift](Sources/UI/LiquidGlassPlayerView.swift)：已完成 `PlayerCoordinator` 逻辑改造，待补齐视图层 `PhotosPicker` 按钮、`onChange` 与 `DiagnosticLogSheet` 真机 5 项体检面板
  * [ ] 待更新 [tests/test_project_integrity.py](tests/test_project_integrity.py)、[tests/GlassMPVTests.swift](tests/GlassMPVTests.swift)、[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)，并在本地运行 `pytest tests/test_project_integrity.py -v` 后推送 `main` 触发 CI 验证

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟡 **[IN PROGRESS · PENDING VERIFY]** `v1.1.0` 本地代码重构半程接力中（尚余视图层与测试文件收尾，暂未运行 `pytest` 与推送 CI）
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟡 [PENDING] 上次通过基线为 `v1.0.2` (Run `45314254206`)；本轮 `v1.1.0` 收尾后需执行 `pytest tests/test_project_integrity.py -v` 并等待 CI `xcodebuild test` 全绿出包
- **待办事项**：
  1. 补全 [Sources/UI/LiquidGlassPlayerView.swift](Sources/UI/LiquidGlassPlayerView.swift) 视图层 `PhotosPicker` 入口、异步导入状态提示与 `DiagnosticLogSheet`「一键真机 5 项体检」UI；
  2. 更新 [tests/test_project_integrity.py](tests/test_project_integrity.py)、[tests/GlassMPVTests.swift](tests/GlassMPVTests.swift) 与 [docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)；
  3. 执行 `pytest tests/test_project_integrity.py -v`，通过后提交并推送 `main` 跟踪 CI `xcodebuild test` 与 `GlassMPV-v1.1.0` IPA 产物。
