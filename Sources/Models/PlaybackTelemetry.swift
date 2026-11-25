import Foundation

/// 设备热状态分级（映射 ProcessInfo.ThermalState）
enum ThermalLevel: String, Equatable, Sendable {
    case nominal = "正常"
    case fair = "温热"
    case serious = "过热"
    case critical = "严重过热"

    init(state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal:
            self = .nominal
        case .fair:
            self = .fair
        case .serious:
            self = .serious
        case .critical:
            self = .critical
        @unknown default:
            self = .nominal
        }
    }
}

/// MPV 风格常驻关键信息 HUD 汇总模型（未开启补帧时亦可实时读取完整播放参数）
struct PlaybackHUDMetrics: Equatable, Sendable {
    let engineBadge: String
    let interpolationBadge: String
    let codec: String
    let width: Int
    let height: Int
    let sourceFPS: Double
    let outputFPS: Double
    let displayFPS: Double
    let bitDepth: String
    let hdrTag: String
    let isHDRActive: Bool
    let decoderBadge: String
    let droppedFrames: Int64
    let activeShaderCount: Int
    let thermalLevel: ThermalLevel

    var videoStreamSummary: String {
        let codecText = Self.formatCodecName(codec)
        let resText = (width > 0 && height > 0) ? "\(width)×\(height)" : "--×--"
        var parts = [codecText, resText]
        var colorParts: [String] = []
        if !bitDepth.isEmpty && bitDepth != "--" {
            colorParts.append(bitDepth)
        }
        if !hdrTag.isEmpty {
            colorParts.append(hdrTag)
        }
        if !colorParts.isEmpty {
            parts.append(colorParts.joined(separator: " "))
        }
        return parts.joined(separator: " · ")
    }

    var fpsSummary: String {
        let srcText = Self.formatSourceFPS(sourceFPS)
        let effectiveOut = outputFPS > 0 ? outputFPS : sourceFPS
        let outText = Self.formatOutputFPS(effectiveOut)
        if displayFPS > 0, displayFPS.isFinite {
            return "\(srcText) → \(outText) fps · \(Int(displayFPS.rounded()))Hz"
        }
        return "\(srcText) → \(outText) fps"
    }

    var pipelineSummary: String {
        var parts = [decoderBadge, interpolationBadge]
        if activeShaderCount > 0 {
            parts.append("\(activeShaderCount)着色器")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Formatting & Parsing Helpers

    static func formatCodecName(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return "--" }

        switch normalized {
        case "hevc", "h265", "h.265", "hvc1", "hev1":
            return "HEVC"
        case "dvh1", "dvhe":
            return "HEVC (DV)"
        case "h264", "h.264", "avc1", "avc3":
            return "H.264"
        case "av1", "av01":
            return "AV1"
        case "vp9", "vp09":
            return "VP9"
        case "vp8", "vp08":
            return "VP8"
        case "prores", "apch", "apcn", "apcs", "apco", "ap4h", "ap4x":
            return "ProRes"
        case "mpeg4", "mp4v":
            return "MPEG-4"
        default:
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
    }

    static func parseBitDepth(fromPixelFormat raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return "--" }

        // 先匹配明确的 8-bit 格式（避免 nv12 误匹配 12-bit）
        let eightBitTokens = ["nv12", "nv21", "420v", "420f", "yuv420p8", "yuv422p8", "yuv444p8", "bgra", "rgba", "argb", "8bit"]
        if eightBitTokens.contains(where: { lower.contains($0) })
            || lower == "yuv420p"
            || lower == "yuv422p"
            || lower == "yuv444p"
            || lower.hasSuffix("p8") {
            return "8-bit"
        }

        let tenBitTokens = ["p010", "p210", "p410", "x420", "xf20", "p10", "10le", "10be", "10bit", "rgb10"]
        if tenBitTokens.contains(where: { lower.contains($0) }) || lower.contains("10") {
            return "10-bit"
        }

        let twelveBitTokens = ["p012", "p212", "p412", "p12", "12le", "12be", "12bit"]
        if twelveBitTokens.contains(where: { lower.contains($0) }) {
            return "12-bit"
        }

        let sixteenBitTokens = ["p016", "p216", "p416", "p16", "16le", "16be", "16bit", "ayuv64"]
        if sixteenBitTokens.contains(where: { lower.contains($0) }) {
            return "16-bit"
        }

        return "--"
    }

    static func formatHDRTag(isHDRContent: Bool, transferName: String?, isHDRActive: Bool) -> String {
        let lower = (transferName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let baseTag: String
        if lower.contains("pq") || lower.contains("2084") {
            baseTag = "HDR10"
        } else if lower.contains("hlg") || lower.contains("b67") {
            baseTag = "HLG"
        } else if isHDRContent {
            baseTag = "HDR"
        } else {
            return "SDR"
        }

        return isHDRActive ? "\(baseTag)✓" : baseTag
    }

    static func formatDecoderBadge(hardwareDecoder: String) -> String {
        let trimmed = hardwareDecoder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "--" }

        let lower = trimmed.lowercased()
        if lower == "software" || lower == "no" || lower == "sw" {
            return "软解"
        }
        if lower.contains("videotoolbox") {
            return "硬解 VT"
        }
        if lower.contains("ane") {
            return "硬解 ANE"
        }
        return "硬解 \(trimmed)"
    }

    static func formatSourceFPS(_ fps: Double) -> String {
        guard fps > 0, fps.isFinite else { return "--" }
        let roundedOneDecimal = (fps * 10.0).rounded() / 10.0
        if abs(fps - roundedOneDecimal) < 0.005 {
            return String(format: "%.1f", fps)
        }
        return String(format: "%.2f", fps)
    }

    static func formatOutputFPS(_ fps: Double) -> String {
        guard fps > 0, fps.isFinite else { return "--" }
        return String(format: "%.1f", fps)
    }
}

/// 4K 超分自适应门控策略：片源已达 4K（3840×2160 或更高）时自动禁用超分，避免无效开销与过热降频
enum SuperResolutionPolicy: Sendable {
    static func isAlready4K(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let longSide = max(width, height)
        let shortSide = min(width, height)
        return longSide >= 3840 || shortSide >= 2160
    }

    static func disabledReason(width: Int, height: Int) -> String? {
        guard isAlready4K(width: width, height: height) else { return nil }
        return "片源已达 4K（\(width)×\(height)），自动禁用超分以节省算力与功耗"
    }
}
