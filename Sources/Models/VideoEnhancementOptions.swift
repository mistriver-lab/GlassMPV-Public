import Foundation

/// 实时画质增强预设（纯系统 Metal + MetalFX 零依赖管线）
enum VideoEnhancementPreset: String, CaseIterable, Identifiable, Hashable, Sendable {
    case off = "原画"
    case old4KRestore = "老片去糊"
    case animeLineArt = "动漫强化"
    case lowResSuperRes = "低清超分"

    var id: Self { self }

    var shortBadge: String {
        switch self {
        case .off: return "画质"
        case .old4KRestore: return "去糊"
        case .animeLineArt: return "动漫"
        case .lowResSuperRes: return "超分"
        }
    }

    var subtitle: String {
        switch self {
        case .off: return "关闭增强"
        case .old4KRestore: return "假4K修复"
        case .animeLineArt: return "线条锐利"
        case .lowResSuperRes: return "MetalFX重建"
        }
    }

    var iconName: String {
        switch self {
        case .off: return "camera.filters"
        case .old4KRestore: return "sparkles.tv"
        case .animeLineArt: return "pencil.and.outline"
        case .lowResSuperRes: return "arrow.up.left.and.arrow.down.right"
        }
    }

    var detailDescription: String {
        switch self {
        case .off:
            return "不额外修改像素，原片直通输出。"
        case .old4KRestore:
            return "专治标称 4K 但高压缩发糊老片：多尺度纯亮度去糊 + 防光晕 CAS 锐化 + 去灰提透。"
        case .animeLineArt:
            return "针对动画/老番：抑制蚊噪浮尘并压实深色描边线条，保持纯净色彩无彩边。"
        case .lowResSuperRes:
            return "针对 480p/720p/1080p 低清视频与光流帧：MetalFX 感知重建 + 多尺度锐度收尾（高刷/高温自动切省电直锐）。"
        }
    }
}

/// 画质增强强度档位
enum VideoEnhancementStrength: String, CaseIterable, Identifiable, Hashable, Sendable {
    case subtle = "轻度"
    case standard = "标准"
    case strong = "强力"

    var id: Self { self }

    var multiplier: Float {
        switch self {
        case .subtle: return 0.70
        case .standard: return 1.0
        case .strong: return 1.35
        }
    }
}

/// 画质对比模式（兼容播放中与暂停状态即时刷新）
enum VideoEnhancementCompareMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case off = "增强效果"
    case split = "分屏对比"
    case original = "全屏原画"

    var id: Self { self }

    var uniformValue: UInt32 {
        switch self {
        case .off: return 0
        case .split: return 1
        case .original: return 2
        }
    }
}

/// 传递给 Metal 着色器的归一化画质参数
struct VideoEnhancementParameters: Equatable, Sendable {
    let denoiseStrength: Float
    let denoiseThreshold: Float
    let casStrength: Float
    let lineDarken: Float
    let clarityStrength: Float
    let wantsSpatialUpscale: Bool
    let deblurStrength: Float
    let noiseDeadzone: Float

    init(
        denoiseStrength: Float,
        denoiseThreshold: Float,
        casStrength: Float,
        lineDarken: Float,
        clarityStrength: Float,
        wantsSpatialUpscale: Bool,
        deblurStrength: Float = 0,
        noiseDeadzone: Float = 0.012
    ) {
        self.denoiseStrength = denoiseStrength
        self.denoiseThreshold = denoiseThreshold
        self.casStrength = casStrength
        self.lineDarken = lineDarken
        self.clarityStrength = clarityStrength
        self.wantsSpatialUpscale = wantsSpatialUpscale
        self.deblurStrength = deblurStrength
        self.noiseDeadzone = noiseDeadzone
    }
}

