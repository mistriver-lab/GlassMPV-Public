# GlassMPV — iOS 26/27 纯原生 VideoToolbox ANE 光流真补帧播放器

专为 **iPhone 15 Pro Max（A17 Pro + 120Hz ProMotion，iOS 26 / 27+）** 设计的轻量级纯原生播放器，采用 Apple Silicon 神经网络引擎（ANE）`VideoToolbox.VTFrameProcessor` 硬件光流真补帧与原生硬解直通双模式，搭配 **Liquid Glass** 液态玻璃界面。

## 核心特性

1. **ANE 硬件光流真补帧（默认开启，支持多档位）**
   - 调用 Apple `VideoToolbox.VTFrameProcessor`（优先 `VTLowLatencyFrameInterpolationConfiguration` 低内存 `420v` 管线，辅以 `VTFrameRateConversionConfiguration` 兜底）。
   - 支持 **2× / 60fps / 96fps / 120fps** 四档实用目标帧率（24p 自动匹配 `48 / 60 / 96 / 120 fps`，30p 自动收敛为 `60 / 120 fps`，60p 收敛为 `120 fps`），配合 ProMotion 物理档位精准锁频（48Hz / 60Hz / 120Hz）、低电量 60Hz 上限保护及 2× 单相空间硬件超分（4K 片源自动禁用空间超分，保留光流补帧）。
   - 内置 `OpticalFlowPhaseScheduler`（整倍等分 + 非整倍时间栅格重采样）、`OpticalFlowBudgetGuard`（「先降分辨率、再降目标帧率」算力自适应）、`ThermalState` 主动温控限档及 `hev1→hvc1` 压缩透传硬解兜底。

2. **实时 Metal + MetalFX GPU 画质增强（兼容原画直通、分屏对比与高帧率补帧）**
   - **假 4K / 老片去糊 & 动漫强化**：单遍多尺度（1px+2px）亮度去糊、死区抗噪与防光晕 CAS 自适应锐化，不破坏 10-bit HDR 与色度。
   - **低清超分（MetalFX）与热功耗保护**：支持 `MTLFXSpatialScaler` 感知重建（60fps 封顶 1080p、高刷/高温自动切省电直锐），提供可点击「分屏对比 / 原画对比」且暂停态即时刷新（杜比视界自动保留原厂映射）。

3. **原生云端片源库（夸克网盘 / Emby / WebDAV・Alist）**
   - 内置网页一键提取夸克 Cookie（系统 Keychain 加密存储）、Emby 媒体库登录（支持局域网 HTTP）与 WebDAV/Alist 浏览；支持播放中切换 `原画直链 / 夸克 4K / Emby HLS` 及离线缓存精播。

4. **原帧率硬解直通模式（关闭补帧时启用）**
   - 直接走 `AVAssetReader` / `VTDecompressionSession` 硬解直通送显，不开启光流推理，功耗最低。

3. **iOS 26/27 Liquid Glass 液态玻璃交互 & 全链路黑匣子诊断**
   - 支持本地视频选择器（`UIDocumentPickerViewController`）、系统相册（`PhotosPicker`）、网络串流与一键生成 3 秒内置测试视频。
   - 内置 2 秒周期黑匣子采样、`[ui-switch]` 交互审计、真机 4 项体检及 `.txt` 诊断日志一键导出分享。

---

## 云端自动编译 `.ipa`（GitHub Actions）

1. 推送代码至仓库 `main` 分支，GitHub Actions（`macos-latest`）自动执行 `xcodegen generate`、iOS 模拟器 `GlassMPVTests` 单元测试与无签 Release `.ipa` 打包。
2. 在 Actions 构建记录的 **Artifacts** 下载 **`GlassMPV-unsigned-ipa`**，通过 Sideloadly / AltStore 签名安装至 iPhone 即可使用。

---

## 目录结构

- `Sources/Models/OpticalFlowOptions.swift`：补帧模式与 ANE 目标帧率枚举（`2× / 60 / 96 / 120fps`）与片源自适应选项
- `Sources/Engine/VTOpticalFlowEngine.swift`：`VideoToolbox` `VTFrameProcessor` 硬件光流真补帧与原帧率硬解直通核心
- `Sources/Models/PlaybackTelemetry.swift`：HUD 参数汇总、设备内存/型号采样、黑匣子时间轴与客观判定
- `Sources/UI/LiquidGlassPlayerView.swift`：Liquid Glass 液态玻璃播放界面、光流控制台与诊断中心
- `.github/workflows/build-ios.yml`：GitHub Actions `macos-latest` 自动单测与构建未签名 `.ipa` 工作流
- `tests/GlassMPVTests.swift`：Swift XCTest 单元测试套件
- `tests/test_project_integrity.py`：工程结构、Swift 语法括号平衡与红线门禁测试
