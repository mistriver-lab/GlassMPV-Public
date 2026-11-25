# 插帧方案深度调研与 iOS 端稳定架构选型报告

> 调研来源：
> 1. 桌面端实证样本：`C:\Users\21920\Downloads\mpvnet-20231122.zip`（`96,051,643` bytes，183 个文件，含 `portable_config`、`k7sfunc.py` 与 `vapoursynth64` 插件集）
> 2. GitHub 开源生态与 Apple 官方 SDK：`LePips/MPVUI`（0.11.0）、`mpvkit/MPVKit`、`Practical-RIFE` / CoreML 方案、Apple `VideoToolbox`（iOS 26 `VTFrameProcessor`）与 `MetalFX`（iOS 26 `MTLFXFrameInterpolator`）

---

## 1. 电脑端 `mpvnet-20231122.zip` 插帧实现机制深度剖析

该桌面端整合包源自 **mpv.net + MPV_lazy（hooke007）** 体系，采用**“L1 原生时域混合兜底 + L2 VapourSynth 滤镜链真补帧”**的双层架构。

### 1.1 L1 轻量兜底层：mpv 原生时域混合 (`interpolation` + `tscale`)
- **配置文件**：`mpvnet/portable_config/mpv.conf` 与 `profiles.conf`
- **默认行为**：`mpv.conf` 中默认启用 `vo = gpu`、`gpu-context = d3d11`、`hwdec = auto`、`interpolation = yes`、`hr-seek-framedrop = no`。
- **高刷自保护 (`[vsync-auto]`)**：`profiles.conf` 明确配置了条件规避规则（引用 `mpv-player/mpv/issues/11122`）：
  ```ini
  [vsync-auto]
  profile-cond = p.display_fps>122
  profile-restore = copy
  interpolation = no
  video-sync = audio
  ```
  当显示器刷新率超过 122Hz 时自动关闭 `interpolation` 并回退 `video-sync = audio`，防止高刷新率下的同步抖动。
- **算法本质**：mpv 原生 `interpolation` **不做光流或块匹配运动估计**，仅在 `video-sync = display-resample` 下使用 `tscale`（时间轴重采样核，如 `oversample`、`triangle`、`sphinx`）对相邻帧做时间权重混合，用于消除 24fps→60Hz 的 3:2 pulldown 颤动。

### 1.2 L2 重度真补帧层：VapourSynth + `k7sfunc.py` 四套 MEMC 管线
在 `mpvnet/portable_config/input.conf` 中通过快捷键 `ALT+1` ~ `ALT+4` 动态挂载 `-vf vapoursynth="~~/vs/MEMC_*.vpy"`，由内嵌 `VapourSynth.dll` + `python311.dll` + `vapoursynth64/plugins/` 执行真运动估计与补偿（MEMC）：

| 快捷键 / 脚本 | 底层引擎二进制 | 算法核心与关键参数（实证自 `k7sfunc.py` 与 `.vpy`） | 色彩/精度与性能特征 |
| :--- | :--- | :--- | :--- |
| `ALT+1`<br>`MEMC_MVT_LQ.vpy` | `libmvtools.dll` (4.74 MB) | `k7f.MVT_LQ`：补边对齐 `blk_size=32` → `mv.Super(pel=1, sharp=0)` → `mv.Analyse` → `mv.Recalculate(blksize=16, thsad=200)` → `mv.BlockFPS`（可选 `FlowFPS`）输出 `2×` | 纯 CPU 多线程（`core.num_threads`），低算力开销、块边缘较明显 |
| `ALT+2`<br>`MEMC_MVT_STD.vpy` | `libmvtools.dll` (4.74 MB) | `k7f.MVT_STD`：`mv.Super(sharp=1, rfilter=4)` → `mv.Analyse(blksize=64, pelsearch=3, overlapv=16, lsad=10000)` → `mv.BlockFPS(mode=2, thscd1=970, thscd2=255, blend=False)` 输出 `60.0fps`（文档建议高刷屏可设为 `display_fps/2`，余量交由 `--interpolation`） | 纯 CPU 块匹配，保守策略避免严重果冻伪影 |
| `ALT+3`<br>`MEMC_SVP_LQ.vpy` | `svpflow1_vs64.dll` (439 KB)<br>`svpflow2_vs64.dll` (470 KB) | `k7f.SVP_LQ`：`svp1.Super(pel:2, gpu:1, scale:{up:2, down:4})` → `svp1.Analyse(block:{w:32, h:16, overlap:2}, main:{levels:4}, refine:[{thsad:200}])` → `svp2.SmoothFps(algo:21, mask:{area:100}, scene:{limits:{m1:1800, m2:3600, scene:5200}})` | OpenCL/GPU + CPU 混合块匹配光流；10-bit 源先转 `YUV420P8` 做运动分析，GPU 模式下在原 10-bit 帧上合成输出 |
| `ALT+4`<br>`MEMC_RIFE_STD.vpy` | `RIFE.dll` (5.99 MB)<br>`models/rife-v4/flownet.bin` (10.61 MB)<br>`flownet.param` (16.7 KB)<br>`MiscFilters.dll` (24 KB) | `k7f.RIFE_STD`：`misc.SCDetect(threshold=0.15)` 场景切换检测 → `resize.Bilinear` 转 `vs.RGBS`（BT.709 32-bit 浮点）→ `rife.RIFE(model=9, factor_num=2, factor_den=1, gpu_thread=2, sc=True, skip=True, skip_threshold=60.0)` → 转回源 YUV | 基于 ncnn + Vulkan GPU 深度学习光流；显存与带宽极高，但具备**场景切换防撕裂**与**静止帧跳过**优化 |