/// 跨平台画质增强参数与超分热功耗预算规划器
enum VideoEnhancementPlanner: Sendable {
    static func parameters(
        for preset: VideoEnhancementPreset,
        strength: VideoEnhancementStrength
    ) -> VideoEnhancementParameters {
        let m = strength.multiplier
        switch preset {
        case .off:
            return VideoEnhancementParameters(
                denoiseStrength: 0,
                denoiseThreshold: 0,
                casStrength: 0,
                lineDarken: 0,
                clarityStrength: 0,
                wantsSpatialUpscale: false,
                deblurStrength: 0,
                noiseDeadzone: 0
            )
        case .old4KRestore:
            return VideoEnhancementParameters(
                denoiseStrength: 0,
                denoiseThreshold: 0.032,
                casStrength: min(1.0, max(0, 0.88 * m)),
                lineDarken: min(0.18, max(0, 0.08 * m)),
                clarityStrength: min(0.45, max(0, 0.24 * m)),
                wantsSpatialUpscale: false,
                deblurStrength: min(1.35, max(0, 0.72 * m)),
                noiseDeadzone: 0.012
            )
        case .animeLineArt:
            return VideoEnhancementParameters(
                denoiseStrength: 0,
                denoiseThreshold: 0.045,
                casStrength: min(1.0, max(0, 0.92 * m)),
                lineDarken: min(0.75, max(0, 0.45 * m)),
                clarityStrength: min(0.38, max(0, 0.18 * m)),
                wantsSpatialUpscale: false,
                deblurStrength: min(1.15, max(0, 0.58 * m)),
                noiseDeadzone: 0.020
            )
        case .lowResSuperRes:
            return VideoEnhancementParameters(
                denoiseStrength: 0,
                denoiseThreshold: 0.036,
                casStrength: min(1.0, max(0, 0.85 * m)),
                lineDarken: min(0.22, max(0, 0.10 * m)),
                clarityStrength: min(0.35, max(0, 0.18 * m)),
                wantsSpatialUpscale: true,
                deblurStrength: min(1.15, max(0, 0.60 * m)),
                noiseDeadzone: 0.014
            )
        }
    }

    /// 按输出帧率与热状态限制 MetalFX 空间超分输出规模，避免 96/120fps 或高温下过热掉帧
    static func effectiveUpscaleBudget(
        outputFPS: Double,
        thermalState: ProcessInfo.ThermalState
    ) -> (allowSpatialUpscale: Bool, maxLongSide: Int, maxShortSide: Int) {
        if thermalState == .serious || thermalState == .critical || outputFPS > 65.0 {
            return (allowSpatialUpscale: false, maxLongSide: 0, maxShortSide: 0)
        }
        if thermalState == .fair || outputFPS > 35.0 {
            return (allowSpatialUpscale: true, maxLongSide: 1920, maxShortSide: 1080)
        }
        return (allowSpatialUpscale: true, maxLongSide: 2560, maxShortSide: 1440)
    }

    static func recommendedUpscaleDimensions(
        inputWidth: Int,
        inputHeight: Int,
        maxLongSide: Int = 2560,
        maxShortSide: Int = 1440
    ) -> (width: Int, height: Int)? {
        guard inputWidth >= 64, inputHeight >= 64 else { return nil }
        if max(inputWidth, inputHeight) >= maxLongSide || min(inputWidth, inputHeight) >= maxShortSide {
            return nil
        }

        let isLandscape = inputWidth >= inputHeight
        let capW = isLandscape ? maxLongSide : maxShortSide
        let capH = isLandscape ? maxShortSide : maxLongSide
        let targetScale = min(
            2.0,
            min(Double(capW) / Double(inputWidth), Double(capH) / Double(inputHeight))
        )
        guard targetScale >= 1.15 else { return nil }

        let rawW = Int(floor(Double(inputWidth) * targetScale))
        let rawH = Int(floor(Double(inputHeight) * targetScale))
        let outW = max(64, rawW - (rawW % 2))
        let outH = max(64, rawH - (rawH % 2))
        guard outW > inputWidth && outH > inputHeight else { return nil }
        return (outW, outH)
    }

    static func shouldBypassForDolbyVision(isDolbyVision: Bool) -> Bool {
        isDolbyVision
    }
}
