# GlassMPV 工程踩坑复盘与防复发门禁沉淀

本文档系统记录 GlassMPV 从 `v1.0.0` 立项至 `v1.0.2` 云端 CI 出包与端内实播排查期间暴露出的 7 类典型工程问题，以及对应的根因修复与自动化防复发门禁。

---

## 1. Swift 6 严格并发下 `CAMetalLayer` 子类捕获 `super` 编译失败

### 【现象】
- 在 `SWIFT_VERSION = 6.0` 下，直接继承 `CAMetalLayer` 并重写 `wantsExtendedDynamicRangeContent` 时，如果在 `DispatchQueue.main` 闭包的非主线程分支直接访问 `super.wantsExtendedDynamicRangeContent`，编译器报捕获 `self` / `super` 跨隔离域错误（参考历史提交 `26f751f`、`29ffa8d`、`8d46fec`）。

### 【根因】
- `CAMetalLayer` 未遵循 `Sendable`，在 Swift 6 严格并发检查中不能直接跨 `@Sendable` 闭包捕获 `self`（而访问 `super` 隐式依赖 `self`）。

### 【修复】
- 通过 `private struct UnsafeSendableBox<T>: @unchecked Sendable` 显式封装引用，再调用内部辅助方法 `setSuperWantsEDR(_:)` 完成底层属性写入，不在 `@Sendable` 闭包内直接书写 `super`。

### 【防复发门禁】
- 保持 `project.yml` 强制锁定 `SWIFT_VERSION: "6.0"`，CI 全量编译即作为 Swift 6 并发合规门禁。

---

## 2. XcodeGen `info:` 字段覆写手写 `Sources/Info.plist`

### 【现象】
- `Sources/Info.plist` 中已声明 `CADisableMinimumFrameDurationOnPhone = true`（开启 120Hz ProMotion）、`UILaunchScreen` 与文档共享权限，但早期的 IPA 中 `Info.plist` 缺失关键字段导致启动黑屏或帧率受限（参考提交 `5805799`）。

### 【根因】
- `project.yml` 同时存在 `info:` 块与 `INFOPLIST_FILE` 设置时，XcodeGen 会在 `xcodegen generate` 阶段以 `info:` 内容重新生成并覆盖 `Sources/Info.plist`。

### 【修复】
- 从 `project.yml` 彻底移除 `info:` 块，设置 `GENERATE_INFOPLIST_FILE: "NO"` 与 `INFOPLIST_FILE: Sources/Info.plist`，并以 `excludes: [Info.plist]` 防止被重复打入资源复制阶段。

### 【防复发门禁】
- [test_project_integrity.py](../tests/test_project_integrity.py) 强制断言 `"info" not in target_cfg` 且 `GENERATE_INFOPLIST_FILE` 关闭；[build-ios.yml](../.github/workflows/build-ios.yml) 在打包后用 `plutil -p` 校验 `CADisableMinimumFrameDurationOnPhone`、`UILaunchScreen` 与 `CFBundleIcons`。

---

## 3. XcodeGen `resources:` 配置错误导致 58 个 GLSL 着色器未打入 IPA

### 【现象】
- `Resources/Shaders/` 下已完整提取 58 个 `.glsl` 着色器，但早期构建产物 `GlassMPV.app` 内缺失 `Shaders` 目录，运行时 `SingleShaderOption.resolvedShaderPaths` 返回空数组。

### 【根因】
- `project.yml` Target 级不存在独立的 `resources:` 配置字段，XcodeGen 将资源目录配置在 `sources:` 列表中并配合 `type: folder` + `buildPhase: resources` 才能将整个目录拷贝进 `.app/Shaders`。

### 【修复】
- 移除无效 `resources:` 键，改为在 `targets.GlassMPV.sources` 下配置 `path: Resources/Shaders`、`type: folder`、`buildPhase: resources`。

