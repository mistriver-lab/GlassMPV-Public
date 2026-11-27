import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private final class ThermalObserverToken: @unchecked Sendable {
    var observer: NSObjectProtocol?

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

private final class TelemetryLoopToken: @unchecked Sendable {
    var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }
}

@MainActor
final class PlayerCoordinator: ObservableObject {
    @Published var interpolationMode: InterpolationMode = .vtOpticalFlow
    @Published var opticalFlowTargetFPS: OpticalFlowTargetFPS = .x2
    @Published var vtSpatial2x: Bool = false
    @Published var isEDREnabled: Bool = true
    @Published var isAspectFill: Bool = false
    @Published var isLooping: Bool = true
    @Published var speed: Double = 1.0
    @Published var currentURL: URL?
    @Published var isImportingFile: Bool = false
    @Published var selfCheckReport: String = ""
    @Published var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published var runtimeTimeline: [RuntimeTelemetrySample] = []
    @Published var lastSessionSummary: SessionDiagnosticSummary?
    @Published var uiAuditLogs: [String] = []
    @Published var isLowPowerModeEnabled: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published var videoEnhancementPreset: VideoEnhancementPreset = .off
    @Published var videoEnhancementStrength: VideoEnhancementStrength = .standard

    let opticalFlowController = OpticalFlowPlayerController()
    private let thermalToken = ThermalObserverToken()
    private let powerModeToken = ThermalObserverToken()
    private let telemetryLoopToken = TelemetryLoopToken()

    private static let auditTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init() {
        opticalFlowController.setEDREnabled(isEDREnabled)
        opticalFlowController.setAspectFill(isAspectFill)
        opticalFlowController.isLoopingEnabled = isLooping

        thermalToken.observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let current = ProcessInfo.processInfo.thermalState
            Task { @MainActor [weak self] in
                self?.thermalState = current
            }
        }

