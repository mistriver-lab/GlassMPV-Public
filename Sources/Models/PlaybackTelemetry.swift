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

/// libmpv 实时属性探针快照（由 expand-properties print-text 采得）
struct MPVProbeSnapshot: Equatable, Sendable {
    let timestamp: Date
    let displaySyncActive: Bool?
    let videoSync: String
    let interpolation: Bool?
    let tscale: String
    let vsyncRatio: Double?
    let displayFPS: Double?
    let estimatedDisplayFPS: Double?
    let rawLine: String

    static func parse(from line: String, timestamp: Date = Date()) -> MPVProbeSnapshot? {
        guard let markerRange = line.range(of: "[mpv-probe]") else {
            return nil
        }
        let payload = line[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return nil }

        var fields: [String: String] = [:]
        for token in payload.split(whereSeparator: { $0.isWhitespace }) {
            let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            fields[key] = rawValue
        }

        let recognizedKeys = ["sync_active", "video_sync", "interp", "tscale", "vsync_ratio", "disp_fps", "est_disp"]
        guard recognizedKeys.contains(where: { fields[$0] != nil }) else {
            return nil
        }

        func sanitizedValue(_ key: String) -> String? {
            guard let value = fields[key],
                  !value.isEmpty,
                  !value.hasPrefix("${"),
                  !value.hasPrefix("(") else {
                return nil
            }
            return value
        }

        func parseBool(_ key: String) -> Bool? {
            guard let val = sanitizedValue(key)?.lowercased() else { return nil }
            switch val {
            case "yes", "true", "1":
                return true
            case "no", "false", "0":
                return false
            default:
                return nil
            }
        }

        func parseDouble(_ key: String, requirePositive: Bool = false) -> Double? {
            guard let str = sanitizedValue(key),
                  let val = Double(str),
                  val.isFinite else {
                return nil
            }
            if requirePositive && val <= 0 {
                return nil
            }
            return val
        }

        return MPVProbeSnapshot(
            timestamp: timestamp,
            displaySyncActive: parseBool("sync_active"),
            videoSync: sanitizedValue("video_sync") ?? "",
            interpolation: parseBool("interp"),
            tscale: sanitizedValue("tscale") ?? "",
            vsyncRatio: parseDouble("vsync_ratio"),
            displayFPS: parseDouble("disp_fps", requirePositive: true),
            estimatedDisplayFPS: parseDouble("est_disp", requirePositive: true),
            rawLine: line
        )
    }

    var summaryText: String {
        let syncStr = displaySyncActive.map { $0 ? "yes" : "no" } ?? "-"
        let interpStr = interpolation.map { $0 ? "yes" : "no" } ?? "-"
        let videoSyncStr = videoSync.isEmpty ? "-" : videoSync
        let tscaleStr = tscale.isEmpty ? "-" : tscale
        let vsyncStr = vsyncRatio.map { String(format: "%.2f", $0) } ?? "-"
        let dispStr = displayFPS.map { String(format: "%.1fHz", $0) } ?? "-"
        let estStr = estimatedDisplayFPS.map { String(format: "%.1fHz", $0) } ?? "-"
        return "sync_active=\(syncStr) video_sync=\(videoSyncStr) interp=\(interpStr) tscale=\(tscaleStr) vsync_ratio=\(vsyncStr) disp_fps=\(dispStr) est_disp=\(estStr)"
    }

    var stateSignature: String {
        let syncStr = displaySyncActive.map { $0 ? "1" : "0" } ?? "-"
        let interpStr = interpolation.map { $0 ? "1" : "0" } ?? "-"
        let vsyncStr = vsyncRatio.map { String(format: "%.1f", $0) } ?? "-"
        let dispStr = displayFPS.map { String(format: "%.1f", $0) } ?? "-"
        return "\(syncStr)|\(videoSync)|\(interpStr)|\(tscale)|\(vsyncStr)|\(dispStr)"
    }
}

/// 补帧是否真正生效的客观判定结果
enum InterpolationVerdict: Equatable, Sendable {
    case off
    case mpvActive(detail: String)
    case mpvInactive(reason: String)
    case mpvPending(detail: String)
    case aneActive(detail: String)
    case aneFailed(reason: String)
    case anePending(detail: String)