### 【防复发门禁】
- [test_project_integrity.py](../tests/test_project_integrity.py) 校验 `"resources" not in target_cfg` 与 `Resources/Shaders` 数量等于 58；CI 打包步骤断言 `Payload/GlassMPV.app/Shaders/*.glsl` 数量严格等于 58；`GlassMPVTests.testAll58GLSLShadersPresentAndResolvable` 在模拟器测试宿主 Bundle 内实测全部预设路径可解析。

---

## 4. 26 个 `MinimumOSVersion: 100.0` 占位 `.framework` 污染签名与安装

### 【现象】
- 构建产物的 `GlassMPV.app/Frameworks/` 中出现大量带 `MinimumOSVersion = 100.0` 的空壳/占位动态框架，导致部分签名安装工具拒签或安装失败（参考提交 `5805799`）。

### 【根因】
- 依赖包 `MPVKit` 以静态库为主体链接进主二进制，但 Xcode 在特定无签构建路径下会将未实际动态链接的 XCFramework 占位壳拷入 `Frameworks/`。

### 【修复】
- 在 CI 打包脚本中通过 `otool -L Payload/GlassMPV.app/GlassMPV` 探测主二进制是否真正依赖 `@rpath` 或 `@executable_path/Frameworks`；若全部为静态链接，则自动清理无效的 `Payload/GlassMPV.app/Frameworks` 目录。

### 【防复发门禁】
- 在 [build-ios.yml](../.github/workflows/build-ios.yml) 的 `Package unsigned IPA` 步骤固化 `otool -L` 校验与自动剔除逻辑。

---

## 5. 冷启动 `0x0` 图层、`LC_NUMERIC` 与过早探测导致的启动闪退

### 【现象】
- 应用在未选中任何视频的冷启动阶段即直接闪退，无法进入主界面（参考提交 `5805799`）。

### 【根因】
- 启动时立即挂载了尺寸为 `0x0` 的视频表面并初始化 `mpv`/MoltenVK，同时主界面提前调用 `VTLowLatencyFrameInterpolationConfiguration.isSupported` 探测；此外 iOS 下部分地区 Locale 的小数点格式会触发 `libmpv` 解析异常。

### 【修复】
- 仅在 `coordinator.currentURL != nil` 后才挂载视频渲染视图；
- 在 `MPVMetalContainerView.layoutSubviews()` 中确保 `window != nil` 且 `bounds.width > 1 && bounds.height > 1` 时才回调初始化 `mpv`；
- 在 `mpv_create()` 前强制调用 `setlocale(LC_NUMERIC, "C")`；
- 将 `VTLowLatencyFrameInterpolationConfiguration.isSupported` 延后至切换至 ANE 光流核加载时探测。

### 【防复发门禁】
- [test_project_integrity.py](../tests/test_project_integrity.py) 断言 `MPVPlayerCore.swift` 必须包含 `setlocale(LC_NUMERIC, "C")`；`LiquidGlassPlayerView.swift` 保持 `if coordinator.currentURL != nil` 条件挂载。

---

## 6. `DispatchQueue.main.sync` 死锁、`layerClass` 差异、FileProvider 权限与静默黑屏

### 【现象】
- 用户可正常打开进入 App，但选择视频后出现黑屏、卡死或毫无画面反应，界面也无任何错误提示。

### 【根因】
1. **线程死锁隐患**：`MPVMetalLayer.wantsExtendedDynamicRangeContent` 在非主线程写入时调用了 `DispatchQueue.main.sync`，当主线程同步等待事件/锁或繁忙时直接发生死锁。
2. **图层宿主模型差异**：通过重写 `UIView.layerClass` 替换容器根图层与 `MPVKit` 官方示例的独立 `addSublayer(metalLayer)` 不一致，且未在 `layoutSubviews` 内关闭隐式动画同步更新 `drawableSize`。
3. **主线程阻塞命令与盲区**：`loadfile`、`seek`、`change-list` 使用同步 `mpv_command`；未监听 `MPV_EVENT_LOG_MESSAGE` 与 `MPV_EVENT_END_FILE`，导致文件打不开或解码失败时界面静默黑屏。
4. **激进默认配置与沙盒文件权限**：默认开启 6 个 Anime4K 着色器 + `120Hz` 时域重采样 + 强制 `hwdec=videotoolbox`；部分 FileProvider（如“文件”App/iCloud/第三方网盘）提供的 `Security-Scoped URL` 无法直接被 C 层路径读取。

