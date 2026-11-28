import Darwin
import Foundation

/// 运行期硬件型号、系统版本与内存占用采样器（Swift 6 并发安全）
enum DeviceDiagnosticsSampler: Sendable {
    static func currentMemoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / (1024.0 * 1024.0)
    }

    static func deviceHardwareModel() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let count = MemoryLayout.size(ofValue: sysinfo.machine)
        return withUnsafeBytes(of: &sysinfo.machine) { rawBuffer in
            let bytes = rawBuffer.prefix(count).prefix { $0 != 0 }
            let model = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? "Unknown" : model
        }
    }

    static func deviceSummaryLine(maxScreenFPS: Int? = nil) -> String {
        let model = deviceHardwareModel()
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let cores = ProcessInfo.processInfo.processorCount
        let totalRAMGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024.0 * 1024.0 * 1024.0)
        let memMB = currentMemoryFootprintMB()
        var parts = [
            model,
            osVersion,
            "\(cores) Cores",
            String(format: "RAM=%.1fGB", totalRAMGB),
            String(format: "AppMem=%.1fMB", memMB)
        ]
        if let maxScreenFPS, maxScreenFPS > 0 {
            parts.append("ScreenMax=\(maxScreenFPS)Hz")
        }
        return parts.joined(separator: " | ")
    }
}

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