### 1.3 桌面端核心工程护栏（极值得 iOS 端借鉴）
1. **高帧率源熔断 (`k7f.FPS_CTRL`)**：所有 `.vpy` 均前置 `FPS_CTRL(clip, fps_in=container_fps, fps_ret=True)`，默认 `fps_max = 32.0`。当片源超过 32fps（如 50/60fps 源）时直接中止 MEMC，防止无意义算力浪费与反向掉帧。
2. **分辨率预限幅 (`k7f.FMT_CTRL`)**：前置 `FMT_CTRL(clip, h_max=1440)`，高度超出 `H_Pre` 时先用 `Bicubic` 降采样，并对齐 YUV 色度抽样偶数宽高。
3. **场景切换与静止帧门控 (`sc_mode` + `skip`)**：RIFE 管线在推理前先用 `SCDetect` 检测切镜避免跨镜头鬼影，用 `stat_th = 60.0` 跳过静止帧（如字幕静止画面/PPT）。
4. **半倍率 + 时域混合组合**：`MEMC_MVT_STD.vpy` 注释指出，高刷屏不必强行算到 120/144fps，算到 `display_fps / 2`（例如 60fps）再配合 mpv `--interpolation` 可兼顾画质与功耗。

---

## 2. 桌面端方案为何不能直接移植到 iOS？

1. **进程与动态库沙箱限制**：iOS 严禁 App 动态加载或执行未签名二进制插件（`.pyd` / `.dll`）及内嵌 CPython 解释器动态扩展，无法运行 VapourSynth 滤镜宿主。
2. **SVP (`svpflow`) 闭源无 ARM64 iOS 构建**：`svpflow1`/`svpflow2` 依赖桌面 OpenCL/Vulkan 商业闭源库，无 iOS 平台产物。
3. **ncnn RIFE (`RIFE.dll`) 在 iOS 的转译与带宽瓶颈**：桌面版 `RIFE.dll` 走 Vulkan Compute；在 iOS 上只能通过 `MoltenVK` 转译为 Metal GPU 计算，无法利用 Apple Silicon 的 **ANE（神经网络引擎）**，且 `RGBS`（32-bit float × 3 通道）纹理在移动端统一内存下极易引发热节流（`ThermalState.serious`）与 Jetsam OOM 闪退。
4. **`AVSampleBufferDisplayLayer` 与 `MPV` 双管道内存拷贝代价**：若从 `libmpv` 软解回读帧做后处理再回传显示，会破坏 `VideoToolbox` 零拷贝硬解链路，功耗剧增。

---

## 3. GitHub 与 Apple iOS 端已验证插帧方案横向对比

