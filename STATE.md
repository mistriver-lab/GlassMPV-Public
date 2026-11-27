# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `a956a5c` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `00fae3e` | 最新交付 IPA `dist/GlassMPV-2026.11.27-202611271557-unsigned.ipa`）
- **当前阶段**：`已完成 Phase 2 原生云端片源库（夸克网盘 + Emby + WebDAV/Alist，含内置网页提取夸克 Cookie、直链/转码切换与 ANE+Metal 流媒体联动）及 153158 实机日志反馈的过热/去糊强度/分屏对比修复；CI Run 45961120348 全绿（28/28）、IPA 已下载校验（3,160,211 bytes）并投递微信「文件传输助手」`
- **最后活跃时间**：`2026-11-27 16:00:00` | **最近安全快照**：`00fae3e`（CI Run `45961120348` 绿灯出包，`a956a5c` 为私有主线代码与单测同步点）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成夸克网盘 + Emby + WebDAV/Alist 原生云端片源整合与 153158 实机热控/去糊/分屏对比专项修复（CI Run 45961120348 全绿 28/28），定版 IPA 已下载校验并投递微信「文件传输助手」；等待用户实机验收云端挂载、热控及画质分屏对比`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
  * [x] Phase 1 实时 Metal + MetalFX 画质增强引擎上线（`ba872d4` / 公开镜像 `3f51ddf`）：支持「原画 / 老片去糊 / 动漫强化 / 低清超分」，CI Run `45957449192`（24/24 PASS）。
  * [x] 响应 `153158` 实机日志专项优化 + Phase 2 云端片源库上线（`a956a5c` / 公开镜像 `00fae3e`）：
    - **实机过热/去糊/对比修复**：移除高耗时 8 邻域双边 `exp()`，改为单遍多尺度（1px+2px）邻域限幅 Luma 去糊 + 死区门控 + 防光晕 CAS；`MetalFX` 新增高刷/高温保护（`outputFPS > 65` 或过热自动切省电直锐，60fps 封顶 1080p）；`ThermalState.serious` 限档由 `60fps` 调整为 `2×(48fps)` 快速降温；新增可点击「**分屏对比（左原画｜右增强）**」与「**对比原画**」并缓存最近原始帧以支持暂停态零延迟刷新。
    - **原生云端片源库**：新增 `MediaSourceModels`、`MediaSourceClients`、`RemoteStreamOpticalFlowWorker`、`CloudMediaLibraryView` 及 `Info.plist` `NSAppTransportSecurity`；支持夸克网盘内置网页登录提取 Cookie、Emby 登录/海报墙/无损 HLS、`WebDAV / Alist` 目录挂载、播放底栏流切换与离线高速缓存。
    - **云端 CI 验证**：CI Run `45961120348`（`8m53s`）`GlassMPVTests` 28/28 全绿交付 `3,160,211` bytes IPA。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV 2026.11.27`（公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `00fae3e`，CI Run `45961120348`，耗时 `8m53s`）iOS 模拟器 `GlassMPVTests` 28/28 通过（`Executed 28 tests, with 0 failures (0 unexpected) in 43.728 (43.749) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-2026.11.27-202611271557-unsigned.ipa`（`3,160,211` bytes，纯原生系统框架 + `Assets.car`，0 个 `.glsl` 着色器，已启用 `NSAppTransportSecurity`）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.21s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 `GlassMPVTests 28/28` 与 Release IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-2026.11.27-202611271557-unsigned.ipa`（`3,160,211` bytes；`Info.plist` 校验 `CFBundleIdentifier=com.glassmpv.player`、`CFBundleShortVersionString=2026.11.27`、`CFBundleVersion=202611271557`，含 `Assets.car`，0 个 `.glsl` 着色器，`NSAllowsArbitraryLoads=true`）。
  - 最新实机闭环日志：`GlassMPV-Log-20261127-153158.txt`（`Build 202611271522`，暴露 `.serious` 60fps[×4] 过热、双边 `exp()` 与 120fps+MetalFX 并发高耗电、`DragGesture` 按住对比暂停未重刷等根因，已在本版彻底修复）。
  - **已定因根因与本轮已核验架构约束**：
    1. **远程流并发与 `VideoToolbox` SDK 边界**：`RemoteStreamOpticalFlowWorker` 采用 `@unchecked Sendable` + `NSLock` + `Task.detached` 串联 `VTFrameProcessor.process(parameters:)`，使用 `OpticalFlowResolutionPlanner.lowLatencyExponent(forInterpolatedFrames:)` 与 `proc.startSession(configuration:)`；`AVPlayer.seek(to:toleranceBefore:toleranceAfter:)` 须在 `async` 上下文加 `await`。
    2. **Metal/MetalFX 热控预算与对比刷新**：禁止在每帧像素着色器内执行 8 邻域 `exp()`；`outputFPS > 65` 或 `.serious`/`.critical` 热态时 MetalFX 自动退为省电直锐，`ThermalState.serious` 限档至 `2×(48fps)`；`presentFrame` 缓存最近 `CVPixelBuffer` 以支撑暂停态即时重绘对比画面。
    3. **Swift 6 与门禁红线**：`OpticalFlowPlayerController` 保持 `nonisolated init()`（非 `@MainActor` 私有状态不加 `@MainActor`）；`tests/GlassMPVTests.swift` 禁止使用含未转义引号的 `"""` 多行字符串，确保平衡检验器通过；`VTOpticalFlowEngine.swift` 的 `runOpticalFlowTask..#endif` 区间内严禁直接出现 `.lock()`/`.unlock()`。
- **待办清单**：
  - [x] 完成 `153158` 实机热控/去糊/分屏对比修复与夸克网盘/Emby/WebDAV 云端片源上线（CI Run `45961120348`，28/28 PASS，`8m53s`）。
  - [x] 下载校验 `dist/GlassMPV-2026.11.27-202611271557-unsigned.ipa`（`3,160,211` bytes）并投递微信「文件传输助手」。
  - [ ] 用户真机实测：夸克网盘/Emby 挂载播放、`老片去糊 / 低清超分`「分屏对比」与温度控制表现。