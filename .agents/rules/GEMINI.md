---
trigger: always_on
---
# ipa开发 (GlassMPV) - iOS / Swift 6 工程开发守则

本工作区（`ipa开发`，对应 iOS App Target `GlassMPV`、GitHub 仓库 `mistriver-lab/GlassMPV`）专用于 iOS 媒体播放器与无签 IPA 云端持续交付。

## 1. 工程身份与环境边界
- **目标平台与编译约束**：`iOS 26.0+`、`SWIFT_VERSION: "6.0"`、依赖 `MPVKit` (`1.0.0+`)，工程文件由 `XcodeGen` (`project.yml`) 动态生成，云端构建与模拟器 `XCTest` 在 GitHub Actions (`macos-latest`) 执行。
- **不改核心 Target 标识**：除非用户明确要求全量改包名，保持 `project.yml` Target `GlassMPV`、Bundle ID 与 GitHub 仓库关联不变。

## 2. 硬性防复发门禁（源自 `docs/LESSONS_LEARNED.md`）
1. **Swift 6 并发与 C 回调隔离铁律**：
   - 严禁在 `@MainActor` 方法内向 C 函数（如 `mpv_set_wakeup_callback`）传入内联闭包；C 回调必须定义为文件顶层非隔离函数（如 `mpvWakeupCallback(_:)`），否则会触发 `_dispatch_assert_queue_fail` 闪退。
   - 严禁在 `@Sendable` 闭包内直接捕获 `super`；跨线程写入 `CAMetalLayer` 属性须经由 `@unchecked Sendable` 包装并异步派发，严禁使用 `DispatchQueue.main.sync`。
2. **XcodeGen 与资源打包铁律**：
   - 严禁在 `project.yml` 的 `targets.GlassMPV` 下添加 `info:` 或 `resources:` 键；保持 `GENERATE_INFOPLIST_FILE: "NO"` 与 `INFOPLIST_FILE: Sources/Info.plist`。
   - 58 个 GLSL 着色器必须保持在 `Sources` 下的 `Resources/Shaders`（`type: folder` + `buildPhase: resources`）。
3. **libmpv 生命周期与跨 SDK 铁律**：
   - 必须保留 `setlocale(LC_NUMERIC, "C")`、`layer.addSublayer(metalLayer)`、`mpv_command_async`、以及 `shutdownCore` 中 `eventQueue.sync {}` 排空后再 `mpv_terminate_destroy(handle)`。
   - 仅 `iphoneos` 真机 SDK 提供的 `VideoToolbox` 光流 API 必须使用 `#if !targetEnvironment(simulator)` 隔离，确保模拟器 `XCTest` 宿主可编可测。
4. **本地与云端双重验证铁律**：
   - 每次提交代码前必须在本地执行 `pytest tests/test_project_integrity.py -v` 并全部通过。
   - 每次代码改动推送 `main` 后须等待 CI `xcodebuild test`（`GlassMPVTests`）绿灯通过并校验 IPA 产物。
