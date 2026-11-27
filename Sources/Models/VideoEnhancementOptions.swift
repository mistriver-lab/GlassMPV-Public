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
            return "专治标称 4K 但高压缩发糊老片：纯亮度保边去噪 + CAS 自适应锐化 + 去灰提透。"
        case .animeLineArt:
            return "针对动画/老番：抑制蚊噪色块并强化深色描边线条，保持纯净色彩无彩边。"
        case .lowResSuperRes:
            return "针对 480p/720p/1080p 低清视频与高帧率 720p 光流帧：MetalFX 感知重建 + 锐度收尾。"
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
        case .subtle: return 0.65
        case .standard: return 1.0
        case .strong: return 1.35
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
}

/// 跨平台画质增强参数与超分尺寸规划器
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
                wantsSpatialUpscale: false
            )
        case .old4KRestore:
            return VideoEnhancementParameters(
                denoiseStrength: min(0.85, max(0, 0.42 * m)),
                denoiseThreshold: 0.038,
                casStrength: min(1.0, max(0, 0.72 * m)),
                lineDarken: 0.0,
                clarityStrength: min(0.32, max(0, 0.14 * m)),
                wantsSpatialUpscale: false
            )
        case .animeLineArt:
            return VideoEnhancementParameters(
                denoiseStrength: min(0.90, max(0, 0.60 * m)),
                denoiseThreshold: 0.055,
                casStrength: min(1.0, max(0, 0.85 * m)),
                lineDarken: min(0.30, max(0, 0.16 * m)),
                clarityStrength: min(0.25, max(0, 0.10 * m)),
                wantsSpatialUpscale: false
            )
        case .lowResSuperRes:
            return VideoEnhancementParameters(
                denoiseStrength: min(0.75, max(0, 0.35 * m)),
                denoiseThreshold: 0.042,
                casStrength: min(0.95, max(0, 0.55 * m)),
                lineDarken: 0.0,
                clarityStrength: min(0.24, max(0, 0.10 * m)),
                wantsSpatialUpscale: true
            )
        }
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
