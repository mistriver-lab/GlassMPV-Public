# GlassMPV — iOS 26/27 液态玻璃双核超分补帧播放器

专为 **iPhone 15 Pro Max（A17 Pro + 120Hz ProMotion，iOS 26 / 27+）** 设计，提取并移植了原 `mpvnet` 桌面包中的全部 **58 个 GLSL 超分着色器** 与 9 档 Anime4K 预设，并采用 **路线 C 双核架构** 与原生 **Liquid Glass** 液态玻璃界面。

## 核心特性

1. **MPV 超分核（默认，全格式兼容）**
   - 基于 [`mpvkit/MPVKit`](https://github.com/mpvkit/MPVKit)（`libmpv` + `MoltenVK` + `VideoToolbox` 硬解 + `libass` 特效字幕）。
   - 完整保留原包 `input.conf` 中的 **9 档 Anime4K 组合预设**（Mode A/B/C/A+A/B+B/C+A 的 FAST 与 HQ 档），以及 **AMD FSR、FSRCNNX、KrigBilateral、NNEDI3、RAVU Zoom、Adaptive Sharpen** 单项叠加。
   - 内置 `video-sync=display-resample` + `interpolation=yes` + `tscale=oversample` 时域平滑，消除 24fps 动漫/电影的顿挫感并适配 120Hz 屏幕。

2. **ANE 光流核（真光流插帧，适合本地 MP4/MOV）**
   - 调用 Apple Silicon 神经网络引擎硬件接口 `VideoToolbox.VTFrameProcessor`（`VTLowLatencyFrameInterpolationConfiguration`）。
   - 在相邻帧之间实时生成真实运动补偿中间帧（24→48fps / 30→60fps / 60→120fps），支持同步开启硬件 2× 超分。
   - 若打开 MKV/FLV 等非原生容器，底部会提示一键切回「MPV 超分核」。

3. **iOS 26/27 Liquid Glass 液态玻璃交互**
   - 使用 SwiftUI 原生 `GlassEffectContainer` 与 `.glassEffect(_:in:)`，控制坞、内核切换胶囊与按钮自带折射与流体触控反馈。

---

## 在 Windows 上无 Mac 编译并装机到 iPhone 的步骤

### 第一步：上传代码到 GitHub
1. 在 GitHub 创建一个新仓库（例如 `GlassMPV`，公开或私有均可）。
2. 将本文件夹 `<项目根目录>` 的全部内容推送到该仓库的 `main` 分支：
   ```powershell
   cd <项目根目录>
   git init
   git add .
   git commit -m "init GlassMPV iOS project"
   git branch -M main
   git remote add origin https://github.com/<你的用户名>/GlassMPV.git
   git push -u origin main
   ```

### 第二步：云端免费自动编译 `.ipa`
1. 打开你的 GitHub 仓库页面，点击顶部 **Actions** 标签页。
2. 等待 **Build Unsigned iOS IPA** 工作流跑完变成绿勾（首次拉取 MPVKit 预编译依赖约需 3~6 分钟）。
3. 点进该次构建记录，在底部 **Artifacts** 下载 **`GlassMPV-unsigned-ipa`**，解压得到 `GlassMPV-unsigned.ipa`。

### 第三步：Windows 签名安装到 iPhone 15 Pro Max
1. 在 Windows 安装并打开 **[Sideloadly](https://sideloadly.io/)**（免费，官方电脑端签名工具）以及官方 Apple Devices / iTunes 驱动。
2. 用数据线连接 iPhone 15 Pro Max 并点击「信任此电脑」。
3. 将 `GlassMPV-unsigned.ipa` 拖入 Sideloadly，填入你的 Apple ID，点击 **Start** 即可自动签名安装到手机。
4. 首次安装后在手机「设置 → 通用 → VPN 与设备管理」中信任该证书即可打开（免费 Apple ID 证书有效期 7 天，到期重新点一次 Sideloadly 或搭配 AltStore 自动续签即可）。

---

## 目录结构

- `Resources/Shaders/`：从桌面版提取的 58 个 `.glsl` 超分着色器
- `Sources/Models/ShaderPreset.swift`：9 档 Anime4K 预设、单着色器列表与双核/补帧模式枚举
- `Sources/Engine/MPVPlayerCore.swift`：`libmpv` + `MoltenVK` + GLSL 管线核心
- `Sources/Engine/VTOpticalFlowEngine.swift`：`VideoToolbox` `VTFrameProcessor` 硬件光流真补帧管线
- `Sources/UI/LiquidGlassPlayerView.swift`：Liquid Glass 液态玻璃播放界面与超分控制台
- `.github/workflows/build-ios.yml`：GitHub Actions `macos-latest` 自动构建未签名 `.ipa` 脚本
- `scripts/extract_shaders.py`：从原 zip 包重新提取着色器的工具脚本
- `tests/test_project_integrity.py`：工程与资源完整性本地冒烟测试
