# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（主线 `GlassMPV v1.1.0` 已出包 | 衍生：`mistriver-lab/CinePlayer` 云端无签构建中）
- **当前阶段**：`GlassMPV v1.1.0 已交付 dist；CinePlayer Fork 云端构建 Run 45322902101 待排查失败日志`
- **最后活跃时间**：`2026-11-24 11:58:30` | **最近安全快照**：`72e9711`（`GlassMPV` CI Run `45319794144`）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`排查 mistriver-lab/CinePlayer 云端构建 Run 45322902101 失败原因并完成无签 iOS IPA 构建（或切换兼容版本/KSPlayer）`
- **已完成事项**：
  * [x] `GlassMPV v1.1.0` 通过本地 `pytest`（7/7）与 CI Run `45319794144`（5/5 `XCTest`），无签 IPA 已下载至 [dist/GlassMPV-v1.1.0-b16-unsigned.ipa](dist/GlassMPV-v1.1.0-b16-unsigned.ipa)（`21,599,242` bytes）。
  * [x] 已将 `cinemore/CinePlayer` Fork 至 GitHub `mistriver-lab/CinePlayer`（默认分支 `main`）。
  * [x] 已通过 GitHub API 向 `mistriver-lab/CinePlayer` 提交 `.github/workflows/build-ios-ipa.yml`（`Xcode_26.6.0` 自动选择、校验下载 `v2.0.0 Frameworks.zip`、`-skipPackagePluginValidation -skipMacroValidation`）。
  * [x] 第一次构建 Run `45322663610`（SPM 插件信任拦截）已修复；第二次构建 Run `45322902101`（`https://github.com/mistriver-lab/CinePlayer/actions/runs/45322902101`）在 `Build unsigned Release iOS app` 阶段退出码 65 失败，因当前会话达到 180k Tokens 熔断红线，待新会话拉取日志排障。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV` 本地 `pytest`（7/7）与 CI Run `45319794144`（`a9f355b`）5/5 通过并落地 `dist/GlassMPV-v1.1.0-b16-unsigned.ipa`；衍生任务 `mistriver-lab/CinePlayer` Run `45322902101` 待排错
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（`GlassMPV` 基线全绿） / 🟡 [IN PROGRESS]（`mistriver-lab/CinePlayer` Run `45322902101` 待查错）
- **下一窗口首步待办**：
  1. 执行 `gh run view 45322902101 -R mistriver-lab/CinePlayer --log-failed` 定位具体报错；
  2. 核实 `Xcode_26.6.0` 是否与 `CinePlayer v2.0.0 Frameworks.zip`（README 标注使用 Swift 6.4 / Xcode 27 编译）存在版本不兼容；若确为编译器版本或商业 SDK 限制，向用户确认改建 `v1.0.1` / `v1.0.0` 或切换纯开源 `kingslay/KSPlayer` (`Demo/SwiftUI`)；
  3. 若可修复，更新 `mistriver-lab/CinePlayer` 的 `.github/workflows/build-ios-ipa.yml` 出包后下载至 `dist/`。
