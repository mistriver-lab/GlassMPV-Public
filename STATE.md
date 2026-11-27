# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `399bd85` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `08be28d` | 最新交付 IPA `dist/GlassMPV-0.1.0-beta.1-b18-unsigned.ipa`）
- **当前阶段**：`已完成 v0.1.0-beta.1 三合一升级：切换初始 Beta 版本体系（0.1.0 / Build 18）、零拷贝异步 FP16 CAMetalLayer 直绘与 48/60fps 解除 .latencyCritical 温控减负、纯原生 NWListener 127.0.0.1 本地 HTTP 代理根治夸克 403 与 __puus 续期；CI Run 45965239531 全绿（31/31），IPA 已校验并投递微信「文件传输助手」`
- **最后活跃时间**：`2026-11-27 16:32:00` | **最近安全快照**：`08be28d`（CI Run `45965239531` 绿灯出包，`399bd85` 为私有主线代码与单测同步点）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 v0.1.0-beta.1 (Build 18)：零拷贝 FP16 CAMetalLayer 直绘降耗 + 夸克 127.0.0.1 本地代理与 __puus 续期 + 初始 Beta 版本号，CI Run 45965239531 全绿 31/31 并已投递微信「文件传输助手」；等待用户实机验收温度控制与夸克/Emby 播放表现`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
  * [x] 响应 `153158` 实机日志专项优化 + Phase 2 云端片源库上线（`a956a5c` / 公开镜像 `00fae3e`）：重构多尺度 Luma 去糊、`.serious` 降档至 `2×(48fps)`、可点选「分屏对比 / 对比原画」暂停即时刷新及 夸克/Emby/WebDAV 云端片源（CI Run `45961120348`，28/28 PASS）。
  * [x] `v0.1.0-beta.1 (Build 18)` 性能温控与夸克代理架构重构（`399bd85` / 公开镜像 `08be28d`）：
    - **零拷贝异步 FP16 直绘与温控减负**：针对 `160642` 日志暴露的 `waitUntilCompleted()` 与 `+36MB` 冗余拷贝，新增 `CAMetalLayer` 全异步 Fragment Shader（16-bit `half` 5 点硬件双线性采样、零 `copyChroma`、零中间缓冲池、`addCompletedHandler` 非阻塞统计 GPU 耗时）；`48/60fps` 释放 `.latencyCritical`。
    - **夸克直连彻底加固**：新增 `LocalHTTPStreamProxy.swift`（`NWListener` 绑定 `127.0.0.1`），跨 302 重定向与 `.m3u8` 分片全程注入 `Cookie / Referer / User-Agent` 根治 403，捕获 `Set-Cookie` 自动回写 `__puus` 至 Keychain；夸克内置登录页切换至 `.desktop` 桌面模式并强校验 `__puus`/`__pus`。
    - **Beta 版本切换**：`VERSION` 改为 `0.1.0-beta.1`、`project.yml` `MARKETING_VERSION` 设为 `0.1.0`、CI Run `45965239531`（`7m22s`）`GlassMPVTests` 31/31 全绿交付 `3,214,453` bytes IPA。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV v0.1.0-beta.1`（公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `08be28d`，CI Run `45965239531`，耗时 `7m22s`）iOS 模拟器 `GlassMPVTests` 31/31 通过（`Executed 31 tests, with 0 failures (0 unexpected) in 55.764 (56.185) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-0.1.0-beta.1-b18-unsigned.ipa`（`3,214,453` bytes，纯原生系统框架 + `Assets.car`，0 个 `.glsl` 着色器，已启用 `NSAppTransportSecurity`）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.32s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 `GlassMPVTests 31/31` 与 Release Beta IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-0.1.0-beta.1-b18-unsigned.ipa`（`3,214,453` bytes；`Info.plist` 校验 `CFBundleIdentifier=com.glassmpv.player`、`CFBundleShortVersionString=0.1.0`、`CFBundleVersion=18`，含 `Assets.car`，0 个 `.glsl` 着色器，`NSAllowsArbitraryLoads=true`）。
  - 最新实机闭环日志：`GlassMPV-Log-20261127-160642.txt`（`Build 202611271557`，定位 `waitUntilCompleted()` `5.55ms` 同步等待、`+36MB` 拷贝与 `.latencyCritical` 锁频导致过热，已在本版重构为零拷贝 `CAMetalLayer` 直绘）。
  - **已定因根因与本轮已核验架构约束**：
    1. **本地 HTTP 反向代理与 `__puus` 持久化**：`LocalHTTPStreamProxy` 通过 `NWListener` + `URLSessionDataDelegate` 流式转发，302 与 `.m3u8` 重写不丢 `Cookie / Referer / UA`，并在响应 `Set-Cookie` 时触发 `onCookieUpdate` 同步写入 `MediaSourceStore`。
    2. **零拷贝异步 `CAMetalLayer` 与 Activity 降耗**：非 HDR/杜比视界画质增强直接由 Fragment Shader（FP16 5 点线性多尺度）上屏，禁止在热渲染路径调用 `waitUntilCompleted()`；仅 `96/120fps` 申请 `.latencyCritical`。
    3. **Swift 6 与门禁红线**：测试异步桩锁操作封装于 `@unchecked Sendable` 同步方法；`OpticalFlowPlayerController` 保持 `nonisolated init()`；`tests/GlassMPVTests.swift` 禁止含未转义引号的 `"""` 多行字符串；`VTOpticalFlowEngine.swift` 的 `runOpticalFlowTask..#endif` 区间内严禁直接出现 `.lock()`/`.unlock()`。
- **待办清单**：
  - [x] 完成 `v0.1.0-beta.1 (Build 18)` 零拷贝 FP16 直绘、`.latencyCritical` 温控降压与 `LocalHTTPStreamProxy` 上线（CI Run `45965239531`，31/31 PASS，`7m22s`）。
  - [x] 下载校验 `dist/GlassMPV-0.1.0-beta.1-b18-unsigned.ipa`（`3,214,453` bytes）并投递微信「文件传输助手」。
  - [ ] 用户真机实测 `v0.1.0-beta.1`：对比 `48fps + 老片去糊` 机身发热改善，以及夸克网盘桌面扫码挂载与 `127.0.0.1` 代理播放稳定性。