| 方案路线 | 代表实现 / API | 计算单元 | 支持容器与超分共存 | 画质与稳定性评价 | 移动端功耗 / 发热 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **A. mpv 原生时域平滑** | `LePips/MPVUI`、`mpvkit/MPVKit` (`video-sync=display-resample` + `interpolation=yes` + `tscale=oversample`) | GPU (`MoltenVK` + `gpu-next`) | **全格式** (MKV/MP4/FLV/WebM)、支持 ASS 特效字幕与 **58 个 GLSL 超分共存** | 仅时域帧混合，无运动补偿；高对比度横移物体仍有轻微拖影，但**零伪影、零崩溃** | 极低（可长时间 120Hz 稳态播放） |
| **B. VideoToolbox 系统硬件光流** | Apple `VideoToolbox` (`VTFrameProcessor` + `VTLowLatencyFrameInterpolationConfiguration` / `VTFrameRateConversionConfiguration`, iOS 26.0+) | **ANE 神经网络引擎 + 媒体引擎** | 当前走 `AVAssetReader`（原生 MP4/MOV）；可通过 `spatialScaleFactor: 2` 同步超分，**不走 mpv GLSL** | **真光流插帧**，Apple 原生硬件流水线，`CVPixelBuffer` + `IOSurface` 零拷贝，iOS 26 实测稳定 | **最优真光流能效比**（远低于 GPU 推理），但高分辨率连续多倍仍会触发温升 |
| **C. CoreML RIFE v4.x + Metal Warp** | GitHub 社区移植方案（PyTorch Practical-RIFE v4.25/v4.26 转 `.mlpackage` + 自定义 Metal `grid_sample` Warp Shader） | ANE / MPSGraph + Metal GPU | 需自建解码帧队列（`AVAssetReader` 或 FFmpeg）；难以直接与 `mpv` `libass`/58 GLSL 串联 | 动漫大位移/线条锐度优于传统块匹配；但需内置 10MB+ 模型权重，且须降采样到 540p/720p 计算光流金字塔 + 切镜/静止帧跳过 | 中高（1080p 以上长播易触发 `serious` 热降频，Simulator 上 `MPSGraphDevice` 易异常） |
| **D. Metal 4 帧生成** | `MetalFX` (`MTLFXFrameInterpolator` / `MTL4FXFrameInterpolator`, iOS 26.0+) | Metal 4 GPU + ML | 面向 3D 渲染管线（强制依赖深度图、游戏引擎 Motion Vector 缓冲） | **不适用于普通 2D 视频播放**（无深度与真实运动矢量输入） | 不适用 |

---

## 4. GlassMPV iOS 端稳定落地架构选型结论

综合桌面端 `mpvnet` 工程经验与 iOS 26 真机硬件约束，GlassMPV 确立**“双轨协同 + `k7sfunc` 防护移植”**的最终落地方案：

1. **全能主力轨（`MPV 超分核`：全格式 + 58 GLSL + 120Hz 时域平滑）**
   - 保持 `LePips/MPVUI`（`videoOutput: .metal`）底座，负责 MKV/ASS 字幕/HDR 与 58 个 Anime4K/FSRCNNX 着色器渲染；
   - 通过 `video-sync=display-resample` + `interpolation=yes` + `tscale=oversample` + `display-fps-override=120` 提供零发热、全格式可用的 120Hz 平滑体验。
2. **真光流高能效轨（`ANE 光流核`：Apple `VTFrameProcessor`）**
   - **唯一推荐在 iOS 端作为长期默认真补帧引擎**的技术路线：直接调用 iOS 26 系统级 `VTLowLatencyFrameInterpolationConfiguration`（`numberOfInterpolatedFrames: 1` 或 `spatialScaleFactor: 2`），依托 ANE 硬件管线与 `CVPixelBufferPool` + `AVSampleBufferDisplayLayer`（带 `kCMSampleAttachmentKey_DisplayImmediately`）实现 2× 真光流补帧。
   - **拒绝在主播放核中直接内嵌桌面式 Python/VapourSynth 或纯 Vulkan RIFE**，仅将 CoreML RIFE 作为未来面向 1080p 以下 SDR 动漫的实验性可选项（且必须配合 Simulator passthrough 保护与降采样金字塔）。
3. **从 `k7sfunc.py` 移植到 iOS 光流核的四项关键防护准则（后续迭代准则）**
   - **帧率熔断 (`FPS_CTRL` 思路)**：源帧率 `> 32fps`（如 50/60fps 视频）默认提示或跳过 2× 光流，避免 60→120fps 高功耗空转。
   - **空间降维保护 (`FMT_CTRL` 思路)**：针对 4K 高码率片源或 `spatial2x` 模式严格约束缓冲队列与输出尺寸，避免内存与帧预算超时把输入帧率拖垮。
   - **温度闭环感知**：监听 `ProcessInfo.thermalStateDidChangeNotification`，在常驻 HUD 实时暴露 `正常 / 温热 / 过热 / 严重过热` 状态，当达到 `serious`/`critical` 时可提示用户或自动降级回 MPV 平滑模式。
   - **中远期容器突破**：若需对 **MKV / FLV** 开启 ANE 真光流，后续可通过 `FFmpeg` 解封装 + `VTDecompressionSession` 硬解直接吐出 `CVPixelBuffer`，再无缝喂入现有的 `VTFrameProcessor` 管线，无需绕道 `AVAssetReader`。