    var shortLabel: String {
        switch self {
        case .off:
            return "未开启"
        case .mpvActive:
            return "MPV补帧生效"
        case .mpvInactive:
            return "MPV补帧未生效"
        case .mpvPending:
            return "MPV等待探针"
        case .aneActive:
            return "ANE光流生效"
        case .aneFailed:
            return "ANE光流失败"
        case .anePending:
            return "ANE预热中"
        }
    }

    var detailText: String {
        switch self {
        case .off:
            return "当前为原帧率直出"
        case .mpvActive(let detail),
             .mpvInactive(let detail),
             .mpvPending(let detail),
             .aneActive(let detail),
             .aneFailed(let detail),
             .anePending(let detail):
            return detail
        }
    }

    var isEffective: Bool {
        switch self {
        case .mpvActive, .aneActive:
            return true
        case .off, .mpvInactive, .mpvPending, .aneFailed, .anePending:
            return false
        }
    }

    static func evaluateMPV(
        mode: InterpolationMode,
        probe: MPVProbeSnapshot?,
        targetDisplaySyncFPS: Double,
        reportedDisplayFPS: Double,
        measuredProMotionFPS: Double
    ) -> InterpolationVerdict {
        guard mode == .mpvSmooth120Hz else {
            return .off
        }
        if let probe {
            let syncText = probe.displaySyncActive.map { $0 ? "yes" : "no" } ?? "unknown"
            let interpText = probe.interpolation.map { $0 ? "yes" : "no" } ?? "unknown"
            let videoSyncText = probe.videoSync.isEmpty ? "unknown" : probe.videoSync
            let tscaleText = probe.tscale.isEmpty ? "unknown" : probe.tscale
            let vsyncText = probe.vsyncRatio.map { String(format: "%.2f", $0) } ?? "--"
            let dispText = probe.displayFPS.map { String(format: "%.1fHz", $0) } ?? "--"

            if probe.displaySyncActive == true && probe.interpolation == true {
                return .mpvActive(detail: "sync_active=yes, interp=yes, tscale=\(tscaleText), vsync_ratio=\(vsyncText), disp_fps=\(dispText)")
            }
            if probe.displaySyncActive == false || probe.interpolation == false {
                return .mpvInactive(reason: "sync_active=\(syncText), video_sync=\(videoSyncText), interp=\(interpText), vsync_ratio=\(vsyncText)")
            }
        }

        let targetStr = targetDisplaySyncFPS > 0 ? String(format: "%.0fHz", targetDisplaySyncFPS) : "--"
        let estStr = reportedDisplayFPS > 0 ? String(format: "%.1fHz", reportedDisplayFPS) : "--"
        let pmStr = measuredProMotionFPS > 0 ? String(format: "%.1fHz", measuredProMotionFPS) : "--"
        return .mpvPending(detail: "target=\(targetStr), est=\(estStr), ProMotion=\(pmStr), 等待探针回报")
    }

    static func evaluateANE(
        interpolatedCount: Int,
        failedCount: Int,
        presentedCount: Int,
        actualOutputFPS: Double,
        sourceFPS: Double,
        errorMessage: String?
    ) -> InterpolationVerdict {
        if interpolatedCount > 0 {
            let outText = actualOutputFPS > 0 ? String(format: "%.1f", actualOutputFPS) : "--"
            let srcText = sourceFPS > 0 ? String(format: "%.1f", sourceFPS) : "--"
            return .aneActive(detail: "已生成 \(interpolatedCount) 帧光流中间帧（送显 \(presentedCount) 帧, \(srcText)→\(outText)fps）")
        }
        if let errorMessage {
            let trimmed = errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return .aneFailed(reason: trimmed)
            }
        }
        if failedCount > 0 {
            return .aneFailed(reason: "光流补帧连续失败 \(failedCount) 次，送显 \(presentedCount) 帧")
        }
        return .anePending(detail: "等待光流首帧完成（已送显 \(presentedCount) 帧）")
    }
}

