# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（iOS App Target: `GlassMPV` `v1.0.2` | GitHub: `mistriver-lab/GlassMPV`）
- **当前阶段**：`v1.0.2 云端 CI 全绿出包与模拟器实播验证已完成 (b14)`
- **最后活跃时间**：`2026-11-24 10:57:00` | **最近安全快照**：`基线 823422d`（CI Run `45314254206`）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`GlassMPV v1.0.2 真机验机反馈与后续功能迭代准备`
- 最近交付闭环：
  * [x] 修复端内「能进桌面但播放黑屏」根因并新增内置 3 秒合成测试片一键自测与 100 条 `libmpv` 诊断日志面板（[CHANGELOG.md](CHANGELOG.md)）
  * [x] 修复 Swift 6 `@MainActor` 内联 C 回调触发 `_dispatch_assert_queue_fail` 崩溃（抽离顶层非隔离 `mpvWakeupCallback`、`shutdownCore` 主线程同步状态与 `eventQueue.sync` 排空），沉淀 8 类工程复盘至 [docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
  * [x] 完成 CI iOS 模拟器 `XCTest` 全绿（Run `45314254206`，`4/4` passed `** TEST SUCCEEDED **`）与无签 IPA 产物 `dist/GlassMPV-v1.0.2-b14-unsigned.ipa` 校验（`Assets.car` + 58 个 `.glsl` + `CFBundleIcons` + `120Hz`）

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[VERIFIED PASS]** 本地完整性门禁 `pytest tests/test_project_integrity.py` 7/7 + 云端 CI `xcodebuild test` (`GlassMPVTests`) 4/4 `** TEST SUCCEEDED **` | Run: `45314254206`
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS] 本地完整性 7 passed | iOS 模拟器实播测试 4 passed (`duration=3.00 size=640x360 time=0.17 err=nil`)
- **待办事项**：等待用户使用 [dist/GlassMPV-v1.0.2-b14-unsigned.ipa](dist/GlassMPV-v1.0.2-b14-unsigned.ipa) 真机签装实测反馈后推进下一版本迭代
