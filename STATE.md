# 🧭 项目状态与会话交接中枢 (STATE.md)
> 🚨 **反重力智能体铁律**：每次开启新会话首轮静默读取本文件，并在回复开头输出 <50 字【现场复原快照】。

## 📌 项目基本元数据
- **工程名称**：`ipa开发`（主线 `GlassMPV 2026.11.26` @ `1014b2b` | 最新交付 IPA `dist/GlassMPV-2026.11.26-202611260950-unsigned.ipa`）
- **当前阶段**：`已完成 095951 真机日志核验（4K ANE LowLatency 1480×1080 已稳定 2× 补帧 47.8fps，MPV 确定仅支持去抖动不支持运动补帧）并完成 ANE 多档位帧率（2×/60/72/96/120fps）+ 相位重采样 + 算力自适应降档架构设计；因当前上下文触及 SPEC-34 180k 红线熔断，待 /compact 或新窗直接编码落地、出包与微信投递`
- **最后活跃时间**：`2026-11-26 10:11:30` | **最近安全快照**：`89b941e`（CI Run `45737880768` 绿灯出包）
- **运行环境**：`Swift 6.0 / iOS 26+ / XcodeGen + GitHub Actions macOS CI (无本地 Xcode)`

---

## 🎯 当前核心推进焦点 (Active Focus)
`已核验095951真机4K ANE 2x稳定生效；因触发SPEC-34红线，待新窗/compact按已定方案实施ANE多档位帧率(2x/60/72/96/120fps)`
- 最近交付闭环（更早的 2 项历史里程碑已归档至 [CHANGELOG.md](file:///C:/Users/21920/Desktop/ipa开发/CHANGELOG.md)）：
  * [x] 修复 `VTOpticalFlowEngine.swift` `VTDecompressionSessionCreate` 参数标签与 `test_project_integrity.py` 断言（`b4676df`）；CI Run `45588353144` 全绿出包并交付微信「文件传输助手」。
  * [x] 完成 `VTOpticalFlowEngine.swift` 跨平台 `OpticalFlowResolutionPlanner`、双后端 `ActiveOpticalFlowConfiguration`（LowLatency + FRC）、边界查询、不覆盖 `IOSurfaceProperties`、首帧 `-19730` 自动降档切后端自愈、`LiquidGlassPlayerView.swift` `activeBackendLabel` 透出、`VERSION`/`project.yml`/`CHANGELOG.md`/`AppReleaseInfo.swift` 升级 `2026.11.26`（`cf3d397`）。
  * [x] 修复 `OpticalFlowCandidate` / `OpticalFlowBackendKind` `Hashable`（`42a9739`）与 `testMPVUIControllerPlaybackWithWindowHost` 慢跑器轮询窗口放宽至 30s（`1014b2b`），CI Run `45737880768` 全绿出包并交付微信「文件传输助手」。

---

## 📚 领域规约与防复发门禁
- 工程专属铁律：[.agents/rules/GEMINI.md](.agents/rules/GEMINI.md)
- 历史踩坑与防复发沉淀：[docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)
- 工程构建配置：[project.yml](project.yml) | 云端流水线：[.github/workflows/build-ios.yml](.github/workflows/build-ios.yml)

---

## 🧪 最近一次自动化门禁状态 (Latest Verification Gate)
<!-- AGY:REGRESSION:START -->
> 🟢 **[PASS]** `GlassMPV 2026.11.26`（主线 `mistriver-lab/GlassMPV` @ `1014b2b`，CI Run `45737880768`，耗时 `7m23s`）iOS 模拟器 `GlassMPVTests` 20/20 通过（`9.866 (9.938) seconds`）且 Release `iphoneos` 打包全绿，交付 `dist/GlassMPV-2026.11.26-202611260950-unsigned.ipa`（`21,828,153` bytes，含 58 个 GLSL 着色器 & `Assets.car`）；主仓本地 `pytest tests/test_project_integrity.py -v`（7 passed in `0.64s`）PASS
<!-- AGY:REGRESSION:END -->
- **门禁评级**：🟢 [PASS]（全量单测与无签 IPA 交付均已绿灯）
- **交付与工作区归档**：
  - 主线最新交付 IPA：`dist/GlassMPV-2026.11.26-202611260950-unsigned.ipa`（`21,828,153` bytes；`Info.plist` 校验 `CFBundleIdentifier=com.glassmpv.player`、`CFBundleShortVersionString=2026.11.26`、`CFBundleVersion=202611260950`，内含 58 个 GLSL 着色器与 `Assets.car`）。
  - 最新实机诊断日志：`C:\Users\21920\Documents\xwechat_files\wxid_8mhh4tfklkan22_9a3a\msg\file\2026-11\GlassMPV-Log-20261126-095951.txt`（Build `202611260950`，`2960×2160` HEVC 23.98fps：`MPV` `sync=yes,interp=yes,tscale=linear,vsync=5.00` 属纯去抖动不生成运动帧；`ANE` 降档至 `LowLatency 1480×1080` + 压缩透传兜底后成功补帧 `interp=835, fail=0, pres=1618, avg=20.5ms`，实测稳定 `47.8fps` 即 2×，偶发段 `drop` 40→56）。
- **待办清单**：
  - [x] 拉取 `45735826023` 与 `45736501105` 失败日志并完成双轮修复：`OpticalFlowCandidate`/`OpticalFlowBackendKind` 遵循 `Hashable`（`42a9739`），放宽 `testMPVUIControllerPlaybackWithWindowHost` 轮询窗口至 30s（`1014b2b`）；CI Run `45737880768` 全绿出包，已下载校验 `dist/GlassMPV-2026.11.26-202611260950-unsigned.ipa` 并投递微信「文件传输助手」。
  - [x] 核验真机实测日志 `GlassMPV-Log-20261126-095951.txt` 并完成 ANE 多档位帧率（`2× / 60 / 72 / 96 / 120 fps`）升级方案设计。
  - [ ] 【新窗/compact 后首步】直接实施 ANE 多档位目标帧率升级：1) `Sources/Models/ShaderPreset.swift` 新增 `OpticalFlowTargetFPS`（`x2 / fps60 / fps72 / fps96 / fps120`，仅 `x2` 允许 `spatial2x`）；2) `Sources/Engine/VTOpticalFlowEngine.swift` 扩展 `OpticalFlowCandidate.maxInterpolatedFrames`、`OpticalFlowResolutionPlanner` 后端优先级（2 的幂倍率优先 `LowLatency`，非 2 的幂如 24→60/72/120 优先 `FRC`）、新增跨平台 `OpticalFlowPhaseScheduler`（整倍等分 + 非整倍时间栅格重采样）与 `OpticalFlowBudgetGuard`（先降分辨率后降帧率档位）、单次多缓冲 `process` 调用与动态队列上限（锁定 helper 放在 `runOpticalFlowTask` 的 `#endif` 外）；3) `PlaybackTelemetry.swift` + `LiquidGlassPlayerView.swift` + `AppReleaseInfo.swift` + `CHANGELOG.md` 透出目标/实测档位与分段选择 UI；4) `GlassMPVTests.swift` 新增 `testOpticalFlowPhaseSchedulerAndMultiTierTargets` 与 `test_project_integrity.py` 断言 → 本地 `pytest` 全绿 → 推送 `main` 等 CI 出包 → 校验 IPA 并投递微信「文件传输助手」。