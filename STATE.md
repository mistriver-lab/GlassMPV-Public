# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `ce902ba` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `ce902ba` | 最新交付 IPA `dist/GlassMPV-0.1.0-beta.9-b31-unsigned.ipa`）
- **当前阶段**：`已完成 v0.1.0-beta.9 (Build 31)：合并 beta.8 与 beta.9 彻底根治真 4K（3840×2160）高刷「一闪一闪发糊」、5.86GB 在线流加载卡顿与开关补帧 24~32s 重建阻塞；CI Run 46010263351 全绿 44/44（9m39s），IPA 已校验并投递微信「文件传输助手」`
- **最后活跃时间**：`2026-11-27 22:01:00` | **最近安全快照**：`ce902ba`（CI Run `46010263351` 绿灯出包）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 v0.1.0-beta.9 (Build 31)：消除 25Hz 4K↔360p 锐度频闪（同分对齐+抬高清底线+4对预热豁免）、原画降采样自动硬件 MetalFX 重建、MP4 Box-Aware 零拷贝跳过 mdat + NWConnection 4MB/1MB 滑动窗口背压、云端流零断流热开关补帧与 0.5s 关键帧快跳；CI Run 46010263351 全绿 44/44，IPA 已投递微信`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
    - **消除真 4K 高刷频闪与自动 MetalFX (`v0.1.0-beta.8` + `v0.1.0-beta.9`)**：锁定 96/120fps ProMotion `minimum = 120Hz`；`RemoteStreamOpticalFlowWorker` 缓存 `preparedBuffer`、发射原帧对齐 `preparedCurr` 消除 25Hz 清晰度闪烁、移除 `360p/288p` 档（底线抬至 `2×: 1080p/720p`、`60/96fps: 720p/540p`、`120fps: 540p/480p`）并加 4 对预热豁免；`MetalVideoEnhancer` 原画高刷加入 3×3 中性 Mitchell 采样与降采样光流自动 `MTLFXSpatialScaler`（零锐化）。
    - **真 4K 大文件代理吞吐与热切换补帧 (`v0.1.0-beta.9`)**：`MP4HEV1StreamPatcher(startsAtFileOffsetZero:)` 按 ISO BMFF Box 边界零扫描透传 multi-GB `mdat` 并守护尾部 `moov`；`UpstreamStreamRelay` 新增 `4MB/1MB` `inFlightBytes` 滑动窗口背压；`OpticalFlowPlayerController.setRemoteInterpolationEnabled` 与 `LiquidGlassPlayerView.setInterpolation` 支持云端流零断流热开关补帧、10s 前向缓冲与 `0.5s` 关键帧 Seek。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV v0.1.0-beta.9`（`mistriver-lab/GlassMPV-Public` @ `ce902ba`，CI Run `46010263351`，总耗时 `9m39s`）iOS 模拟器 `GlassMPVTests` 44/44 通过（`Executed 44 tests, with 0 failures (0 unexpected) in 11.996 (13.343) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-0.1.0-beta.9-b31-unsigned.ipa`（`3,875,044` bytes，`CFBundleIdentifier=com.glassmpv.player`，`CFBundleShortVersionString=0.1.0`，`CFBundleVersion=31`，含 `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.51s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 `GlassMPVTests 44/44` 与 Release Beta IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-0.1.0-beta.9-b31-unsigned.ipa`（`3,875,044` bytes）。
  - 最新实机定因日志：`GlassMPV-Log-20261127-213243.txt`。
- **待办清单**：
  - [x] 完成 `v0.1.0-beta.9 (Build 31)` 消除真 4K 高刷频闪发糊、MetalFX 自动感知重建、5.86GB Box-Aware 零扫描透传 + 背压与云端热开关补帧（CI Run `46010263351`，44/44 PASS，`9m39s`）。
  - [x] 下载校验 `dist/GlassMPV-0.1.0-beta.9-b31-unsigned.ipa`（`3,875,044` bytes）并发送至微信「文件传输助手」。
  - [ ] 用户安装 `v0.1.0-beta.9-b31` 真机实测：播放 `3840×2160` 5.86GB 夸克原画直链验证高刷不闪烁、画面清晰度与开关补帧/Seek 加载流畅度；后续视需要进入阶段 B（TMDB 刮削海报墙与剧集详情页）。
