import Foundation

/// 补帧模式（纯 VideoToolbox ANE 硬件光流真补帧 / 原帧率硬解直通）
enum InterpolationMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case off = "关闭补帧"
    case vtOpticalFlow = "ANE 光流真补帧"

    var id: Self { self }

    var shortBadge: String {
        switch self {
        case .off: return "原帧率"
        case .vtOpticalFlow: return "光流补帧"
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

    var id: Self { self }

    var shortBadge: String { rawValue }

    var pillTitle: String {
        switch self {
        case .x2: return "2×"
        case .fps60: return "60"
        case .fps72: return "72"
        case .fps96: return "96"
        case .fps120: return "120"
        }
    }

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
