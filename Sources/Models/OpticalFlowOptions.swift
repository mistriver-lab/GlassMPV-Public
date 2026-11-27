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
    case fps96 = "96fps"
    case fps120 = "120fps"

    var id: Self { self }

    var shortBadge: String { rawValue }

    var pillTitle: String {
        switch self {
        case .x2: return "2×"
        case .fps60: return "60"
        case .fps96: return "96"
        case .fps120: return "120"
        }
    }

    var targetFPSValue: Double? {
        switch self {
        case .x2: return nil
        case .fps60: return 60.0
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
        case .fps96: return .fps60
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

    static func smartPresets(forSourceFPS sourceFPS: Double) -> [FrameRatePresetItem] {
        let safeSrc = (sourceFPS.isFinite && sourceFPS > 1.0) ? sourceFPS : 24.0
        let srcInt = max(1, Int(safeSrc.rounded()))
        var items: [FrameRatePresetItem] = [
            FrameRatePresetItem(target: nil, primaryTitle: "原画", subtitle: "\(srcInt)p 直通")
        ]

        if safeSrc < 27.0 {
            let x2FPS = Int((safeSrc * 2.0).rounded())
            items.append(FrameRatePresetItem(target: .x2, primaryTitle: "\(x2FPS) fps", subtitle: "2× 清晰省电"))
            items.append(FrameRatePresetItem(target: .fps60, primaryTitle: "60 fps", subtitle: "均衡流畅"))
            items.append(FrameRatePresetItem(target: .fps96, primaryTitle: "96 fps", subtitle: "4× 高刷甜点"))
            items.append(FrameRatePresetItem(target: .fps120, primaryTitle: "120 fps", subtitle: "120Hz 满血"))
        } else if safeSrc < 45.0 {
            let x2FPS = Int((safeSrc * 2.0).rounded())
            items.append(FrameRatePresetItem(target: .x2, primaryTitle: "\(x2FPS) fps", subtitle: "2× 清晰省电"))
            items.append(FrameRatePresetItem(target: .fps120, primaryTitle: "120 fps", subtitle: "4× 满血"))
        } else {
            items.append(FrameRatePresetItem(target: .fps120, primaryTitle: "120 fps", subtitle: "2× 满血"))
        }
        return items
    }

    static func activeCapsuleSummary(
        isOff: Bool,
        requested: OpticalFlowTargetFPS,
        effective: OpticalFlowTargetFPS,
        sourceFPS: Double,
        spatial2x: Bool
    ) -> (title: String, subtitle: String) {
        let safeSrc = (sourceFPS.isFinite && sourceFPS > 1.0) ? sourceFPS : 24.0
        let srcInt = max(1, Int(safeSrc.rounded()))
        guard !isOff else {
            return (title: "原画", subtitle: "\(srcInt)p")
        }
        if effective != requested {
            let effFPS = Int(effective.effectiveTargetFPS(sourceFPS: safeSrc).rounded())
            return (title: "\(requested.pillTitle)→\(effFPS)", subtitle: "自动稳帧")
        }
        let targetInt = Int(effective.effectiveTargetFPS(sourceFPS: safeSrc).rounded())
        let subtitle: String
        switch effective {
        case .x2:
            subtitle = spatial2x ? "2×+超分" : "2× 清晰"
        case .fps60:
            subtitle = "均衡流畅"
        case .fps96:
            subtitle = "高刷甜点"
        case .fps120:
            subtitle = "120Hz"
        }
        return (title: "\(targetInt) fps", subtitle: subtitle)
    }
}

/// 基于片源原生帧率生成的智能帧率选项
struct FrameRatePresetItem: Identifiable, Equatable, Sendable {
    let target: OpticalFlowTargetFPS?
    let primaryTitle: String
    let subtitle: String

    var id: String {
        target?.rawValue ?? "off"
    }
}
