import Foundation

/// 双核播放引擎模式
enum PlayerEngineMode: String, CaseIterable, Identifiable, Sendable {
    case mpv = "MPV 超分核"
    case opticalFlow = "ANE 光流核"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .mpv:
            return "全格式 · 58个GLSL超分 · 120Hz时域平滑"
        case .opticalFlow:
            return "MP4/MOV · VideoToolbox 硬件光流真补帧"
        }
    }
}

/// 补帧模式
enum InterpolationMode: String, CaseIterable, Identifiable, Sendable {
    case off = "关闭补帧"
    case mpvSmooth120Hz = "MPV 时域平滑 (120Hz)"
    case vtOpticalFlow2x = "ANE 光流真补帧 (多档位)"

    var id: String { rawValue }

    var shortBadge: String {
        switch self {
        case .off: return "原帧率"
        case .mpvSmooth120Hz: return "120Hz平滑"
        case .vtOpticalFlow2x: return "光流2x"
        }
    }
}

/// ANE 光流真补帧目标帧率档位
enum OpticalFlowTargetFPS: String, CaseIterable, Identifiable, Hashable, Sendable {
    case x2 = "2×"
    case fps60 = "60fps"
    case fps72 = "72fps"
    case fps96 = "96fps"
    case fps120 = "120fps"

    var id: String { rawValue }

    var shortBadge: String { rawValue }

    var targetFPSValue: Double? {
        switch self {
        case .x2: return nil
        case .fps60: return 60.0
        case .fps72: return 72.0
        case .fps96: return 96.0
        case .fps120: return 120.0
        }
    }

    /// VideoToolbox 空间 2× 超分仅支持 2× 单相 [0.5]
    var allowsSpatial2x: Bool {
        self == .x2
    }

    var nextLowerTier: OpticalFlowTargetFPS? {
        switch self {
        case .fps120: return .fps96
        case .fps96: return .fps72
        case .fps72: return .fps60
        case .fps60: return .x2
        case .x2: return nil
        }
    }

    func effectiveTargetFPS(sourceFPS: Double) -> Double {
        let safeSrc = (sourceFPS.isFinite && sourceFPS > 1.0) ? sourceFPS : 24.0
        guard let fixed = targetFPSValue else {
            return safeSrc * 2.0
        }
        return max(safeSrc, fixed)
    }

    func isPowerOfTwoMultiplier(sourceFPS: Double) -> Bool {
        if self == .x2 {
            return true
        }
        let safeSrc = (sourceFPS.isFinite && sourceFPS > 1.0) ? sourceFPS : 24.0
        let ratio = effectiveTargetFPS(sourceFPS: safeSrc) / safeSrc
        return abs(ratio - 2.0) <= 0.04 || abs(ratio - 4.0) <= 0.04
    }

    func maxInterpolatedFramesPerPair(sourceFPS: Double) -> Int {
        if self == .x2 {
            return 1
        }
        let safeSrc = (sourceFPS.isFinite && sourceFPS > 1.0) ? sourceFPS : 24.0
        let ratio = effectiveTargetFPS(sourceFPS: safeSrc) / safeSrc
        if ratio <= 1.05 {
            return 0
        }
        let nearest = Int(ratio.rounded())
        if nearest >= 2 && abs(ratio - Double(nearest)) <= 0.03 {
            return min(8, max(1, nearest - 1))
        }
        return min(8, max(1, Int(ceil(ratio))))
    }
}

/// 负载级别提示
enum ShaderLoadTier: String, Sendable {
    case none = "原画"
    case fast = "FAST · 推荐"
    case hq = "HQ · 高负载"
}