/// 常驻关键信息 HUD 汇总模型（未开启补帧时亦可实时读取完整播放参数）
struct PlaybackHUDMetrics: Equatable, Sendable {
    let engineBadge: String
    let interpolationBadge: String
    let codec: String
    let width: Int
    let height: Int
    let sourceFPS: Double
    let outputFPS: Double
    let bitDepth: String
    let hdrTag: String
    let isHDRActive: Bool
    let decoderBadge: String
    let droppedFrames: Int64
    let thermalLevel: ThermalLevel
    var resolutionModeBadge: String = ""
    var flowAvgMs: Double = 0
    var renderAvgMs: Double = 0
    var queueDepth: Int = 0
    var memoryMB: Double = 0
    var isStalled: Bool = false

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
        if isStalled {
            return "\(srcText) → 缓冲中"
        }
        let effectiveOut = outputFPS > 0 ? outputFPS : sourceFPS
        let outText = Self.formatOutputFPS(effectiveOut)
        return "\(srcText) → \(outText) fps"
    }

    var pipelineSummary: String {
        [decoderBadge, interpolationBadge].joined(separator: " · ")
    }

    var performanceSummary: String {
        var parts: [String] = []
        if flowAvgMs > 0.05 {
            parts.append(String(format: "光流 %.1fms", flowAvgMs))
        }
        if renderAvgMs > 0.05 {
            parts.append(String(format: "渲染 %.1fms", renderAvgMs))
        }
        if engineBadge != "PASS" {
            parts.append("队列 \(queueDepth)")
        }
        if memoryMB > 1.0 {
            parts.append(String(format: "%.0fMB", memoryMB))
        }
        return parts.joined(separator: " · ")
    }

    static func resolveEngineBadge(isInterpolationEnabled: Bool, backendLabel: String) -> String {
        guard isInterpolationEnabled else { return "PASS" }
        let lower = backendLabel.lowercased()
        if lower.contains("gpu") {
            return "GPU"
        }
        return "ANE"
    }

    static func resolveResolutionModeBadge(isInterpolationEnabled: Bool, backendLabel: String) -> String {
        guard isInterpolationEnabled else { return "原画直通" }
        let lower = backendLabel.lowercased()
        if lower.contains("gpu") {
            return "原画直采"
        }
        if lower.contains("metalfx") || lower.contains("lowlatency") {
            return "降采样→MetalFX"
        }
        return "原画输出"
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
        case "dav1":
            return "AV1 (DV)"
        case "dva1", "dvav":
            return "H.264 (DV)"
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

    static func formatHDRTag(
        isHDRContent: Bool,
        transferName: String?,
        isHDRActive: Bool,
        isDolbyVision: Bool = false
    ) -> String {
        let lower = (transferName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let baseTag: String
        if isDolbyVision || lower.contains("dolby") || lower.contains("dovi") || lower.contains("ipt") {
            baseTag = "杜比视界"
        } else if lower.contains("pq") || lower.contains("2084") {
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
        return "片源已达 4K（\(width)×\(height)），自动禁用 ANE 2× 空间超分，仅保留光流补帧"
    }
}

/// 停播返回主界面前缓存的会话诊断摘要，防止导出报告关键指标归零
struct SessionDiagnosticSummary: Equatable, Sendable {
    let capturedAt: Date
    let engineName: String
    let playbackState: String
    let resolution: String
    let fpsSummary: String
    let decoderSummary: String
    let is4KGated: Bool
    let telemetrySummary: [String]
    let mediaFilename: String
}

/// 补帧是否真正生效的客观判定结果
enum InterpolationVerdict: Equatable, Sendable {
    case off
    case aneActive(detail: String)
    case aneFailed(reason: String)
    case anePending(detail: String)

    var shortLabel: String {
        switch self {
        case .off:
            return "未开启"
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
            return "当前为原帧率硬解直通"
        case .aneActive(let detail),
             .aneFailed(let detail),
             .anePending(let detail):
            return detail
        }
    }

    var isEffective: Bool {
        if case .aneActive = self {
            return true
        }
        return false
    }

    static func evaluateANE(
        isEnabled: Bool = true,
        interpolatedCount: Int,
        failedCount: Int,
        presentedCount: Int,
        actualOutputFPS: Double,
        sourceFPS: Double,
        errorMessage: String?,
        targetLabel: String? = nil
    ) -> InterpolationVerdict {
        guard isEnabled else {
            return .off
        }
        if interpolatedCount > 0 {
            let outText = actualOutputFPS > 0 ? String(format: "%.1f", actualOutputFPS) : "--"
            let srcText = sourceFPS > 0 ? String(format: "%.1f", sourceFPS) : "--"
            let targetSuffix: String
            if let targetLabel, !targetLabel.isEmpty {
                targetSuffix = ", 目标 \(targetLabel)"
            } else {
                targetSuffix = ""
            }
            return .aneActive(detail: "已生成 \(interpolatedCount) 帧光流中间帧（送显 \(presentedCount) 帧, \(srcText)→\(outText)fps\(targetSuffix)）")
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
    let playbackState: String
    let mediaTime: Double
    let width: Int
    let height: Int
    let sourceFPS: Double
    let outputFPS: Double
    let droppedFrames: Int64
    let aneInterpolated: Int
    let aneSkipped: Int
    let aneFailed: Int
    let anePresented: Int
    let aneAvgMs: Double
    let aneTargetFPS: String
    let aneBackend: String
    let aneQueueDepth: Int
    let avDeltaMs: Double?
    let memoryFootprintMB: Double
    let verdictLabel: String
    let thermalLevel: ThermalLevel

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        playbackState: String,
        mediaTime: Double,
        width: Int,
        height: Int,
        sourceFPS: Double,
        outputFPS: Double,
        droppedFrames: Int64,
        aneInterpolated: Int,
        aneSkipped: Int,
        aneFailed: Int,
        anePresented: Int,
        aneAvgMs: Double,
        aneTargetFPS: String = "",
        aneBackend: String = "",
        aneQueueDepth: Int = 0,
        avDeltaMs: Double? = nil,
        memoryFootprintMB: Double = 0,
        verdictLabel: String,
        thermalLevel: ThermalLevel
    ) {
        self.id = id
        self.timestamp = timestamp
        self.playbackState = playbackState
        self.mediaTime = mediaTime
        self.width = width
        self.height = height
        self.sourceFPS = sourceFPS
        self.outputFPS = outputFPS
        self.droppedFrames = droppedFrames
        self.aneInterpolated = aneInterpolated
        self.aneSkipped = aneSkipped
        self.aneFailed = aneFailed
        self.anePresented = anePresented
        self.aneAvgMs = aneAvgMs
        self.aneTargetFPS = aneTargetFPS
        self.aneBackend = aneBackend
        self.aneQueueDepth = aneQueueDepth
        self.avDeltaMs = avDeltaMs
        self.memoryFootprintMB = memoryFootprintMB
        self.verdictLabel = verdictLabel
        self.thermalLevel = thermalLevel
    }

    func formatLogLine(timeString: String? = nil) -> String {
        let resolvedTime: String
        if let timeString {
            resolvedTime = timeString
        } else {
            let comps = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: timestamp)
            let ms = max(0, min(999, (comps.nanosecond ?? 0) / 1_000_000))
            resolvedTime = String(format: "%02d:%02d:%02d.%03d", comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0, ms)
        }

        let resText = (width > 0 && height > 0) ? "\(width)x\(height)" : "--"
        let srcText = sourceFPS > 0 ? String(format: "%.1f", sourceFPS) : "--"
        let outText = outputFPS > 0 ? String(format: "%.1f", outputFPS) : "--"
        let timeText = String(format: "%.1fs", mediaTime)
        let memSeg = memoryFootprintMB > 0 ? String(format: " mem=%.1fMB", memoryFootprintMB) : ""
        let avgText = String(format: "%.1fms", aneAvgMs)
        let targetSeg = aneTargetFPS.isEmpty ? "" : " target=\(aneTargetFPS)"
        let backendSeg = aneBackend.isEmpty ? "" : " backend=\(aneBackend)"
        let queueSeg = " q=\(aneQueueDepth)"
        let avDeltaSeg = avDeltaMs.map { String(format: " avDelta=%+.1fms", $0) } ?? ""
        let tag = (aneBackend == "原帧率直通") ? "[PASS]" : "[ANE]"

        return "[\(resolvedTime)] \(tag) \(playbackState) t=\(timeText) \(resText) fps=\(srcText)->\(outText)\(targetSeg)\(backendSeg)\(queueSeg)\(avDeltaSeg) drop=\(droppedFrames) ane(interp=\(aneInterpolated),skip=\(aneSkipped),fail=\(aneFailed),pres=\(anePresented),avg=\(avgText)) verdict=\(verdictLabel) therm=\(thermalLevel.rawValue)\(memSeg)"
    }
}
