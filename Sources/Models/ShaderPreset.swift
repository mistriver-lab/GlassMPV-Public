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
    case vtOpticalFlow2x = "ANE 光流真补帧 (2x)"

    var id: String { rawValue }

    var shortBadge: String {
        switch self {
        case .off: return "原帧率"
        case .mpvSmooth120Hz: return "120Hz平滑"
        case .vtOpticalFlow2x: return "光流2x"
        }
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

    static let allOptions: [SingleShaderOption] = [
        SingleShaderOption(
            id: "amd_fsr",
            title: "AMD FSR",
            filename: "AMD_FSR.glsl",
            summary: "适合真人影视/写实画面的边缘自适应超分"
        ),
        SingleShaderOption(
            id: "fsrcnnx_8",
            title: "FSRCNNX x2 (8-0-4-1)",
            filename: "FSRCNNX_x2_8_0_4_1.glsl",
            summary: "轻量神经网络超分，兼顾二次元与真人"
        ),
        SingleShaderOption(
            id: "krig_bilateral",
            title: "KrigBilateral",
            filename: "KrigBilateral.glsl",
            summary: "色度上采样着色器，消除 4:2:0 彩边锯齿"
        ),
        SingleShaderOption(
            id: "nnedi3_64",
            title: "NNEDI3 (64/8x4)",
            filename: "nnedi3_nns64_win8x4.glsl",
            summary: "高精度边缘插值放大（GPU 负载较高）"
        ),
        SingleShaderOption(
            id: "ravu_zoom",
            title: "RAVU Zoom R2",
            filename: "ravu_zoom_r2.glsl",
            summary: "任意比例快速锐利放大"
        ),
        SingleShaderOption(
            id: "adaptive_sharpen",
            title: "Adaptive Sharpen",
            filename: "adaptive_sharpen.glsl",
            summary: "自适应锐化，避免过冲白边"
        )
    ]

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