        powerModeToken.observer = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLowPowerModeEnabled = lowPower
                self.opticalFlowController.syncDisplayLinkState()
            }
        }
    }

    func recordUISwitch(_ detail: String) {
        let stamp = Self.auditTimeFormatter.string(from: Date())
        uiAuditLogs.append("[\(stamp)] [ui-switch] \(detail)")
        if uiAuditLogs.count > 500 {
            uiAuditLogs.removeFirst(uiAuditLogs.count - 500)
        }
    }

    var activeVideoWidth: Int {
        opticalFlowController.videoWidth
    }

    var activeVideoHeight: Int {
        opticalFlowController.videoHeight
    }

    var isSuperResolutionDisabledBy4K: Bool {
        SuperResolutionPolicy.isAlready4K(width: activeVideoWidth, height: activeVideoHeight)
    }

    var superResolutionDisabledReason: String? {
        SuperResolutionPolicy.disabledReason(width: activeVideoWidth, height: activeVideoHeight)
    }

    var currentEnhancementSummary: String {
        guard interpolationMode == .vtOpticalFlow else {
            return "原帧率"
        }
        if vtSpatial2x && opticalFlowTargetFPS.allowsSpatial2x {
            return "\(opticalFlowTargetFPS.shortBadge) + 2×超分"
        }
        return opticalFlowTargetFPS.shortBadge
    }

    var hudMetrics: PlaybackHUDMetrics {
        let thermal = ThermalLevel(state: thermalState)
        if interpolationMode == .off {
            return PlaybackHUDMetrics(
                engineBadge: "PASS",
                interpolationBadge: "原帧率",
                codec: opticalFlowController.videoCodec,
                width: opticalFlowController.videoWidth,
                height: opticalFlowController.videoHeight,
                sourceFPS: opticalFlowController.sourceFPS,
                outputFPS: opticalFlowController.actualOutputFPS,
                bitDepth: opticalFlowController.bitDepthLabel,
                hdrTag: opticalFlowController.hdrLabel,
                isHDRActive: opticalFlowController.isHDRActive,
                decoderBadge: "硬解 VT直通",
                droppedFrames: opticalFlowController.droppedFrames,
                thermalLevel: thermal
            )
        }
        let targetBadge = opticalFlowController.targetSummaryBadge
        let interpBadge = opticalFlowController.enableSpatial2xUpscale
            ? "光流\(targetBadge)+超分2×"
            : "光流\(targetBadge)"
        let aneDecoderBadge = opticalFlowController.activeBackendLabel != "--"
            ? "VT+\(opticalFlowController.activeBackendLabel)"
            : "硬解 VT+ANE"
        return PlaybackHUDMetrics(
            engineBadge: "ANE",
            interpolationBadge: interpBadge,
            codec: opticalFlowController.videoCodec,
            width: opticalFlowController.videoWidth,
            height: opticalFlowController.videoHeight,
            sourceFPS: opticalFlowController.sourceFPS,
            outputFPS: opticalFlowController.actualOutputFPS,
            bitDepth: opticalFlowController.bitDepthLabel,
            hdrTag: opticalFlowController.hdrLabel,
            isHDRActive: opticalFlowController.isHDRActive,
            decoderBadge: aneDecoderBadge,
            droppedFrames: opticalFlowController.droppedFrames,
            thermalLevel: thermal
        )
    }

    func presentLocalVideoPicker() {
        opticalFlowController.clearError()
        opticalFlowController.appendLog("[file] 正在拉起系统原生文件选择器 (UIDocumentPickerViewController, asCopy=true)...")
        NativeDocumentPickerPresenter.shared.present(
            onPick: { [weak self] url in
                self?.open(url: url, isSecurityScoped: false)
            },
            onCancel: { [weak self] in
                self?.opticalFlowController.appendLog("[file] 用户取消了本地文件选择")
            },
            onError: { [weak self] message in
                self?.opticalFlowController.recordExternalError("无法打开本地文件选择器：\(message)")
            }
        )
    }

    func open(url: URL, isSecurityScoped: Bool = false) {
        opticalFlowController.clearError()

        if !url.isFileURL {
            beginPlayback(url: url)
            return
        }

        isImportingFile = true
        opticalFlowController.appendLog("[file] 正在异步准备本地视频: \(url.lastPathComponent)")

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let playableURL = try await LocalMediaImporter.preparePlayableLocalURL(
                    from: url,
                    isSecurityScoped: isSecurityScoped
                )
                self.isImportingFile = false
                self.opticalFlowController.appendLog("[file] 本地视频已就绪: \(playableURL.lastPathComponent)")
                self.beginPlayback(url: playableURL)
            } catch {
                self.isImportingFile = false
                self.opticalFlowController.recordExternalError("无法读取本地视频（\(url.lastPathComponent)）：\(error.localizedDescription)")
            }
        }
    }

    func importFromPhotosItem(_ item: PhotosPickerItem) {
        guard !isImportingFile else { return }
        isImportingFile = true
        opticalFlowController.clearError()
        opticalFlowController.appendLog("[photos] 开始从系统相册导入视频...")

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let movie = try await item.loadTransferable(type: MovieFileTransferable.self) else {
                    self.isImportingFile = false
                    self.opticalFlowController.recordExternalError("未能从系统相册读取该视频（请确认 iCloud 原片已下载到本地）。")
                    return
                }
                self.isImportingFile = false
                self.opticalFlowController.appendLog("[photos] 相册视频已拷贝至沙盒: \(movie.url.lastPathComponent)")
                self.beginPlayback(url: movie.url)
            } catch {
                self.isImportingFile = false
                self.opticalFlowController.recordExternalError("相册视频导入失败：\(error.localizedDescription)")
            }
        }
    }

    static var persistedLastReportURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("glassmpv_last_session_report.txt")
    }

    func closeToHome() {
        if currentURL != nil {
            captureRuntimeTelemetrySample()
            lastSessionSummary = buildCurrentSessionSummary()
            persistLastSessionReport()
        }
        recordUISwitch("closeToHome interp=\(interpolationMode.rawValue) target=\(opticalFlowTargetFPS.shortBadge)")
        stopRuntimeTelemetrySampling()
        opticalFlowController.stop()
        currentURL = nil
        isImportingFile = false
        OrientationController.shared.returnToHomeOrientation()
    }

    private func beginPlayback(url: URL) {
        let enteringFromHome = (currentURL == nil)
        currentURL = url
        runtimeTimeline.removeAll()
        if enteringFromHome {
            OrientationController.shared.enterVideoLandscape()
        }
        startPlayback()
        startRuntimeTelemetrySampling()
    }

    var currentInterpolationVerdict: InterpolationVerdict {
        InterpolationVerdict.evaluateANE(
            isEnabled: interpolationMode == .vtOpticalFlow,
            interpolatedCount: opticalFlowController.interpolatedFrameCount,
            failedCount: opticalFlowController.failedInterpolationCount,
            presentedCount: opticalFlowController.presentedFrameCount,
            actualOutputFPS: opticalFlowController.actualOutputFPS,
            sourceFPS: opticalFlowController.sourceFPS,
            errorMessage: opticalFlowController.errorMessage ?? opticalFlowController.lastInterpolationError,
            targetLabel: opticalFlowController.targetSummaryBadge
        )
    }

    func startRuntimeTelemetrySampling() {
        telemetryLoopToken.task?.cancel()
        let loopTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, self.currentURL != nil else { break }
                self.captureRuntimeTelemetrySample()
            }
        }
        telemetryLoopToken.task = loopTask
    }

    func stopRuntimeTelemetrySampling() {
        telemetryLoopToken.task?.cancel()
        telemetryLoopToken.task = nil
    }

    func captureRuntimeTelemetrySample() {
        let verdict = currentInterpolationVerdict
        let metrics = hudMetrics
        let memMB = DeviceDiagnosticsSampler.currentMemoryFootprintMB()
        let sample = RuntimeTelemetrySample(
            playbackState: opticalFlowController.isPaused ? "已暂停" : "播放中",
            mediaTime: activeCurrentTime,
            width: metrics.width,
            height: metrics.height,
            sourceFPS: metrics.sourceFPS,
            outputFPS: metrics.outputFPS,
            droppedFrames: metrics.droppedFrames,
            aneInterpolated: opticalFlowController.interpolatedFrameCount,
            aneSkipped: opticalFlowController.skippedInterpolationCount,
            aneFailed: opticalFlowController.failedInterpolationCount,
            anePresented: opticalFlowController.presentedFrameCount,
            aneAvgMs: opticalFlowController.averageInterpolationMs,
            aneTargetFPS: interpolationMode == .vtOpticalFlow ? opticalFlowController.targetSummaryBadge : "原帧率",
            aneBackend: opticalFlowController.activeBackendLabel,
            aneQueueDepth: opticalFlowController.currentQueueDepthSnapshot(),
            avDeltaMs: opticalFlowController.latestAVDeltaMs,
            memoryFootprintMB: memMB,
            verdictLabel: verdict.shortLabel,
            thermalLevel: ThermalLevel(state: thermalState)
        )
        runtimeTimeline.append(sample)
        if runtimeTimeline.count > 500 {
            runtimeTimeline.removeFirst(runtimeTimeline.count - 500)
        }
        if currentURL != nil {
            lastSessionSummary = buildCurrentSessionSummary()
            if runtimeTimeline.count == 1 || runtimeTimeline.count % 3 == 0 {
                persistLastSessionReport()
            }
        }
    }

    func persistLastSessionReport() {
        let content = exportDiagnosticReportText(includePersistedFallback: false)
        try? content.write(to: Self.persistedLastReportURL, atomically: true, encoding: .utf8)
    }

    func exportDiagnosticReportText(includePersistedFallback: Bool) -> String {
        if selfCheckReport.isEmpty {
            runRealDeviceSelfCheck()
        }
        let maxScreenFPS = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.maximumFramesPerSecond ?? 60
        let deviceInfo = DeviceDiagnosticsSampler.deviceSummaryLine(maxScreenFPS: maxScreenFPS)

        let summary: SessionDiagnosticSummary
        var extraTelemetry: [String] = []
        if currentURL != nil {
            summary = buildCurrentSessionSummary()
        } else if let cached = lastSessionSummary {
            summary = cached
            extraTelemetry.append("Snapshot Source: last-session (cached before closeToHome)")
        } else {
            summary = buildCurrentSessionSummary()
        }

        var report = DiagnosticLogExporter.buildReport(
            version: AppReleaseInfo.displayVersion,
            deviceInfo: deviceInfo,
            engineName: summary.engineName,
            playbackState: summary.playbackState,
            resolution: summary.resolution,
            fpsSummary: summary.fpsSummary,
            decoderSummary: summary.decoderSummary,
            is4KGated: summary.is4KGated,
            telemetrySummary: summary.telemetrySummary + extraTelemetry,
            runtimeTimeline: runtimeTimeline.map { $0.formatLogLine() },
            uiAuditLogs: uiAuditLogs,
            selfCheck: selfCheckReport,
            opticalLogs: opticalFlowController.diagnosticLogs
        )

        if includePersistedFallback,
           currentURL == nil,
           lastSessionSummary == nil,
           runtimeTimeline.isEmpty,
           let persisted = try? String(contentsOf: Self.persistedLastReportURL, encoding: .utf8),
           !persisted.isEmpty {
            report += "\n\n--- Previous Session Backup (Before Relaunch) ---\n\(persisted)"
        }
        return report
    }

    func buildCurrentSessionSummary() -> SessionDiagnosticSummary {
        let metrics = hudMetrics
        let resolution = (metrics.width > 0 && metrics.height > 0)
            ? "\(metrics.width)×\(metrics.height)"
            : "暂无"
        let stateText = opticalFlowController.isPaused ? "已暂停" : "播放中"
        let verdict = currentInterpolationVerdict
        let engineLabel = interpolationMode == .vtOpticalFlow ? "ANE 光流核" : "原生硬解直通"
        let telemetrySummary = [
            "Interpolation Verdict: \(verdict.shortLabel) | \(verdict.detailText)",
            "HDR/EDR: \(metrics.hdrTag) (edr=\(isEDREnabled ? "ON" : "OFF"), active=\(metrics.isHDRActive ? "YES" : "NO")) | Fill=\(isAspectFill ? "Fill" : "Fit") | Loop=\(isLooping ? "ON" : "OFF")",
            "ANE Target: \(opticalFlowController.targetSummaryBadge) (requested=\(opticalFlowController.requestedTargetFPS.shortBadge), effective=\(opticalFlowController.effectiveTargetFPS.shortBadge)) | ANE Backend: \(opticalFlowController.activeBackendLabel) | Clock: \(opticalFlowController.clockSourceLabel) | spatial2x=\(opticalFlowController.enableSpatial2xUpscale ? "ON" : "OFF")",
            "Quality Enhance: \(videoEnhancementPreset.rawValue) (\(videoEnhancementStrength.rawValue)) -> \(opticalFlowController.activeQualityPipelineLabel) | avgMs=\(String(format: "%.2f", opticalFlowController.averageQualityEnhanceMs))",
            "ANE Counters: interpolated=\(opticalFlowController.interpolatedFrameCount) | skipped=\(opticalFlowController.skippedInterpolationCount) | failed=\(opticalFlowController.failedInterpolationCount) | presented=\(opticalFlowController.presentedFrameCount) | avgMs=\(String(format: "%.1f", opticalFlowController.averageInterpolationMs)) | actualFPS=\(String(format: "%.1f", opticalFlowController.actualOutputFPS)) | queueDepth=\(opticalFlowController.currentQueueDepthSnapshot()) | avDelta=\(opticalFlowController.latestAVDeltaMs.map { String(format: "%+.1fms", $0) } ?? "--")"
        ]
        return SessionDiagnosticSummary(
            capturedAt: Date(),
            engineName: engineLabel,
            playbackState: stateText,
            resolution: resolution,
            fpsSummary: metrics.fpsSummary,
            decoderSummary: "\(metrics.codec) / \(metrics.decoderBadge)",
            is4KGated: isSuperResolutionDisabledBy4K,
            telemetrySummary: telemetrySummary,
            mediaFilename: currentURL?.lastPathComponent ?? ""
        )
    }

    func retryWithoutInterpolation() {
        interpolationMode = .off
        vtSpatial2x = false
        opticalFlowController.clearError()
        recordUISwitch("retryWithoutInterpolation -> 原帧率直通")
        if currentURL != nil {
            startPlayback(seekTo: opticalFlowController.currentTime, autoPlay: true)
        }
    }

    func runRealDeviceSelfCheck() {
        let verdict = currentInterpolationVerdict
        let maxScreenFPS = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.maximumFramesPerSecond ?? 60

        let importCheck: String = {
            do {
                try FileManager.default.createDirectory(
                    at: LocalMediaImporter.importsDirectory,
                    withIntermediateDirectories: true
                )
                let currentReadable = currentURL.map {
                    $0.isFileURL ? FileManager.default.isReadableFile(atPath: $0.path(percentEncoded: false)) : true
                } ?? true
                return "PASS (沙盒导入目录可写, 当前片源可读=\(currentReadable))"
            } catch {
                return "FAIL (\(error.localizedDescription))"
            }
        }()

        let opticalStatus = "\(opticalFlowController.capabilityDescription) | 模式=\(interpolationMode.rawValue) | 画质=\(videoEnhancementPreset.rawValue)(\(opticalFlowController.activeQualityPipelineLabel)) | HDR=\(opticalFlowController.hdrLabel)(EDR=\(isEDREnabled ? "ON" : "OFF")) | 目标=\(opticalFlowController.targetSummaryBadge) | 后端=\(opticalFlowController.activeBackendLabel) | 时钟=\(opticalFlowController.clockSourceLabel) | 补帧=\(opticalFlowController.interpolatedFrameCount) | 跳帧追赶=\(opticalFlowController.skippedInterpolationCount) | 失败=\(opticalFlowController.failedInterpolationCount) | 送显=\(opticalFlowController.presentedFrameCount) | 平均耗时=\(String(format: "%.1f", opticalFlowController.averageInterpolationMs))ms | 实测FPS=\(String(format: "%.1f", opticalFlowController.actualOutputFPS)) | err=\(opticalFlowController.errorMessage ?? opticalFlowController.lastInterpolationError ?? "none")"

        let gateStatus = isSuperResolutionDisabledBy4K ? "已触发4K禁超分" : "允许2×空间超分"
        let lines = [
            "=== GlassMPV 运行状态摘要 ===",
            "版本: \(AppReleaseInfo.displayVersion) | 模式: \(interpolationMode.rawValue) | 4K超分门控: \(gateStatus) | 补帧判定: \(verdict.shortLabel) (\(verdict.detailText))",
            "1. 屏幕 ProMotion 上限: \(maxScreenFPS) Hz \(maxScreenFPS >= 120 ? "(PASS)" : "(非120Hz)")",
            "2. 本地/相册导入沙盒通道: \(importCheck)",
            "3. ANE 光流与硬解直通核: \(opticalStatus)",
            "4. 黑匣子采样: 共 \(runtimeTimeline.count) 条（最近判定=\(runtimeTimeline.last?.verdictLabel ?? "无")）"
        ]
        selfCheckReport = lines.joined(separator: "\n")
    }

    func selectFrameRateOption(_ target: OpticalFlowTargetFPS?) {
        guard let target else {
            setInterpolation(.off)
            return
        }
        if interpolationMode == .off {
            opticalFlowTargetFPS = target
            if !target.allowsSpatial2x && vtSpatial2x {
                vtSpatial2x = false
            }
            recordUISwitch("selectFrameRateOption(fromOff) -> \(target.shortBadge)")
            setInterpolation(.vtOpticalFlow)
        } else {
            setOpticalFlowTargetFPS(target)
        }
    }

    func setInterpolation(_ mode: InterpolationMode) {
        guard mode != interpolationMode else { return }
        let previousMode = interpolationMode
        let resumeTime = activeCurrentTime
        let wasPaused = activePaused
        if currentURL != nil {
            captureRuntimeTelemetrySample()
        }
        interpolationMode = mode
        if mode == .off {
            vtSpatial2x = false
        }
        recordUISwitch("setInterpolation \(previousMode.rawValue) -> \(mode.rawValue) (paused=\(wasPaused), t=\(String(format: "%.2f", resumeTime))s)")
        if currentURL != nil {
            startPlayback(seekTo: resumeTime, autoPlay: !wasPaused)
        }
    }

    func setOpticalFlowTargetFPS(_ target: OpticalFlowTargetFPS) {
        guard target != opticalFlowTargetFPS || opticalFlowController.effectiveTargetFPS != target else {
            return
        }
        let previousTarget = opticalFlowTargetFPS
        opticalFlowTargetFPS = target
        if !target.allowsSpatial2x && vtSpatial2x {
            vtSpatial2x = false
            opticalFlowController.appendLog("[ane] 切换至多相目标 \(target.shortBadge)，已自动关闭 ANE 2× 空间超分")
        }
        let wasPaused = opticalFlowController.isPaused
        recordUISwitch("setOpticalFlowTargetFPS \(previousTarget.shortBadge) -> \(target.shortBadge) (paused=\(wasPaused))")
        if interpolationMode == .vtOpticalFlow {
            opticalFlowController.updateTargetConfiguration(targetFPS: target, spatial2x: vtSpatial2x)
            opticalFlowController.setSpeed(speed)
        }
    }

    func setVTSpatial2x(_ enabled: Bool) {
        guard enabled != vtSpatial2x else { return }
        if enabled && !opticalFlowTargetFPS.allowsSpatial2x {
            vtSpatial2x = false
            opticalFlowController.appendLog("[ane] 目标帧率 \(opticalFlowTargetFPS.shortBadge) 需多相补帧，仅 2× 档位支持同步开启 ANE 2× 空间超分")
            recordUISwitch("setVTSpatial2x(true) 被多相档位(\(opticalFlowTargetFPS.shortBadge))互斥拦截")
            return
        }
        if enabled && isSuperResolutionDisabledBy4K {
            vtSpatial2x = false
            let reason = superResolutionDisabledReason ?? "片源已达 4K，自动禁用 ANE 2× 超分"
            opticalFlowController.appendLog("[ane] \(reason)")
            recordUISwitch("setVTSpatial2x(true) 被4K门控拦截")
            return
        }
        vtSpatial2x = enabled
        let wasPaused = opticalFlowController.isPaused
        recordUISwitch("setVTSpatial2x(\(enabled)) (paused=\(wasPaused))")
        if interpolationMode == .vtOpticalFlow {
            opticalFlowController.updateTargetConfiguration(targetFPS: opticalFlowTargetFPS, spatial2x: enabled)
            opticalFlowController.setSpeed(speed)
        }
    }

    func setEDREnabled(_ enabled: Bool) {
        guard enabled != isEDREnabled else { return }
        isEDREnabled = enabled
        recordUISwitch("setEDREnabled(\(enabled))")
        opticalFlowController.setEDREnabled(enabled)
    }

    func setAspectFill(_ enabled: Bool) {
        guard enabled != isAspectFill else { return }
        isAspectFill = enabled
        recordUISwitch("setAspectFill(\(enabled))")
        opticalFlowController.setAspectFill(enabled)
    }

    func setLooping(_ enabled: Bool) {
        guard enabled != isLooping else { return }
        isLooping = enabled
        recordUISwitch("setLooping(\(enabled))")
        opticalFlowController.isLoopingEnabled = enabled
    }

    func setSpeed(_ value: Double) {
        speed = value
        recordUISwitch("setSpeed(\(String(format: "%.2g", value))x)")
        opticalFlowController.setSpeed(value)
    }

    func setVideoEnhancementPreset(_ preset: VideoEnhancementPreset) {
        guard preset != videoEnhancementPreset else { return }
        let prev = videoEnhancementPreset
        videoEnhancementPreset = preset
        opticalFlowController.videoEnhancementPreset = preset
        if preset == .off {
            opticalFlowController.isComparingOriginalQuality = false
        }
        recordUISwitch("setVideoEnhancementPreset \(prev.rawValue) -> \(preset.rawValue)")
    }

    func setVideoEnhancementStrength(_ strength: VideoEnhancementStrength) {
        guard strength != videoEnhancementStrength else { return }
        let prev = videoEnhancementStrength
        videoEnhancementStrength = strength
        opticalFlowController.videoEnhancementStrength = strength
        recordUISwitch("setVideoEnhancementStrength \(prev.rawValue) -> \(strength.rawValue)")
    }

    func setComparingOriginalQuality(_ comparing: Bool) {
        guard opticalFlowController.isComparingOriginalQuality != comparing else { return }
        opticalFlowController.isComparingOriginalQuality = comparing
    }

    func togglePlayPause() {
        let nextState = activePaused ? "play" : "pause"
        recordUISwitch("togglePlayPause(\(nextState))")
        opticalFlowController.togglePlayPause()
    }

    func seek(to seconds: Double) {
        opticalFlowController.seek(to: seconds)
    }

    func seekRelative(_ delta: Double) {
        opticalFlowController.seekRelative(delta)
    }

    var activeCurrentTime: Double {
        opticalFlowController.currentTime
    }

    var activeDuration: Double {
        opticalFlowController.duration
    }

    var activePaused: Bool {
        opticalFlowController.isPaused
    }

    private func startPlayback(seekTo: Double = 0, autoPlay: Bool = true) {
        guard let url = currentURL else { return }
        opticalFlowController.setEDREnabled(isEDREnabled)
        opticalFlowController.setAspectFill(isAspectFill)
        opticalFlowController.isLoopingEnabled = isLooping
        let enableInterp = (interpolationMode == .vtOpticalFlow)
        opticalFlowController.load(
            url: url,
            spatial2x: enableInterp && vtSpatial2x,
            targetFPS: opticalFlowTargetFPS,
            startAt: seekTo,
            autoPlay: autoPlay,
            enableInterpolation: enableInterp
        )
        opticalFlowController.setSpeed(speed)
    }
}