### 【修复】
- `MPVMetalLayer.wantsExtendedDynamicRangeContent` 改为 `DispatchQueue.main.async`；
- `MPVMetalContainerView` 改用 `layer.addSublayer(metalLayer)` 并在 `CATransaction` 中禁用隐式动画更新 `frame`/`drawableSize`；
- `MPVPlayerController` 改为 `mpv_command_async`，`hwdec` 改为 `auto-safe`，默认预设与插值降为保守直出 `.off`；
- 监听 `MPV_EVENT_START_FILE`、`MPV_EVENT_FILE_LOADED`、`MPV_EVENT_PLAYBACK_RESTART`、`MPV_EVENT_END_FILE`、`MPV_EVENT_LOG_MESSAGE`，出现异常直接弹出错误横幅与「关闭超分重试」；
- `PlayerCoordinator.open` 在 `isReadableFile` 为假时通过 `NSFileCoordinator` 协调拷贝到沙盒临时区再交付播放。

### 【防复发门禁】
- [test_project_integrity.py](../tests/test_project_integrity.py) 禁绝 `DispatchQueue.main.sync`，强制要求 `addSublayer`、`mpv_command_async`、`MPV_EVENT_END_FILE`、`MPV_EVENT_LOG_MESSAGE`；
- `GlassMPVTests.testMetalContainerViewSublayerAndEDRThreadSafety` 在模拟器上实测 `addSublayer`、`1x1` 拦截与后台写 EDR 不阻塞。

---

## 7. 缺乏端内一键自测与 CI iOS 模拟器实播测试闭环

### 【现象】
- 此前只有静态构建（编译通过 + 打包 IPA），缺乏自动化的真机/模拟器实播解码验证和端内可视化排错入口，导致“能进桌面但点不开视频”在出包阶段未被拦截。

### 【根因】
- 项目缺少 `unit-test` 靶标与免外部视频依赖的合成测试片生成器，CI 流程只有 `build` 没有 `xcodebuild test`。

### 【修复】
- 新增 `TestVideoGenerator`，纯代码通过 `AVAssetWriter` 在 0.2 秒内合成 3 秒 640×360 H.264 MP4 彩条测试片；
- 首页与诊断中心 (`DiagnosticLogSheet`) 新增「一键自测（内置 3 秒测试视频）」与最近 100 条 `libmpv` 日志查看/复制面板；
- 新增 `GlassMPVTests` 靶标与 `MPVPlayerController.attachHeadlessForTesting()`，并在 [build-ios.yml](../.github/workflows/build-ios.yml) 中接入 iOS 模拟器 `xcodebuild test` 门禁，验证 `duration > 2.0`、`videoWidth == 640`、`videoHeight == 360` 与 `currentTime > 0.1`。
- 针对 `VideoToolbox` 光流 API（`VTFrameProcessor` / `VTLowLatencyFrameInterpolationConfiguration`）仅在 `iphoneos` 真机 SDK 提供、在 `iphonesimulator` SDK 下不存在的问题，在 `VTOpticalFlowEngine.swift` 中使用 `#if !targetEnvironment(simulator)` 隔离硬件光流管线，保证模拟器测试宿主编译通过且真机逻辑完全不变。

### 【防复发门禁】
- [test_project_integrity.py](../tests/test_project_integrity.py) 校验 `GlassMPVTests` 存在于 `project.yml` 且 `xcodebuild test` 存在于 CI 工作流；每次推送 `main` 必须先通过模拟器实播测试才允许出包。