/// 运行期黑匣子周期采样快照（每 2 秒记录一次，停播不清空）
struct RuntimeTelemetrySample: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let engine: String
    let playbackState: String
    let mediaTime: Double
    let width: Int
    let height: Int
    let sourceFPS: Double
    let outputFPS: Double
    let displayFPS: Double
    let proMotionFPS: Double
    let droppedFrames: Int64
    let mistimedFrames: Int64
    let delayedFrames: Int64
    let mpvProbe: MPVProbeSnapshot?
    let aneInterpolated: Int
    let aneSkipped: Int
    let aneFailed: Int
    let anePresented: Int
    let aneAvgMs: Double
    let verdictLabel: String
    let thermalLevel: ThermalLevel

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        engine: String,
        playbackState: String,
        mediaTime: Double,
        width: Int,
        height: Int,
        sourceFPS: Double,
        outputFPS: Double,
        displayFPS: Double,
        proMotionFPS: Double,
        droppedFrames: Int64,
        mistimedFrames: Int64,
        delayedFrames: Int64,
        mpvProbe: MPVProbeSnapshot?,
        aneInterpolated: Int,
        aneSkipped: Int,
        aneFailed: Int,
        anePresented: Int,
        aneAvgMs: Double,
        verdictLabel: String,
        thermalLevel: ThermalLevel
    ) {
        self.id = id
        self.timestamp = timestamp
        self.engine = engine
        self.playbackState = playbackState
        self.mediaTime = mediaTime
        self.width = width
        self.height = height
        self.sourceFPS = sourceFPS
        self.outputFPS = outputFPS
        self.displayFPS = displayFPS
        self.proMotionFPS = proMotionFPS
        self.droppedFrames = droppedFrames
        self.mistimedFrames = mistimedFrames
        self.delayedFrames = delayedFrames
        self.mpvProbe = mpvProbe
        self.aneInterpolated = aneInterpolated
        self.aneSkipped = aneSkipped
        self.aneFailed = aneFailed
        self.anePresented = anePresented
        self.aneAvgMs = aneAvgMs
        self.verdictLabel = verdictLabel
        self.thermalLevel = thermalLevel
    }

    func formatLogLine(timeString: String? = nil) -> String {
        let resolvedTime: String
        if let timeString {
            resolvedTime = timeString
        } else {
            let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: timestamp)
            resolvedTime = String(format: "%02d:%02d:%02d", comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0)
        }

        let resText = (width > 0 && height > 0) ? "\(width)x\(height)" : "--"
        let srcText = sourceFPS > 0 ? String(format: "%.1f", sourceFPS) : "--"
        let outText = outputFPS > 0 ? String(format: "%.1f", outputFPS) : "--"
        let dispText = displayFPS > 0 ? String(format: "%.1fHz", displayFPS) : "--"
        let pmText = proMotionFPS > 0 ? String(format: "%.1fHz", proMotionFPS) : "--"
        let timeText = String(format: "%.1fs", mediaTime)
        let isANE = engine.localizedCaseInsensitiveContains("ANE") || engine.localizedCaseInsensitiveContains("光流")

        if isANE {
            let avgText = String(format: "%.1fms", aneAvgMs)
            return "[\(resolvedTime)] [ANE] \(playbackState) t=\(timeText) \(resText) fps=\(srcText)->\(outText) drop=\(droppedFrames) ane(interp=\(aneInterpolated),skip=\(aneSkipped),fail=\(aneFailed),pres=\(anePresented),avg=\(avgText)) verdict=\(verdictLabel) therm=\(thermalLevel.rawValue)"
        } else {
            let probeText: String
            if let mpvProbe {
                let s = mpvProbe.displaySyncActive.map { $0 ? "yes" : "no" } ?? "-"
                let i = mpvProbe.interpolation.map { $0 ? "yes" : "no" } ?? "-"
                let t = mpvProbe.tscale.isEmpty ? "-" : mpvProbe.tscale
                let v = mpvProbe.vsyncRatio.map { String(format: "%.2f", $0) } ?? "-"
                probeText = "probe(sync=\(s),interp=\(i),tscale=\(t),vsync=\(v))"
            } else {
                probeText = "probe(none)"
            }
            return "[\(resolvedTime)] [MPV] \(playbackState) t=\(timeText) \(resText) fps=\(srcText)->\(outText) disp=\(dispText) pm=\(pmText) drop=\(droppedFrames) mis=\(mistimedFrames) del=\(delayedFrames) \(probeText) verdict=\(verdictLabel) therm=\(thermalLevel.rawValue)"
        }
    }
}