/// 映射自原包 input.conf 的着色器组合预设
struct ShaderPreset: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let tier: ShaderLoadTier
    let shaderFiles: [String]

    static let off = ShaderPreset(
        id: "off",
        title: "关闭超分",
        detail: "原始画面输出，功耗最低",
        tier: .none,
        shaderFiles: []
    )

    static let allPresets: [ShaderPreset] = [
        .off,
        ShaderPreset(
            id: "a4k_mode_a_fast",
            title: "Anime4K Mode A (FAST)",
            detail: "经典清晰恢复 + 2x CNN 放大（低画质片源首选）",
            tier: .fast,
            shaderFiles: [
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Restore_CNN_M.glsl",
                "Anime4K_Upscale_CNN_x2_M.glsl",
                "Anime4K_AutoDownscalePre_x2.glsl",
                "Anime4K_AutoDownscalePre_x4.glsl",
                "Anime4K_Upscale_CNN_x2_S.glsl"
            ]
        ),
        ShaderPreset(
            id: "a4k_mode_b_fast",
            title: "Anime4K Mode B (FAST)",
            detail: "柔和线条恢复 + 2x CNN 放大（适合720p/1080p）",
            tier: .fast,
            shaderFiles: [
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Restore_CNN_Soft_M.glsl",
                "Anime4K_Upscale_CNN_x2_M.glsl",
                "Anime4K_AutoDownscalePre_x2.glsl",
                "Anime4K_AutoDownscalePre_x4.glsl",
                "Anime4K_Upscale_CNN_x2_S.glsl"
            ]
        ),
        ShaderPreset(
            id: "a4k_mode_c_fast",
            title: "Anime4K Mode C (FAST)",
            detail: "降噪 + 2x CNN 放大（高压缩/噪点片源）",
            tier: .fast,
            shaderFiles: [
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Upscale_Denoise_CNN_x2_M.glsl",
                "Anime4K_AutoDownscalePre_x2.glsl",
                "Anime4K_AutoDownscalePre_x4.glsl",
                "Anime4K_Upscale_CNN_x2_S.glsl"
            ]
        ),
        ShaderPreset(
            id: "a4k_mode_aa_fast",
            title: "Anime4K Mode A+A (FAST)",
            detail: "双级线条重建，二次元强锐化观感",
            tier: .fast,
            shaderFiles: [
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Restore_CNN_M.glsl",
                "Anime4K_Upscale_CNN_x2_M.glsl",
                "Anime4K_Restore_CNN_S.glsl",
                "Anime4K_AutoDownscalePre_x2.glsl",
                "Anime4K_AutoDownscalePre_x4.glsl",
                "Anime4K_Upscale_CNN_x2_S.glsl"
            ]
        ),
        ShaderPreset(
            id: "a4k_mode_bb_fast",
            title: "Anime4K Mode B+B (FAST)",
            detail: "双级柔和重建，减少振铃伪影",
            tier: .fast,
            shaderFiles: [
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Restore_CNN_Soft_M.glsl",
                "Anime4K_Upscale_CNN_x2_M.glsl",
                "Anime4K_AutoDownscalePre_x2.glsl",
                "Anime4K_AutoDownscalePre_x4.glsl",
                "Anime4K_Restore_CNN_Soft_S.glsl",
                "Anime4K_Upscale_CNN_x2_S.glsl"
            ]
        ),
        ShaderPreset(
            id: "a4k_mode_ca_fast",
            title: "Anime4K Mode C+A (FAST)",
            detail: "降噪放大后再做二次线条强化",
            tier: .fast,
            shaderFiles: [
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Upscale_Denoise_CNN_x2_M.glsl",
                "Anime4K_AutoDownscalePre_x2.glsl",
                "Anime4K_AutoDownscalePre_x4.glsl",
                "Anime4K_Restore_CNN_S.glsl",
                "Anime4K_Upscale_CNN_x2_S.glsl"
            ]
        ),
        ShaderPreset(
            id: "a4k_mode_aa_hq",
            title: "Anime4K Mode A+A (HQ)",
            detail: "VL 超大模型双级重建（高负载，注意发热）",
            tier: .hq,
            shaderFiles: [
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Restore_CNN_VL.glsl",
                "Anime4K_Upscale_CNN_x2_VL.glsl",
                "Anime4K_Restore_CNN_M.glsl",
                "Anime4K_AutoDownscalePre_x2.glsl",
                "Anime4K_AutoDownscalePre_x4.glsl",
                "Anime4K_Upscale_CNN_x2_M.glsl"
            ]
        ),
        ShaderPreset(
            id: "a4k_mode_bb_hq",
            title: "Anime4K Mode B+B (HQ)",
            detail: "VL 超大模型柔和双级重建（高负载）",
            tier: .hq,
            shaderFiles: [
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Restore_CNN_Soft_VL.glsl",
                "Anime4K_Upscale_CNN_x2_VL.glsl",
                "Anime4K_AutoDownscalePre_x2.glsl",
                "Anime4K_AutoDownscalePre_x4.glsl",
                "Anime4K_Restore_CNN_Soft_M.glsl",
                "Anime4K_Upscale_CNN_x2_M.glsl"
            ]
        ),
        ShaderPreset(
            id: "a4k_mode_ca_hq",
            title: "Anime4K Mode C+A (HQ)",
            detail: "VL 超大模型降噪放大 + M 级线条强化",
            tier: .hq,
            shaderFiles: [
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Upscale_Denoise_CNN_x2_VL.glsl",
                "Anime4K_AutoDownscalePre_x2.glsl",
                "Anime4K_AutoDownscalePre_x4.glsl",
                "Anime4K_Restore_CNN_M.glsl",
                "Anime4K_Upscale_CNN_x2_M.glsl"
            ]
        )
    ]
}

