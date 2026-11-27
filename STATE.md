# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（私有主线 `mistriver-lab/GlassMPV` @ `c3fb325` / 公开 CI 镜像 `mistriver-lab/GlassMPV-Public` @ `c3fb325` | 最新交付 IPA `dist/GlassMPV-0.1.0-beta.7-b29-unsigned.ipa`）
- **当前阶段**：`已完成 v0.1.0-beta.7 (Build 29)：阶段 A 全面对标 Infuse 8 深度架构重塑（原生「首页/片源/设置」3 Tab 底栏 + NavigationStack 推入式浏览、目录星标收藏夹、本地离线片库、极简影院 HUD 与「视频|音频|字幕|播放」统一 4 分区 ⚙️ 设置面板、双指捏合缩放、默认连续播放 + 片尾 15s Up Next 倒计时、目录记忆「跳过片头」胶囊与自定义快进退步长）；CI Run 46000557703 全绿 42/42，IPA 已校验并投递微信「文件传输助手」`
- **最后活跃时间**：`2026-11-27 20:49:40` | **最近安全快照**：`c3fb325`（CI Run `46000557703` 绿灯出包）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已完成 v0.1.0-beta.7 (Build 29)：Infuse 8 原生三 Tab 架构、目录收藏夹、极简影院 HUD+统一设置面板、捏合缩放/Up Next/跳过片头闭环；CI Run 46000557703 全绿 42/42 并已投递微信「文件传输助手」`
- 最近交付闭环（更早的历史里程碑已归档至 [CHANGELOG.md](CHANGELOG.md)）：
    - **对标 Infuse 8 信息架构与追剧闭环 (`InfuseHomeShellView` + `CloudDirectoryBrowserView` + `PlayerUnifiedSettingsSheet` + `UserPreferencesStore`)**：原生底部三 Tab（「首页」继续观看+收藏夹+离线片库 / 「片源」Native Push 浏览与星标收藏 / 「设置」追剧、手势、画质、缓存管理）；播放器采用上下影院暗角与克制底栏、`⚙️` 四分区面板、双指捏合适应↔铺满、默认连续播放 + 片尾 Up Next 倒计时及目录记忆跳过片头。
    - **夸克直链超时根治与自动降级 HLS (`v0.1.0-beta.6`)**：`ProxyUpstreamSessionPool` 持久连接池（12s 快速失败返回 504/502）、刷新 `__puus` Cookie 透传、主流 `.failed` 秒切 HLS 备选流并保留续播进度。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV v0.1.0-beta.7`（`mistriver-lab/GlassMPV-Public` @ `c3fb325`，CI Run `46000557703`，核心构建耗时 `3m36s`）iOS 模拟器 `GlassMPVTests` 42/42 通过（`Executed 42 tests, with 0 failures (0 unexpected) in 15.854 (15.935) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-0.1.0-beta.7-b29-unsigned.ipa`（`3,860,393` bytes，`CFBundleIdentifier=com.glassmpv.player`，`CFBundleShortVersionString=0.1.0`，`CFBundleVersion=29`，含 `Assets.car`，0 个 `.glsl` 着色器）；主仓本地 `pytest tests/test_project_integrity.py -v`（`6 passed in 0.50s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（本地 `pytest 6/6`、远程 `GlassMPVTests 42/42` 与 Release Beta IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 最新交付 IPA：`dist/GlassMPV-0.1.0-beta.7-b29-unsigned.ipa`（`3,860,393` bytes）。
  - 最新实机定因日志：`GlassMPV-Log-20261127-195958.txt`。
- **待办清单**：
  - [x] 完成 `v0.1.0-beta.7 (Build 29)` 对标 Infuse 8 阶段 A 全面架构与追剧微交互重塑（CI Run `46000557703`，42/42 PASS，`3m36s`）。
  - [x] 下载校验 `dist/GlassMPV-0.1.0-beta.7-b29-unsigned.ipa`（`3,860,393` bytes）并发送至微信「文件传输助手」。
  - [ ] 用户安装 `v0.1.0-beta.7-b29` 真机实测：体验原生 3 Tab「首页/片源/设置」、目录收藏夹、极简 HUD + `⚙️` 四分区面板、双指捏合、片尾 Up Next 倒计时与跳过片头；后续视需要进入阶段 B（TMDB 刮削海报墙与剧集详情页）。
