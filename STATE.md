# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `272d7d4` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `eee3404` | 最新交付 IPA `dist/GlassMPV-0.1.0-beta.2-b20-unsigned.ipa`）
- **当前阶段**：`已完成 v0.1.0-beta.2 (Build 20)：针对 164451 实机日志与反馈彻底修复展开控制栏 120Hz 掉帧（4Hz 遥测节流 + layoutDisplayLayer 幂等 + 1600px 高刷上限 + renderToLayerStatus 背压 + 去嵌套轻量化 HUD）并上线夸克单机扫码通道（uop.quark.cn CAS 二维码保存相册直跳 quark:// + .mobile 网页与 __puus 补全）；CI Run 45970694843 全绿（33/33），IPA 已校验并投递微信「文件传输助手」`
- **最后活跃时间**：`2026-11-27 17:18:00` | **最近安全快照**：`eee3404`（CI Run `45970694843` 绿灯出包，`272d7d4` 为私有主线代码与单测同步点）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 v0.1.0-beta.2 (Build 20)：120Hz 展开控制栏零掉帧重塑 + 夸克单机扫码与 __puus 补全，CI Run 45970694843 全绿 33/33 并已投递微信「文件传输助手」；等待用户实机验收控制栏满帧与夸克扫码/播放表现`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
    - **展开控制栏 120Hz 掉帧根治**：`164451` 日志确认 `therm=正常` 下 120fps 开启 HUD 后滑落至 ~81fps/46.5fps。现将帧率/丢帧/avDelta/耗时收口至内部 `raw*` 按 4Hz 节流发布、修复 `applyVideoTransform`/`layoutDisplayLayer` 120×/s 无效重算、96/120fps 非超分直绘封顶 `1600px` 并接入 `MetalInFlightCounter` 3 缓冲背压（`renderToLayerStatus`），同时剥离底栏 9 处嵌套 `.glassEffect`，高刷期改用低开销半透明描边 HUD。
    - **夸克单机扫码与 Cookie 闭环**：新增 `QuarkDriveClient.requestQRLoginToken`/`pollQRLoginTicket`/`exchangeServiceTicketForCookie`/`bootstrapSessionCookie` 原生 CAS 扫码通道，支持 CoreImage 二维码保存相册 + 一键拉起 `quark://` App 扫相册确认；网页登录默认 `.mobile` 并补齐 `WKUIDelegate`/`WKNavigationDelegate` 外链拉起。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV v0.1.0-beta.2`（公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `eee3404`，CI Run `45970694843`，耗时 `10m51s`）iOS 模拟器 `GlassMPVTests` 33/33 通过（`Executed 33 tests, with 0 failures (0 unexpected) in 19.653 (20.255) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-0.1.0-beta.2-b20-unsigned.ipa`（`3,310,527` bytes，纯原生系统框架 + `Assets.car`，0 个 `.glsl` 着色器，已启用 `NSAppTransportSecurity`、`NSPhotoLibraryAddUsageDescription` 与 `LSApplicationQueriesSchemes`）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.61s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 `GlassMPVTests 33/33` 与 Release Beta IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-0.1.0-beta.2-b20-unsigned.ipa`（`3,310,527` bytes；`Info.plist` 校验 `CFBundleIdentifier=com.glassmpv.player`、`CFBundleShortVersionString=0.1.0`、`CFBundleVersion=20`，含 `Assets.car`，0 个 `.glsl` 着色器，`NSAllowsArbitraryLoads=true`、`NSPhotoLibraryAddUsageDescription`、`LSApplicationQueriesSchemes=[quark, weixin]`）。
  - 最新实机闭环日志：`GlassMPV-Log-20261127-164451.txt`（`v0.1.0-beta.1 Build 18`，证实零拷贝直绘已将温度控制为 `正常`，并精确定位展开 HUD 后 120fps 掉帧源于高频 `@Published` 重排 + 嵌套 `.glassEffect` + 2560px 无背压直绘，及夸克桌面页单机不可扫问题，已在 `beta.2` 彻底修复）。
  - **已定因根因与本轮已核验架构约束**：
    1. **4Hz 遥测与高刷直绘背压**：`OpticalFlowPlayerController` 所有帧级统计均先写入 `raw*` 再按 `0.25s` 节流同步至 `@Published`（首帧/暂停/采样除外），`SampleBufferDisplayContainerView.layoutDisplayLayer` 具备全字段幂等保护与 `96/120fps` 1600px 长边上限，`MetalVideoEnhancer.renderToLayerStatus` 限流 3 帧并发在途。
    2. **夸克单机扫码与 `__puus` 兜底**：优先采用 `uop.quark.cn` 原生 CAS 二维码（存相册 + `quark://` 跳转）与 2s 自动轮询，并通过 `/account/info?st=...` + `bootstrapSessionCookie` 首访根目录确保 `__puus` 落库。
    3. **Swift 6 与门禁红线**：`QuarkPhotoSaver` 延迟初始化避开非隔离 memberwise `init`；`WKNavigationDelegate` `decidePolicyFor async` 内部使用 `_ = await UIApplication.shared.open(...)`；`VTOpticalFlowEngine.swift` 的 `runOpticalFlowTask..#endif` 区间内严禁 `.lock()`/`.unlock()`；`tests/GlassMPVTests.swift` 禁止含未转义引号的 `"""`。
- **待办清单**：
  - [x] 完成 `v0.1.0-beta.2 (Build 20)` 控制栏 120Hz 掉帧根治与夸克单机扫码通道上线（CI Run `45970694843`，33/33 PASS，`10m51s`）。
  - [x] 下载校验 `dist/GlassMPV-0.1.0-beta.2-b20-unsigned.ipa`（`3,310,527` bytes）并投递微信「文件传输助手」。
  - [ ] 用户真机实测 `v0.1.0-beta.2`：确认开启 120fps + 展开控制栏与超分弹窗不掉帧，并验证夸克「保存二维码并打开夸克 App」单机扫码登录与视频流播放体验。
