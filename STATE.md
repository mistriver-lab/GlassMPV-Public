# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（iOS App Target: `GlassMPV` `v1.1.0` 已验证出包 | GitHub: `mistriver-lab/GlassMPV`）
- **当前阶段**：`v1.1.0 MPVUI (0.11.0) 开源底座重构完成，本地与云端 CI 全部绿灯`
- **最后活跃时间**：`2026-11-24 11:37:45` | **最近安全快照**：`a9f355b`（CI Run `45319794144`）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`GlassMPV v1.1.0 切换 MPVUI (0.11.0) 开源底座重构收尾与 CI 验证`
- 本轮已全部完成并推送 `main` 验证通过（`c4cb917` -> `a9f355b`）：
  * [x] [project.yml](project.yml)、[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)、[VERSION](VERSION)、[CHANGELOG.md](CHANGELOG.md)、[Sources/Models/AppReleaseInfo.swift](Sources/Models/AppReleaseInfo.swift)：切换依赖至 `LePips/MPVUI (0.11.0)` 并升版 `v1.1.0`
  * [x] [Sources/Engine/MPVPlayerCore.swift](Sources/Engine/MPVPlayerCore.swift)：基于 `MPVPlayer` / `MPVVideoPlayer` (`videoOutput: .metal`) 重写播放内核与诊断流
  * [x] [Sources/Engine/LocalMediaImporter.swift](Sources/Engine/LocalMediaImporter.swift)：新增 `MovieFileTransferable` 与异步 `NSFileCoordinator` 沙盒导入器
  * [x] [Sources/Engine/VTOpticalFlowEngine.swift](Sources/Engine/VTOpticalFlowEngine.swift)：修复 `kCMSampleAttachmentKey_DisplayImmediately`、`spatial2x` 尺寸一致、补帧异常遥测透出及 Swift 6 不可变闭包捕获
  * [x] [Sources/UI/LiquidGlassPlayerView.swift](Sources/UI/LiquidGlassPlayerView.swift)：补齐视图层 `PhotosPicker` 按钮、`onChange`、导入状态提示与 `DiagnosticLogSheet`「真机 5 项体检」面板
  * [x] [tests/test_project_integrity.py](tests/test_project_integrity.py)、[tests/GlassMPVTests.swift](tests/GlassMPVTests.swift)、[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)：完成门禁适配、实播/导入/光流 5 项单测与第 9 节复盘沉淀

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** 本地 `pytest tests/test_project_integrity.py -v`（7/7 通过）且云端 CI Run `45319794144`（提交 `a9f355b`）`xcodebuild test` 5/5 通过并产出 `GlassMPV-v1.1.0-b16-unsigned.ipa`
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS] 云端 CI Run `45319794144`（2026-11-24，`8m17s`）`GlassMPVTests` 5 项测试全绿（`15.841s`），已上传制品 `GlassMPV-unsigned-ipa`（`21,522,479` bytes / `GlassMPV-v1.1.0-b16-unsigned.ipa`）
- **后续建议**：
  1. 从 GitHub Actions Run `45319794144` 下载 `GlassMPV-unsigned-ipa`（`GlassMPV-v1.1.0-b16-unsigned.ipa`）进行无签/自签安装真机实测；
  2. 真机验证时依次测试：欢迎页「从相册选取」/「打开本地视频」、诊断中心「真机 5 项体检」以及切换「ANE 光流核」观察补帧计数与错误反馈。
