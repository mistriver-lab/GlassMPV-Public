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
    @Published var speed: Double = 1.0
    @Published var currentURL: URL?
    @Published var isGeneratingSample: Bool = false
    @Published var isImportingFile: Bool = false
    @Published var selfCheckReport: String = ""
    @Published var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published var runtimeTimeline: [RuntimeTelemetrySample] = []
    @Published var lastSessionSummary: SessionDiagnosticSummary?
    @Published var uiAuditLogs: [String] = []

    let opticalFlowController = OpticalFlowPlayerController()
    private let thermalToken = ThermalObserverToken()
    private let telemetryLoopToken = TelemetryLoopToken()

    private static let auditTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init() {
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
            return "原帧率直通"
        }
        if vtSpatial2x && opticalFlowTargetFPS.allowsSpatial2x {
            return "光流 \(opticalFlowTargetFPS.shortBadge) + 超分2×"
        }
        return "光流 \(opticalFlowTargetFPS.shortBadge)"
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

    func closeToHome() {
        if currentURL != nil {
            captureRuntimeTelemetrySample()
            lastSessionSummary = buildCurrentSessionSummary()
        }
        recordUISwitch("closeToHome interp=\(interpolationMode.rawValue) target=\(opticalFlowTargetFPS.shortBadge)")
        stopRuntimeTelemetrySampling()
        opticalFlowController.stop()
        currentURL = nil
        isImportingFile = false
        isGeneratingSample = false
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
        }
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
            "ANE Target: \(opticalFlowController.targetSummaryBadge) (requested=\(opticalFlowController.requestedTargetFPS.shortBadge), effective=\(opticalFlowController.effectiveTargetFPS.shortBadge)) | ANE Backend: \(opticalFlowController.activeBackendLabel) | Clock: \(opticalFlowController.clockSourceLabel) | spatial2x=\(opticalFlowController.enableSpatial2xUpscale ? "ON" : "OFF")",
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

    func playBuiltInSampleVideo() {
        guard !isGeneratingSample else { return }
        isGeneratingSample = true
        opticalFlowController.clearError()
        opticalFlowController.appendLog("[sample] 开始生成内置 3 秒自测视频...")

        Task { [weak self] in
            guard let self else { return }
            do {
                let sampleURL = try await TestVideoGenerator.generateSampleMP4()
                self.isGeneratingSample = false
                self.open(url: sampleURL, isSecurityScoped: false)
            } catch {
                self.isGeneratingSample = false
                self.opticalFlowController.recordExternalError("内置测试视频生成失败：\(error.localizedDescription)")
            }
        }
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

        let opticalStatus = "\(opticalFlowController.capabilityDescription) | 模式=\(interpolationMode.rawValue) | 目标=\(opticalFlowController.targetSummaryBadge) | 后端=\(opticalFlowController.activeBackendLabel) | 时钟=\(opticalFlowController.clockSourceLabel) | 补帧=\(opticalFlowController.interpolatedFrameCount) | 跳帧追赶=\(opticalFlowController.skippedInterpolationCount) | 失败=\(opticalFlowController.failedInterpolationCount) | 送显=\(opticalFlowController.presentedFrameCount) | 平均耗时=\(String(format: "%.1f", opticalFlowController.averageInterpolationMs))ms | 实测FPS=\(String(format: "%.1f", opticalFlowController.actualOutputFPS)) | err=\(opticalFlowController.errorMessage ?? opticalFlowController.lastInterpolationError ?? "none")"

        let gateStatus = isSuperResolutionDisabledBy4K ? "已触发4K禁超分" : "允许2×空间超分"
        let lines = [
            "=== GlassMPV 真机 4 项体检报告 ===",
            "版本: \(AppReleaseInfo.displayVersion) | 模式: \(interpolationMode.rawValue) | 4K超分门控: \(gateStatus) | 补帧判定: \(verdict.shortLabel) (\(verdict.detailText))",
            "1. 屏幕 ProMotion 上限: \(maxScreenFPS) Hz \(maxScreenFPS >= 120 ? "(PASS)" : "(非120Hz)")",
            "2. 本地/相册导入沙盒通道: \(importCheck)",
            "3. ANE 光流与硬解直通核: \(opticalStatus)",
            "4. 黑匣子采样: 共 \(runtimeTimeline.count) 条（最近判定=\(runtimeTimeline.last?.verdictLabel ?? "无")）"
        ]
        selfCheckReport = lines.joined(separator: "\n")
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
        if interpolationMode == .vtOpticalFlow, let url = currentURL {
            let t = opticalFlowController.currentTime
            opticalFlowController.load(
                url: url,
                spatial2x: vtSpatial2x,
                targetFPS: target,
                startAt: t,
                autoPlay: !wasPaused,
                enableInterpolation: true
            )
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
        if interpolationMode == .vtOpticalFlow, let url = currentURL {
            let t = opticalFlowController.currentTime
            opticalFlowController.load(
                url: url,
                spatial2x: enabled,
                targetFPS: opticalFlowTargetFPS,
                startAt: t,
                autoPlay: !wasPaused,
                enableInterpolation: true
            )
            opticalFlowController.setSpeed(speed)
        }
    }

    func setSpeed(_ value: Double) {
        speed = value
        recordUISwitch("setSpeed(\(String(format: "%.2g", value))x)")
        opticalFlowController.setSpeed(value)
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

struct LiquidGlassPlayerView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject private var optical: OpticalFlowPlayerController

    @State private var showHUD: Bool = true
    @State private var showStatsHUD: Bool = true
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showURLPrompt: Bool = false
    @State private var streamURLInput: String = ""
    @State private var showEnhancementSheet: Bool = false
    @State private var showChangelogSheet: Bool = false
    @State private var showDiagnosticSheet: Bool = false
    @State private var isScrubbing: Bool = false
    @State private var scrubTime: Double = 0

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
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showHUD.toggle()
                        }
                    }
            }

            if coordinator.currentURL == nil {
                welcomeOverlay
            } else {
                if optical.errorMessage == nil,
                   (optical.isLoadingPipeline || optical.presentedFrameCount == 0) {
                    loadingStatusPill(
                        optical.pipelineStatusText.isEmpty ? "正在预热 ANE 光流缓冲..." : optical.pipelineStatusText
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
                    .padding(.top, showHUD ? 64 : 12)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.22), value: showHUD)
                    .transition(.opacity)
                }

                if showHUD {
                    playerHUDOverlay
                        .transition(.opacity)
                }
            }

            if coordinator.isImportingFile {
                loadingStatusPill("正在导入视频至沙盒...")
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

    // MARK: - Welcome Empty State

    private var welcomeOverlay: some View {
        GlassEffectContainer(spacing: 16) {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles.tv")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(.cyan)
                    Text("GlassMPV")
                        .font(.largeTitle.bold())
                    Text("VideoToolbox ANE 硬件光流真补帧 · 120Hz ProMotion")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))

                HStack(spacing: 12) {
                    Button {
                        coordinator.presentLocalVideoPicker()
                    } label: {
                        Label("打开本地视频", systemImage: "folder.badge.plus")
                            .font(.headline)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 13)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Capsule())
                    .glassEffect(.regular.tint(.cyan).interactive(), in: .capsule)

                    PhotosPicker(selection: $selectedPhotoItem, matching: .videos, photoLibrary: .shared()) {
                        Label("从相册选取", systemImage: "photo.on.rectangle.angled")
                            .font(.headline)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.indigo).interactive(), in: .capsule)
                }

                Button {
                    showURLPrompt = true
                } label: {
                    Label("网络串流", systemImage: "link")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)

                Button {
                    coordinator.playBuiltInSampleVideo()
                } label: {
                    HStack(spacing: 8) {
                        if coordinator.isGeneratingSample {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "play.circle.fill")
                        }
                        Text(coordinator.isGeneratingSample ? "正在生成内置测试视频..." : "一键自测（内置 3 秒测试视频）")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .disabled(coordinator.isGeneratingSample)
                .glassEffect(.regular.tint(.green).interactive(), in: .capsule)

                HStack(spacing: 10) {
                    Button {
                        showEnhancementSheet = true
                    } label: {
                        Label("补帧：\(coordinator.currentEnhancementSummary)", systemImage: "wand.and.stars")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)

                    Button {
                        showDiagnosticSheet = true
                    } label: {
                        Label("诊断日志", systemImage: "stethoscope")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }

                Button {
                    showChangelogSheet = true
                } label: {
                    Label("GlassMPV \(AppReleaseInfo.displayVersion) · 更新日志", systemImage: "doc.text")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .padding()
        }
    }

    // MARK: - Liquid Glass Floating HUD

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

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Text(formatTime(displayTime))
                        .font(.caption.monospacedDigit())
                        .frame(width: 48, alignment: .leading)

                    Slider(
                        value: Binding(
                            get: { displayTime },
                            set: { newVal in
                                isScrubbing = true
                                scrubTime = newVal
                            }
                        ),
                        in: 0...max(coordinator.activeDuration, 1),
                        onEditingChanged: { editing in
                            if !editing {
                                coordinator.seek(to: scrubTime)
                                isScrubbing = false
                            }
                        }
                    )
                    .tint(.cyan)

                    Text(formatTime(coordinator.activeDuration))
                        .font(.caption.monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                }

                HStack(spacing: 14) {
                    Button {
                        coordinator.seekRelative(-10)
                    } label: {
                        Image(systemName: "gobackward.10")
                            .font(.title3)
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)

                    Button {
                        coordinator.togglePlayPause()
                    } label: {
                        Image(systemName: coordinator.activePaused ? "play.fill" : "pause.fill")
                            .font(.title2)
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.cyan).interactive(), in: .circle)

                    Button {
                        coordinator.seekRelative(10)
                    } label: {
                        Image(systemName: "goforward.10")
                            .font(.title3)
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)

                    Spacer()

                    Menu {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                            Button("\(rate, specifier: "%.2g")x") {
                                coordinator.setSpeed(rate)
                            }
                        }
                    } label: {
                        Text("\(coordinator.speed, specifier: "%.2g")x")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                    .glassEffect(.regular.interactive(), in: .capsule)

                    Button {
                        showEnhancementSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.stars")
                            Text("光流设置")
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.indigo).interactive(), in: .capsule)
                }
            }
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    private var toolbarActionButtons: some View {
        HStack(spacing: 10) {
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
                showDiagnosticSheet = true
            } label: {
                Image(systemName: "stethoscope")
                    .font(.body.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: .circle)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showStatsHUD.toggle()
                }
            } label: {
                Image(systemName: showStatsHUD ? "info.circle.fill" : "info.circle")
                    .font(.body.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .glassEffect(
                showStatsHUD ? .regular.tint(.cyan).interactive() : .regular.interactive(),
                in: .circle
            )
        }
    }

    private var topRightMetricsBadge: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showStatsHUD.toggle()
            }
        } label: {
            VStack(alignment: .trailing, spacing: 2) {
                Text(activeResolutionText)
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
        .glassEffect(.regular.interactive(), in: .capsule)
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
            Label("播放或光流遇到异常", systemImage: "exclamationmark.triangle.fill")
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
                        Text("以原帧率直通重试")
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
                    Text("查看诊断日志")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)

                Button {
                    coordinator.closeToHome()
                } label: {
                    Text("返回主界面")
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

// MARK: - Optical Flow Control Sheet

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
                Section("补帧模式（适配 iPhone 15 PM 120Hz）") {
                    ForEach(InterpolationMode.allCases) { mode in
                        Button {
                            coordinator.setInterpolation(mode)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.rawValue)
                                        .foregroundStyle(.primary)
                                    Text(interpolationHint(mode))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if coordinator.interpolationMode == mode {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.cyan)
                                }
                            }
                        }
                    }

                    if let gatedReason = coordinator.superResolutionDisabledReason {
                        Label(gatedReason, systemImage: "4k.tv.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if coordinator.interpolationMode == .vtOpticalFlow {
                    Section("ANE 目标帧率与 2× 硬件超分") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("ANE 目标帧率")
                                Spacer()
                                Text("当前 \(optical.targetSummaryBadge)")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.cyan)
                            }

                            Picker("ANE 目标帧率", selection: Binding(
                                get: { coordinator.opticalFlowTargetFPS },
                                set: { coordinator.setOpticalFlowTargetFPS($0) }
                            )) {
                                ForEach(OpticalFlowTargetFPS.allCases) { tier in
                                    Text(tier.shortBadge).tag(tier)
                                }
                            }
                            .pickerStyle(.segmented)

                            Text("全档位优先 LowLatency (420v) 低功耗低内存管线；60/96/120fps 自动从 720p 起跑并按算力/温度阶梯降分辨率与目标帧率")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)

                        Toggle("同步开启 ANE 2× 硬件超分", isOn: Binding(
                            get: { coordinator.vtSpatial2x },
                            set: { coordinator.setVTSpatial2x($0) }
                        ))
                        .disabled(coordinator.isSuperResolutionDisabledBy4K || !coordinator.opticalFlowTargetFPS.allowsSpatial2x)

                        if !coordinator.opticalFlowTargetFPS.allowsSpatial2x {
                            Text("仅 2× 单相档位支持同步开启 ANE 2× 空间超分（\(coordinator.opticalFlowTargetFPS.shortBadge) 档位需多相补帧，已自动互斥关闭）")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("关于与更新日志") {
                    LabeledContent("当前版本", value: AppReleaseInfo.displayVersion)
                    ForEach(AppReleaseInfo.changelog) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(entry.version) · \(entry.date)")
                                .font(.caption.weight(.semibold))
                            ForEach(entry.highlights, id: \.self) { item in
                                Text("• \(item)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("ANE 光流控制台")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func interpolationHint(_ mode: InterpolationMode) -> String {
        switch mode {
        case .off:
            return "关闭光流，按片源原生帧率硬解直通输出（最低功耗）"
        case .vtOpticalFlow:
            return "Apple VideoToolbox ANE 硬件光流真补帧（支持 2×/60/72/96/120fps 多档位与智能热/预算降档）"
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
    @State private var copiedSelfCheckFeedback: Bool = false
    @State private var exportedFeedback: Bool = false
    @State private var exportErrorMessage: String?

    init(coordinator: PlayerCoordinator) {
        self.coordinator = coordinator
        self._optical = ObservedObject(wrappedValue: coordinator.opticalFlowController)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("真机 4 项体检") {
                    Button {
                        coordinator.runRealDeviceSelfCheck()
                    } label: {
                        Label("一键执行真机 4 项体检", systemImage: "stethoscope.circle.fill")
                    }

                    if !coordinator.selfCheckReport.isEmpty {
                        Text(coordinator.selfCheckReport)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)

                        Button {
                            UIPasteboard.general.string = coordinator.selfCheckReport
                            copiedSelfCheckFeedback = true
                        } label: {
                            Label(
                                copiedSelfCheckFeedback ? "已复制体检报告" : "一键复制体检报告",
                                systemImage: copiedSelfCheckFeedback ? "checkmark.circle.fill" : "doc.on.clipboard"
                            )
                        }
                    }
                }

                Section("ANE 光流与播放状态") {
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
                    LabeledContent("色深 / HDR", value: "\(optical.bitDepthLabel) · \(optical.hdrLabel)")
                    LabeledContent("帧率 (源/输出)", value: "\(String(format: "%.1f", optical.sourceFPS)) / \(String(format: "%.1f", optical.actualOutputFPS)) fps")
                    LabeledContent("设备温度状态", value: ThermalLevel(state: coordinator.thermalState).rawValue)
                    LabeledContent(
                        "解码器 / 后端",
                        value: "\(optical.videoCodec.isEmpty ? "-" : optical.videoCodec) / \(optical.activeBackendLabel) (\(optical.clockSourceLabel))"
                    )
                    LabeledContent(
                        "ANE 光流状态",
                        value: "\(optical.capabilityDescription) (目标 \(optical.targetSummaryBadge) · 后端 \(optical.activeBackendLabel) · 时钟 \(optical.clockSourceLabel) · 补帧 \(optical.interpolatedFrameCount) / 追赶跳过 \(optical.skippedInterpolationCount) / 失败 \(optical.failedInterpolationCount) / 送显 \(optical.presentedFrameCount) / 耗时 \(String(format: "%.1f", optical.averageInterpolationMs))ms)"
                    )
                    if let currentURL = coordinator.currentURL {
                        LabeledContent("当前片源", value: currentURL.lastPathComponent)
                    }
                    if let optErr = optical.errorMessage ?? optical.lastInterpolationError {
                        Text("光流最近错误：\(optErr)")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }

                Section("快捷排查动作") {
                    Button {
                        coordinator.playBuiltInSampleVideo()
                        dismiss()
                    } label: {
                        Label("一键生成并播放内置 3 秒测试视频", systemImage: "play.circle.fill")
                    }

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
                            copiedFeedback ? "已复制全部诊断日志" : "一键复制全部诊断日志",
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
                            exportedFeedback ? "已生成 .txt 诊断日志文件" : "导出诊断日志 (.txt)",
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
            .navigationTitle("播放诊断中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func buildFullDiagnosticReport() -> String {
        if coordinator.selfCheckReport.isEmpty {
            coordinator.runRealDeviceSelfCheck()
        }
        let maxScreenFPS = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.maximumFramesPerSecond ?? 60
        let deviceInfo = DeviceDiagnosticsSampler.deviceSummaryLine(maxScreenFPS: maxScreenFPS)

        let summary: SessionDiagnosticSummary
        var extraTelemetry: [String] = []
        if coordinator.currentURL != nil {
            summary = coordinator.buildCurrentSessionSummary()
        } else if let cached = coordinator.lastSessionSummary {
            summary = cached
            extraTelemetry.append("Snapshot Source: last-session (cached before closeToHome)")
        } else {
            summary = coordinator.buildCurrentSessionSummary()
        }

        return DiagnosticLogExporter.buildReport(
            version: AppReleaseInfo.displayVersion,
            deviceInfo: deviceInfo,
            engineName: summary.engineName,
            playbackState: summary.playbackState,
            resolution: summary.resolution,
            fpsSummary: summary.fpsSummary,
            decoderSummary: summary.decoderSummary,
            is4KGated: summary.is4KGated,
            telemetrySummary: summary.telemetrySummary + extraTelemetry,
            runtimeTimeline: coordinator.runtimeTimeline.map { $0.formatLogLine() },
            uiAuditLogs: coordinator.uiAuditLogs,
            selfCheck: coordinator.selfCheckReport,
            opticalLogs: optical.diagnosticLogs
        )
    }
}