// MARK: - Smart Source-Adaptive Frame-Rate Preset Strip

private struct FrameRatePresetStrip: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject var optical: OpticalFlowPlayerController
    var compact: Bool = false
    var onSelectPreset: () -> Void = {}

    var body: some View {
        let presets = OpticalFlowTargetFPS.smartPresets(forSourceFPS: optical.sourceFPS)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: compact ? 8 : 10) {
                ForEach(presets) { preset in
                    let isSelected: Bool = {
                        if let target = preset.target {
                            return coordinator.interpolationMode == .vtOpticalFlow && coordinator.opticalFlowTargetFPS == target
                        }
                        return coordinator.interpolationMode == .off
                    }()
                    let isEffectiveLower = isSelected
                        && preset.target != nil
                        && coordinator.currentURL != nil
                        && optical.effectiveTargetFPS != preset.target
                    let titleText = isEffectiveLower
                        ? "\(preset.primaryTitle)→\(Int(optical.effectiveTargetFPS.effectiveTargetFPS(sourceFPS: optical.sourceFPS).rounded()))"
                        : preset.primaryTitle
                    let subtitleText = isEffectiveLower
                        ? "已自动稳帧"
                        : preset.subtitle

                    presetCardButton(
                        title: titleText,
                        subtitle: subtitleText,
                        isSelected: isSelected,
                        accent: preset.target == nil ? .white : .cyan
                    ) {
                        coordinator.selectFrameRateOption(preset.target)
                        onSelectPreset()
                    }
                }

                if coordinator.interpolationMode == .vtOpticalFlow
                    && coordinator.opticalFlowTargetFPS.allowsSpatial2x
                    && !coordinator.isSuperResolutionDisabledBy4K {
                    presetCardButton(
                        title: "2× 超分",
                        subtitle: coordinator.vtSpatial2x ? "已开启" : "ANE 细节",
                        isSelected: coordinator.vtSpatial2x,
                        accent: .indigo
                    ) {
                        coordinator.setVTSpatial2x(!coordinator.vtSpatial2x)
                        onSelectPreset()
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func presetCardButton(
        title: String,
        subtitle: String,
        isSelected: Bool,
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: compact ? 13 : 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(subtitle)
                    .font(.system(size: compact ? 9.5 : 10.5, weight: .medium))
                    .opacity(isSelected ? 0.85 : 0.72)
            }
            .foregroundStyle(isSelected ? .black : .white.opacity(0.92))
            .padding(.horizontal, compact ? 12 : 14)
            .padding(.vertical, compact ? 7 : 9)
            .background(
                RoundedRectangle(cornerRadius: compact ? 13 : 15, style: .continuous)
                    .fill(isSelected ? accent : Color.white.opacity(0.11))
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 13 : 15, style: .continuous)
                    .strokeBorder(isSelected ? accent.opacity(0.9) : Color.white.opacity(0.16), lineWidth: 0.7)
            )
            .contentShape(RoundedRectangle(cornerRadius: compact ? 13 : 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: compact ? 13 : 15, style: .continuous))
    }
}