/// 可单独叠加的经典着色器（映射自原包 input.conf 单项开关）
struct SingleShaderOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let filename: String
    let summary: String
    let isUpscaler: Bool

    static let allOptions: [SingleShaderOption] = [
        SingleShaderOption(
            id: "amd_fsr",
            title: "AMD FSR",
            filename: "AMD_FSR.glsl",
            summary: "适合真人影视/写实画面的边缘自适应超分",
            isUpscaler: true
        ),
        SingleShaderOption(
            id: "fsrcnnx_8",
            title: "FSRCNNX x2 (8-0-4-1)",
            filename: "FSRCNNX_x2_8_0_4_1.glsl",
            summary: "轻量神经网络超分，兼顾二次元与真人",
            isUpscaler: true
        ),
        SingleShaderOption(
            id: "krig_bilateral",
            title: "KrigBilateral",
            filename: "KrigBilateral.glsl",
            summary: "色度上采样着色器，消除 4:2:0 彩边锯齿（4K可用）",
            isUpscaler: false
        ),
        SingleShaderOption(
            id: "nnedi3_64",
            title: "NNEDI3 (64/8x4)",
            filename: "nnedi3_nns64_win8x4.glsl",
            summary: "高精度边缘插值放大（GPU 负载较高）",
            isUpscaler: true
        ),
        SingleShaderOption(
            id: "ravu_zoom",
            title: "RAVU Zoom R2",
            filename: "ravu_zoom_r2.glsl",
            summary: "任意比例快速锐利放大",
            isUpscaler: true
        ),
        SingleShaderOption(
            id: "adaptive_sharpen",
            title: "Adaptive Sharpen",
            filename: "adaptive_sharpen.glsl",
            summary: "自适应锐化，避免过冲白边（4K可用）",
            isUpscaler: false
        )
    ]

    static func isUpscalerOption(id: String) -> Bool {
        allOptions.first(where: { $0.id == id })?.isUpscaler ?? true
    }

    static func filteredFor4K(preset: ShaderPreset, extras: Set<String>) -> (preset: ShaderPreset, extras: Set<String>) {
        let allowedExtras = extras.filter { !isUpscalerOption(id: $0) }
        return (.off, allowedExtras)
    }

    /// 将选中着色器文件名解析为 Bundle 内真实物理路径，按 Unix 冒号分隔拼接给 mpv
    static func resolvedShaderPaths(preset: ShaderPreset, extras: Set<String>) -> [String] {
        guard let shaderFolder = Bundle.main.resourceURL?.appendingPathComponent("Shaders", isDirectory: true) else {
            return []
        }
        var orderedNames = preset.shaderFiles
        for opt in allOptions where extras.contains(opt.id) {
            if !orderedNames.contains(opt.filename) {
                orderedNames.append(opt.filename)
            }
        }
        return orderedNames.compactMap { name in
            let fileURL = shaderFolder.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL.path : nil
        }
    }
}
