---
trigger: always_on
---
# ipa开发 (GlassMPV) - iOS / Swift 6 工程开发守则

本工作区（`ipa开发`，对应 iOS App Target `GlassMPV`、私有主线 `mistriver-lab/GlassMPV` 与公开 CI 镜像 `mistriver-lab/GlassMPV-Public`）专用于纯原生 VideoToolbox ANE 硬件光流播放器与无签 IPA 云端持续交付。

## 1. 工程身份与环境边界
- **目标平台与编译约束**：`iOS 26.0+`、`SWIFT_VERSION: "6.0"`、纯系统原生框架（`AVFoundation` / `VideoToolbox` / `CoreMedia` / `CoreVideo` / `SwiftUI`，无第三方 Swift Package / MPVKit 依赖），工程文件由 `XcodeGen` (`project.yml`) 动态生成，云端构建与模拟器 `XCTest` 在 GitHub Actions (`macos-latest`) 执行。
- **不改核心 Target 标识**：保持 `project.yml` Target `GlassMPV`、Bundle ID `com.glassmpv.player` 与 GitHub 仓库关联不变，确保无缝覆盖安装。

## 2. 硬性防复发门禁（源自 `docs/LESSONS_LEARNED.md`）
0. **初始 Beta 语义版本号铁律**：
   - 使用标准语义化 Beta 版本：`VERSION` 为 `0.1.0-beta.x`，`MARKETING_VERSION` / `CFBundleShortVersionString`（及 `project.yml`）为 `0.1.0`（纯三段数字满足 Apple 规范），`CURRENT_PROJECT_VERSION` / `CFBundleVersion` 随 CI `GITHUB_RUN_NUMBER` 递增，IPA 产物统一命名为 `GlassMPV-<VERSION>-b<BUILD>-unsigned.ipa`。
1. **Swift 6 并发与锁隔离铁律**：
   - 严禁在 `@Sendable` 闭包内直接捕获 `super`；严禁使用 `DispatchQueue.main.sync`。
   - `VTOpticalFlowEngine.swift` 的 `runOpticalFlowTask..#endif` 区间内严禁直接调用 `.lock()` / `.unlock()`，同步操作须封装于独立的同步 helper。
   - 内存采样须使用 `task_self_trap()`（严禁引用全局可变 `mach_task_self_`）及 `MemoryLayout.size(ofValue: sysinfo.machine)`。
2. **XcodeGen 与资源打包铁律**：
   - 严禁在 `project.yml` 的 `targets.GlassMPV` 下添加 `info:` 或 `resources:` 键；保持 `GENERATE_INFOPLIST_FILE: "NO"` 与 `INFOPLIST_FILE: Sources/Info.plist`。
   - `Assets.xcassets` 须保留在 `Sources` 列表内以正确生成 `Assets.car`。
3. **跨 SDK 隔离铁律**：
   - 仅 `iphoneos` 真机 SDK 提供的 `VideoToolbox` 光流 API（`VTLowLatencyFrameInterpolationConfiguration` / `VTFrameRateConversionConfiguration` / `VTFrameProcessor`）必须使用 `#if !targetEnvironment(simulator)` 隔离，确保模拟器 `XCTest` 宿主可编可测。
   - 原帧率硬解直通模式（`runPassthroughTask`）使用跨平台 `AVAssetReader` / `VTDecompressionSession`，在真机与模拟器均可编译运行。
4. **本地与云端双重验证铁律**：
   - 每次提交代码前必须在本地执行 `pytest tests/test_project_integrity.py -v` 并全部通过。
   - 每次代码改动推送后须等待 CI `xcodebuild test`（`GlassMPVTests`）绿灯通过并校验 IPA 产物，且默认自动执行 `gh run download <run_id> -n GlassMPV-unsigned-ipa -D dist` 将最新无签 IPA 下载至本地 `dist/` 目录并向用户输出可点击本地文件路径。