// MARK: - Quality Enhancement Preset & Comparison Strip

private struct QualityPresetStrip: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject var optical: OpticalFlowPlayerController
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: compact ? 8 : 10) {
                    ForEach(VideoEnhancementPreset.allCases) { preset in
                        let isSelected = (coordinator.videoEnhancementPreset == preset)
                        Button {
                            coordinator.setVideoEnhancementPreset(preset)
                        } label: {
                            VStack(spacing: 2) {
                                Text(preset.rawValue)
                                    .font(.system(size: compact ? 13 : 14, weight: .bold, design: .rounded))
                                Text(preset.subtitle)
                                    .font(.system(size: compact ? 9.5 : 10.5, weight: .medium))
                                    .opacity(isSelected ? 0.85 : 0.72)
                            }
                            .foregroundStyle(isSelected ? .black : .white.opacity(0.92))
                            .padding(.horizontal, compact ? 12 : 14)
                            .padding(.vertical, compact ? 7 : 9)
                            .background(
                                RoundedRectangle(cornerRadius: compact ? 13 : 15, style: .continuous)
                                    .fill(isSelected ? (preset == .off ? .white : .purple.opacity(0.95)) : Color.white.opacity(0.11))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: compact ? 13 : 15, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? (preset == .off ? Color.white.opacity(0.9) : Color.purple.opacity(0.9)) : Color.white.opacity(0.16),
                                        lineWidth: 0.7
                                    )
                            )
                            .contentShape(RoundedRectangle(cornerRadius: compact ? 13 : 15, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            if coordinator.videoEnhancementPreset != .off {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(VideoEnhancementStrength.allCases) { strength in
                            let selected = (coordinator.videoEnhancementStrength == strength)
                            Button {
                                coordinator.setVideoEnhancementStrength(strength)
                            } label: {
                                Text(strength.rawValue)
                                    .font(.caption2.weight(selected ? .bold : .medium))
                                    .foregroundStyle(selected ? .black : .white.opacity(0.85))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule().fill(selected ? Color.cyan : Color.white.opacity(0.12))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer(minLength: 4)

                    if coordinator.currentURL != nil {
                        HStack(spacing: 4) {
                            Image(systemName: "eye")
                                .font(.caption2.weight(.semibold))
                            Text(optical.isComparingOriginalQuality ? "原画对比中" : "按住对比原画")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(optical.isComparingOriginalQuality ? .black : .white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(optical.isComparingOriginalQuality ? Color.yellow : Color.white.opacity(0.16))
                        )
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    coordinator.setComparingOriginalQuality(true)
                                }
                                .onEnded { _ in
                                    coordinator.setComparingOriginalQuality(false)
                                }
                        )
                    }
                }
            }
        }
    }
}

struct LiquidGlassPlayerView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject private var optical: OpticalFlowPlayerController

    @State private var showHUD: Bool = true
    @State private var showStatsHUD: Bool = false
    @State private var showFPSPicker: Bool = false
    @State private var showQualityPicker: Bool = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showURLPrompt: Bool = false
    @State private var streamURLInput: String = ""
    @State private var showEnhancementSheet: Bool = false
    @State private var showChangelogSheet: Bool = false
    @State private var showDiagnosticSheet: Bool = false
    @State private var isScrubbing: Bool = false
    @State private var scrubTime: Double = 0
    @State private var hudAutoHideTask: Task<Void, Never>?
    @State private var fpsAutoCloseTask: Task<Void, Never>?

    init(coordinator: PlayerCoordinator) {
        self.coordinator = coordinator
        self._optical = ObservedObject(wrappedValue: coordinator.opticalFlowController)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if coordinator.currentURL != nil {
                OpticalFlowVideoSurface(controller: optical)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if showFPSPicker || showQualityPicker {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                showFPSPicker = false
                                showQualityPicker = false
                            }
                            fpsAutoCloseTask?.cancel()
                            scheduleHUDAutoHide()
                            return
                        }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showHUD.toggle()
                        }
                        if showHUD {
                            scheduleHUDAutoHide()
                        } else {
                            hudAutoHideTask?.cancel()
                        }
                    }
            }

            if coordinator.currentURL == nil {
                welcomeOverlay
            } else {
                if optical.isComparingOriginalQuality {
                    VStack {
                        Text("按住对比中 · 原画")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.yellow))
                            .padding(.top, 14)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
                if optical.errorMessage == nil,
                   (optical.isLoadingPipeline || optical.presentedFrameCount == 0) {
                    loadingStatusPill(
                        optical.pipelineStatusText.isEmpty ? "正在预热视频管线..." : optical.pipelineStatusText
                    )
                }

                if showStatsHUD {
                    VStack {
                        HStack {
                            compactStatsHUD(metrics: coordinator.hudMetrics)
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, showHUD ? 60 : 14)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.2), value: showHUD)
                    .transition(.opacity)
                }

                if showHUD {
                    playerHUDOverlay
                        .transition(.opacity)
                }
            }

            if coordinator.isImportingFile {
                loadingStatusPill("正在导入视频...")
            }

            if let error = optical.errorMessage {
                playbackErrorBanner(error)
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            selectedPhotoItem = nil
            coordinator.importFromPhotosItem(newItem)
        }
        .onChange(of: coordinator.currentURL) { _, newURL in
            if newURL != nil {
                showHUD = true
                scheduleHUDAutoHide()
            } else {
                hudAutoHideTask?.cancel()
            }
        }
        .onChange(of: optical.isPaused) { _, paused in
            if paused {
                hudAutoHideTask?.cancel()
                withAnimation(.easeInOut(duration: 0.2)) {
                    showHUD = true
                }
            } else if showHUD {
                scheduleHUDAutoHide()
            }
        }
        .onChange(of: showEnhancementSheet) { _, presented in
            if !presented && showHUD {
                scheduleHUDAutoHide()
            }
        }
        .onChange(of: showDiagnosticSheet) { _, presented in
            if !presented && showHUD {
                scheduleHUDAutoHide()
            }
        }
        .alert("打开网络视频流", isPresented: $showURLPrompt) {
            TextField("https:// 视频地址", text: $streamURLInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("播放") {
                let trimmed = streamURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: trimmed) {
                    coordinator.open(url: url, isSecurityScoped: false)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showEnhancementSheet) {
            EnhancementControlSheet(coordinator: coordinator)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showChangelogSheet) {
            ReleaseNotesSheet()
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showDiagnosticSheet) {
            DiagnosticLogSheet(coordinator: coordinator)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
    }

    private func scheduleHUDAutoHide() {
        hudAutoHideTask?.cancel()
        guard coordinator.currentURL != nil,
              !coordinator.activePaused,
              !isScrubbing,
              !showFPSPicker,
              !showQualityPicker,
              !showEnhancementSheet,
              !showDiagnosticSheet else {
            return
        }
        hudAutoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled,
                  coordinator.currentURL != nil,
                  !coordinator.activePaused,
                  !isScrubbing,
                  !showFPSPicker,
                  !showQualityPicker,
                  !showEnhancementSheet,
                  !showDiagnosticSheet else {
                return
            }
            withAnimation(.easeInOut(duration: 0.25)) {
                showHUD = false
            }
        }
    }

    private func scheduleFPSPickerAutoClose() {
        fpsAutoCloseTask?.cancel()
        fpsAutoCloseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.65))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                showFPSPicker = false
            }
            scheduleHUDAutoHide()
        }
    }

    // MARK: - Minimalist Liquid Glass Home

    private var welcomeOverlay: some View {
        ScrollView(showsIndicators: false) {
            GlassEffectContainer(spacing: 16) {
                VStack(spacing: 16) {
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.cyan.opacity(0.32), Color.indigo.opacity(0.28)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 64, height: 64)
                            Image(systemName: "sparkles.tv")
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(.cyan)
                        }

                        VStack(spacing: 4) {
                            Text("GlassMPV")
                                .font(.largeTitle.bold())
                            Text("ANE 硬件光流 · 杜比视界 HDR · 120Hz ProMotion")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("默认帧率策略")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(coordinator.currentEnhancementSummary)
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.cyan)
                            }
                            FrameRatePresetStrip(
                                coordinator: coordinator,
                                optical: optical,
                                compact: true
                            )

                            HStack {
                                Text("默认画质增强")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(coordinator.videoEnhancementPreset == .off ? "原画直通" : "\(coordinator.videoEnhancementPreset.rawValue) · \(coordinator.videoEnhancementStrength.rawValue)")
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.purple)
                            }
                            .padding(.top, 4)
                            QualityPresetStrip(
                                coordinator: coordinator,
                                optical: optical,
                                compact: true
                            )
                        }
                        .padding(.top, 4)
                    }
                    .padding(20)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))

                    HStack(spacing: 12) {
                        Button {
                            coordinator.presentLocalVideoPicker()
                        } label: {
                            Label("本地文件", systemImage: "folder.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Capsule())
                        .glassEffect(.regular.tint(.cyan).interactive(), in: .capsule)

                        PhotosPicker(selection: $selectedPhotoItem, matching: .videos, photoLibrary: .shared()) {
                            Label("系统相册", systemImage: "photo.on.rectangle.angled")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Capsule())
                        .glassEffect(.regular.tint(.indigo).interactive(), in: .capsule)
                    }

                    Button {
                        showURLPrompt = true
                    } label: {
                        Label("打开网络串流 URL", systemImage: "link")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Capsule())
                    .glassEffect(.regular.interactive(), in: .capsule)

                    HStack(spacing: 10) {
                        Button {
                            showEnhancementSheet = true
                        } label: {
                            Label("播控设置", systemImage: "slider.horizontal.3")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)

                        Button {
                            showDiagnosticSheet = true
                        } label: {
                            Label("运行日志", systemImage: "waveform.path.ecg")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)

                        Button {
                            showChangelogSheet = true
                        } label: {
                            Label("v\(AppReleaseInfo.shortVersion)", systemImage: "doc.text")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                }
                .frame(maxWidth: 500)
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Clean Floating Player HUD

    private var playerHUDOverlay: some View {
        VStack {
            HStack(spacing: 8) {
                toolbarActionButtons
                Spacer(minLength: 6)
                topRightMetricsBadge
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            VStack(spacing: 8) {
                if showQualityPicker {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(
                                optical.isDolbyVisionContent
                                    ? "杜比视界原片自动保留原厂映射"
                                    : "Metal + MetalFX 实时画质增强（\(optical.activeQualityPipelineLabel)）",
                                systemImage: "wand.and.stars"
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(optical.isDolbyVisionContent ? .yellow : .secondary)
                            Spacer()
                            Button {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                    showQualityPicker = false
                                }
                                scheduleHUDAutoHide()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        QualityPresetStrip(
                            coordinator: coordinator,
                            optical: optical,
                            compact: true
                        )
                    }
                    .padding(12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                    .frame(maxWidth: 680)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if showFPSPicker {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(
                                coordinator.isLowPowerModeEnabled
                                    ? "源帧率 \(PlaybackHUDMetrics.formatSourceFPS(optical.sourceFPS)) fps · 低电量 60Hz 上限"
                                    : "源帧率 \(PlaybackHUDMetrics.formatSourceFPS(optical.sourceFPS)) fps · ProMotion 智能锁频",
                                systemImage: coordinator.isLowPowerModeEnabled ? "battery.25" : "sparkles"
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(coordinator.isLowPowerModeEnabled ? .yellow : .secondary)
                            Spacer()
                            Button {
                                fpsAutoCloseTask?.cancel()
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                    showFPSPicker = false
                                }
                                scheduleHUDAutoHide()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        FrameRatePresetStrip(
                            coordinator: coordinator,
                            optical: optical,
                            compact: true
                        ) {
                            scheduleFPSPickerAutoClose()
                        }
                    }
                    .padding(12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                    .frame(maxWidth: 680)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Text(formatTime(displayTime))
                            .font(.caption2.monospacedDigit())
                            .frame(width: 46, alignment: .leading)

                        Slider(
                            value: Binding(
                                get: { displayTime },
                                set: { newVal in
                                    isScrubbing = true
                                    scrubTime = newVal
                                    hudAutoHideTask?.cancel()
                                }
                            ),
                            in: 0...max(coordinator.activeDuration, 1),
                            onEditingChanged: { editing in
                                if !editing {
                                    coordinator.seek(to: scrubTime)
                                    isScrubbing = false
                                    scheduleHUDAutoHide()
                                }
                            }
                        )
                        .tint(.cyan)

                        Text(formatTime(coordinator.activeDuration))
                            .font(.caption2.monospacedDigit())
                            .frame(width: 46, alignment: .trailing)
                    }

                    HStack(spacing: 8) {
                        Button {
                            coordinator.seekRelative(-10)
                            scheduleHUDAutoHide()
                        } label: {
                            Image(systemName: "gobackward.10")
                                .font(.callout.weight(.semibold))
                                .frame(width: 34, height: 34)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: .circle)

                        Button {
                            coordinator.togglePlayPause()
                            scheduleHUDAutoHide()
                        } label: {
                            Image(systemName: coordinator.activePaused ? "play.fill" : "pause.fill")
                                .font(.title3.weight(.semibold))
                                .frame(width: 42, height: 42)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Circle())
                        .glassEffect(.regular.tint(.cyan).interactive(), in: .circle)

                        Button {
                            coordinator.seekRelative(10)
                            scheduleHUDAutoHide()
                        } label: {
                            Image(systemName: "goforward.10")
                                .font(.callout.weight(.semibold))
                                .frame(width: 34, height: 34)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: .circle)

                        Spacer(minLength: 4)

                        let fpsSummary = OpticalFlowTargetFPS.activeCapsuleSummary(
                            isOff: coordinator.interpolationMode == .off,
                            requested: coordinator.opticalFlowTargetFPS,
                            effective: optical.effectiveTargetFPS,
                            sourceFPS: optical.sourceFPS,
                            spatial2x: coordinator.vtSpatial2x
                        )
                        Button {
                            fpsAutoCloseTask?.cancel()
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                showQualityPicker = false
                                showFPSPicker.toggle()
                            }
                            if showFPSPicker {
                                hudAutoHideTask?.cancel()
                            } else {
                                scheduleHUDAutoHide()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: coordinator.interpolationMode == .off ? "film" : "sparkles")
                                    .font(.caption2.weight(.bold))
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(fpsSummary.title)
                                        .font(.caption2.monospacedDigit().weight(.bold))
                                    Text(fpsSummary.subtitle)
                                        .font(.system(size: 8.5, weight: .medium))
                                        .opacity(0.75)
                                }
                                Image(systemName: showFPSPicker ? "chevron.down" : "chevron.up")
                                    .font(.system(size: 9, weight: .bold))
                                    .opacity(0.75)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Capsule())
                        .glassEffect(
                            coordinator.interpolationMode == .vtOpticalFlow ? .regular.tint(.cyan).interactive() : .regular.interactive(),
                            in: .capsule
                        )

                        Button {
                            fpsAutoCloseTask?.cancel()
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                showFPSPicker = false
                                showQualityPicker.toggle()
                            }
                            if showQualityPicker {
                                hudAutoHideTask?.cancel()
                            } else {
                                scheduleHUDAutoHide()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: coordinator.videoEnhancementPreset.iconName)
                                    .font(.caption2.weight(.bold))
                                Text(coordinator.videoEnhancementPreset.shortBadge)
                                    .font(.caption2.weight(.bold))
                            }
                            .foregroundStyle(coordinator.videoEnhancementPreset == .off ? .primary : .purple)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Capsule())
                        .glassEffect(
                            coordinator.videoEnhancementPreset != .off ? .regular.tint(.purple).interactive() : .regular.interactive(),
                            in: .capsule
                        )

                        if optical.isHDRContent {
                            Button {
                                coordinator.setEDREnabled(!coordinator.isEDREnabled)
                                scheduleHUDAutoHide()
                            } label: {
                                Text(coordinator.isEDREnabled ? "HDR" : "SDR")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(coordinator.isEDREnabled ? .yellow : .secondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 8)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .contentShape(Capsule())
                            .glassEffect(
                                coordinator.isEDREnabled ? .regular.tint(.yellow).interactive() : .regular.interactive(),
                                in: .capsule
                            )
                        }

                        Button {
                            coordinator.setLooping(!coordinator.isLooping)
                            scheduleHUDAutoHide()
                        } label: {
                            Image(systemName: "repeat")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(coordinator.isLooping ? .cyan : .secondary)
                                .frame(width: 34, height: 34)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Circle())
                        .glassEffect(
                            coordinator.isLooping ? .regular.tint(.cyan).interactive() : .regular.interactive(),
                            in: .circle
                        )

                        Menu {
                            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                                Button("\(rate, specifier: "%.2g")x") {
                                    coordinator.setSpeed(rate)
                                    scheduleHUDAutoHide()
                                }
                            }
                        } label: {
                            Text("\(coordinator.speed, specifier: "%.2g")x")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 8)
                        }
                        .glassEffect(.regular.interactive(), in: .capsule)

                        Button {
                            hudAutoHideTask?.cancel()
                            showEnhancementSheet = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.callout.weight(.semibold))
                                .frame(width: 34, height: 34)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Circle())
                        .glassEffect(.regular.tint(.indigo).interactive(), in: .circle)
                    }
                }
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                .frame(maxWidth: 680)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    private var toolbarActionButtons: some View {
        HStack(spacing: 8) {
            Button {
                coordinator.closeToHome()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.body.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: .circle)

            Button {
                OrientationController.shared.toggleVideoOrientation()
                scheduleHUDAutoHide()
            } label: {
                Image(systemName: "rotate.right")
                    .font(.body.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: .circle)

            Button {
                coordinator.setAspectFill(!coordinator.isAspectFill)
                scheduleHUDAutoHide()
            } label: {
                Image(systemName: coordinator.isAspectFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(coordinator.isAspectFill ? .cyan : .primary)
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .glassEffect(
                coordinator.isAspectFill ? .regular.tint(.cyan).interactive() : .regular.interactive(),
                in: .circle
            )

            Button {
                hudAutoHideTask?.cancel()
                showDiagnosticSheet = true
            } label: {
                Image(systemName: "waveform.path.ecg")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: .circle)
        }
    }

    private var topRightMetricsBadge: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showStatsHUD.toggle()
            }
            scheduleHUDAutoHide()
        } label: {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Text(activeResolutionText)
                    if optical.hdrLabel != "SDR" {
                        Text(optical.hdrLabel)
                            .foregroundStyle(optical.isHDRActive ? .yellow : .orange)
                    }
                }
                .font(.caption2.monospacedDigit().weight(.semibold))

                Text("\(coordinator.hudMetrics.interpolationBadge) · \(activeFPSText)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .glassEffect(
            showStatsHUD ? .regular.tint(.cyan).interactive() : .regular.interactive(),
            in: .capsule
        )
    }

    private func compactStatsHUD(metrics: PlaybackHUDMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(metrics.engineBadge)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        Color.cyan.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )

                Text(metrics.videoStreamSummary)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(metrics.isHDRActive ? .yellow : .white)
                    .lineLimit(1)
            }

            Text("FPS \(metrics.fpsSummary) · 丢帧 \(metrics.droppedFrames)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)

            Text(metrics.pipelineSummary)
                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)

            if optical.videoEnhancementPreset != .off {
                Text("画质 \(optical.activeQualityPipelineLabel) · \(String(format: "%.1f", optical.averageQualityEnhanceMs))ms")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.purple.opacity(0.95))
                    .lineLimit(1)
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(thermalColor(metrics.thermalLevel))
                    .frame(width: 6, height: 6)
                Text("温度 \(metrics.thermalLevel.rawValue)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(thermalColor(metrics.thermalLevel))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.62))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
                )
        )
    }

    private func thermalColor(_ level: ThermalLevel) -> Color {
        switch level {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        }
    }

    private func loadingStatusPill(_ state: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(state)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }

    private func playbackErrorBanner(_ message: String) -> some View {
        VStack(spacing: 12) {
            Label("播放遇到异常", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                if coordinator.interpolationMode != .off {
                    Button {
                        coordinator.retryWithoutInterpolation()
                    } label: {
                        Text("原帧率直通重试")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.cyan).interactive(), in: .capsule)
                }

                Button {
                    showDiagnosticSheet = true
                } label: {
                    Text("运行日志")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)

                Button {
                    coordinator.closeToHome()
                } label: {
                    Text("返回")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding()
    }

    private var displayTime: Double {
        isScrubbing ? scrubTime : coordinator.activeCurrentTime
    }

    private var activeResolutionText: String {
        let m = coordinator.hudMetrics
        if m.width > 0 && m.height > 0 {
            return "\(m.width)×\(m.height)"
        }
        if coordinator.interpolationMode == .off {
            return "原帧率"
        }
        return optical.enableSpatial2xUpscale ? "ANE 2×超分" : "ANE 光流"
    }

    private var activeFPSText: String {
        let m = coordinator.hudMetrics
        let fps = m.outputFPS > 0 ? m.outputFPS : m.sourceFPS
        return fps > 0 ? "\(PlaybackHUDMetrics.formatOutputFPS(fps)) fps" : "-- fps"
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Optical Flow & Playback Settings Sheet

struct EnhancementControlSheet: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject private var optical: OpticalFlowPlayerController
    @Environment(\.dismiss) private var dismiss

    init(coordinator: PlayerCoordinator) {
        self.coordinator = coordinator
        self._optical = ObservedObject(wrappedValue: coordinator.opticalFlowController)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("光流补帧目标帧率（实时热切换）") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("当前模式")
                            Spacer()
                            Text(coordinator.interpolationMode == .vtOpticalFlow ? "光流 \(optical.targetSummaryBadge)" : "原帧率直通")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.cyan)
                        }

                        FrameRatePresetStrip(
                            coordinator: coordinator,
                            optical: optical,
                            compact: false
                        )

                        Text("自动匹配片源帧率与 ProMotion 物理锁频（48Hz / 60Hz / 120Hz），并随低电量模式自动封顶 60Hz；播放中点选卡片立即原地热切换，无需重建音频。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    if optical.activeBackendLabel != "--" {
                        LabeledContent("运行后端", value: "\(optical.activeBackendLabel) (\(String(format: "%.1f", optical.actualOutputFPS)) fps)")
                    }

                    if let gatedReason = coordinator.superResolutionDisabledReason {
                        Label(gatedReason, systemImage: "4k.tv.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("实时 GPU 画质增强（假 4K 去糊 + MetalFX 低清超分）") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("当前画质")
                            Spacer()
                            Text(optical.activeQualityPipelineLabel)
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.purple)
                        }

                        QualityPresetStrip(
                            coordinator: coordinator,
                            optical: optical,
                            compact: false
                        )

                        Text(coordinator.videoEnhancementPreset.detailDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("画质与播放开关") {
                    Toggle("ANE 2× 空间超分（仅 2× 档位）", isOn: Binding(
                        get: { coordinator.vtSpatial2x },
                        set: { coordinator.setVTSpatial2x($0) }
                    ))
                    .disabled(
                        coordinator.interpolationMode == .off
                            || coordinator.isSuperResolutionDisabledBy4K
                            || !coordinator.opticalFlowTargetFPS.allowsSpatial2x
                    )

                    Toggle("杜比视界 / HDR 峰值亮度 (EDR)", isOn: Binding(
                        get: { coordinator.isEDREnabled },
                        set: { coordinator.setEDREnabled($0) }
                    ))

                    Toggle("画面铺满全屏 (裁剪黑边)", isOn: Binding(
                        get: { coordinator.isAspectFill },
                        set: { coordinator.setAspectFill($0) }
                    ))

                    Toggle("播完自动循环重播", isOn: Binding(
                        get: { coordinator.isLooping },
                        set: { coordinator.setLooping($0) }
                    ))
                }
            }
            .navigationTitle("播控与画质设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

struct ReleaseNotesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("当前版本") {
                    LabeledContent("GlassMPV", value: AppReleaseInfo.displayVersion)
                }

                ForEach(AppReleaseInfo.changelog) { entry in
                    Section("\(entry.version) · \(entry.date)") {
                        ForEach(entry.highlights, id: \.self) { item in
                            Label(item, systemImage: "sparkles")
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("版本与更新日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

struct DiagnosticLogSheet: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject private var optical: OpticalFlowPlayerController
    @Environment(\.dismiss) private var dismiss
    @State private var copiedFeedback: Bool = false
    @State private var exportedFeedback: Bool = false
    @State private var exportErrorMessage: String?

    init(coordinator: PlayerCoordinator) {
        self.coordinator = coordinator
        self._optical = ObservedObject(wrappedValue: coordinator.opticalFlowController)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("核心运行状态") {
                    let activeW = coordinator.activeVideoWidth
                    let activeH = coordinator.activeVideoHeight
                    let activeState = optical.isPaused ? "已暂停" : "播放中"
                    let verdict = coordinator.currentInterpolationVerdict

                    LabeledContent("补帧模式", value: coordinator.interpolationMode.rawValue)
                    LabeledContent("运行阶段", value: activeState)
                    LabeledContent("补帧生效判定", value: verdict.shortLabel)
                    Text(verdict.detailText)
                        .font(.caption2)
                        .foregroundStyle(verdict.isEffective ? .green : .secondary)
                    LabeledContent("视频分辨率", value: activeW > 0 ? "\(activeW)×\(activeH)" : "暂无")
                    LabeledContent("色深 / HDR", value: "\(optical.bitDepthLabel) · \(optical.hdrLabel) (EDR=\(coordinator.isEDREnabled ? "开" : "关"))")
                    LabeledContent("帧率 (源/输出)", value: "\(String(format: "%.1f", optical.sourceFPS)) / \(String(format: "%.1f", optical.actualOutputFPS)) fps")
                    LabeledContent("设备温度状态", value: ThermalLevel(state: coordinator.thermalState).rawValue)
                    LabeledContent(
                        "解码器 / 后端",
                        value: "\(optical.videoCodec.isEmpty ? "-" : optical.videoCodec) / \(optical.activeBackendLabel) (\(optical.clockSourceLabel))"
                    )
                    LabeledContent(
                        "ANE 光流计数",
                        value: "目标 \(optical.targetSummaryBadge) · 补帧 \(optical.interpolatedFrameCount) / 跳过 \(optical.skippedInterpolationCount) / 失败 \(optical.failedInterpolationCount) / 送显 \(optical.presentedFrameCount) / \(String(format: "%.1f", optical.averageInterpolationMs))ms"
                    )
                    if let currentURL = coordinator.currentURL {
                        LabeledContent("当前片源", value: currentURL.lastPathComponent)
                    }
                    if let optErr = optical.errorMessage ?? optical.lastInterpolationError {
                        Text("最近异常：\(optErr)")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }

                Section("诊断操作") {
                    Button {
                        coordinator.retryWithoutInterpolation()
                        dismiss()
                    } label: {
                        Label("切换为原帧率硬解直通播放", systemImage: "arrow.counterclockwise")
                    }

                    Button {
                        UIPasteboard.general.string = buildFullDiagnosticReport()
                        copiedFeedback = true
                    } label: {
                        Label(
                            copiedFeedback ? "已复制完整运行日志" : "一键复制完整运行日志",
                            systemImage: copiedFeedback ? "checkmark.circle.fill" : "doc.on.doc"
                        )
                    }

                    Button {
                        exportErrorMessage = nil
                        do {
                            let fileURL = try DiagnosticLogExporter.writeLogFile(content: buildFullDiagnosticReport())
                            NativeShareSheetPresenter.present(fileURL: fileURL) { err in
                                exportErrorMessage = err
                            }
                            exportedFeedback = true
                        } catch {
                            exportErrorMessage = "写入日志文件失败：\(error.localizedDescription)"
                        }
                    } label: {
                        Label(
                            exportedFeedback ? "已生成 .txt 诊断日志" : "导出诊断日志 (.txt)",
                            systemImage: exportedFeedback ? "checkmark.circle.fill" : "square.and.arrow.up"
                        )
                    }

                    if let exportErrorMessage {
                        Text(exportErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("运行期黑匣子采样（最近 \(coordinator.runtimeTimeline.count) 条，停播保留）") {
                    if coordinator.runtimeTimeline.isEmpty {
                        Text("暂无运行期采样（播放视频后每 2 秒自动采集，返回主界面后依然保留）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(coordinator.runtimeTimeline.suffix(30).reversed())) { sample in
                            Text(sample.formatLogLine())
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }

                Section("界面交互与开关审计（最近 \(coordinator.uiAuditLogs.count) 条）") {
                    if coordinator.uiAuditLogs.isEmpty {
                        Text("暂无开关切换审计记录")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(coordinator.uiAuditLogs.suffix(30).reversed().enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }

                Section("ANE 光流核日志（最近 \(optical.diagnosticLogs.count) 条）") {
                    if optical.diagnosticLogs.isEmpty {
                        Text("暂无光流核日志（打开视频后将自动采集）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(optical.diagnosticLogs.reversed().enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .onAppear {
                coordinator.runRealDeviceSelfCheck()
            }
            .navigationTitle("运行日志中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func buildFullDiagnosticReport() -> String {
        coordinator.exportDiagnosticReportText(includePersistedFallback: true)
    }
}
