import AVFoundation
import Combine
import Foundation
import MPVUI
import QuartzCore
import SwiftUI
import UIKit

/// 播放阶段 ProMotion 120Hz 刷新率保活与实际刷新率采样器
@MainActor
final class ProMotionDisplayLinkKeeper {
    private final class DisplayLinkBox: @unchecked Sendable {
        let link: CADisplayLink
        init(_ link: CADisplayLink) { self.link = link }
    }

    private final class DisplayLinkHolder: @unchecked Sendable {
        var link: CADisplayLink?
        deinit {
            if let link {
                let box = DisplayLinkBox(link)
                if Thread.isMainThread {
                    box.link.invalidate()
                } else {
                    DispatchQueue.main.async {
                        box.link.invalidate()
                    }
                }
            }
        }
    }

    private final class DisplayLinkProxy: NSObject {
        weak var owner: ProMotionDisplayLinkKeeper?

        @MainActor
        @objc func handleTick(_ link: CADisplayLink) {
            owner?.handleDisplayLinkTick(link)
        }
    }

    private(set) var isActive: Bool = false
    private(set) var measuredRefreshHz: Double = 0
    var onMeasuredRefreshUpdate: ((Double) -> Void)?

    private let linkHolder = DisplayLinkHolder()
    private var proxy: DisplayLinkProxy?
    private var lastSampleTimestamp: CFTimeInterval?
    private var recentDeltas: [CFTimeInterval] = []
    private var lastPublishTimestamp: CFTimeInterval = 0

    func start(preferredMaxFPS: Int = 120) {
        let clampedMax = Float(max(60, preferredMaxFPS))
        let minRate: Float = clampedMax >= 120 ? 80 : 60
        let range = CAFrameRateRange(minimum: minRate, maximum: clampedMax, preferred: clampedMax)

        if let existing = linkHolder.link {
            existing.preferredFrameRateRange = range
            isActive = true
            return
        }

        let proxy = DisplayLinkProxy()
        proxy.owner = self
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.handleTick(_:)))
        link.preferredFrameRateRange = range
        link.add(to: .main, forMode: .common)
        self.proxy = proxy
        self.linkHolder.link = link
        self.isActive = true
    }

    func stop() {
        linkHolder.link?.invalidate()
        linkHolder.link = nil
        proxy = nil
        lastSampleTimestamp = nil
        recentDeltas.removeAll()
        lastPublishTimestamp = 0
        isActive = false
        measuredRefreshHz = 0
    }

    @discardableResult
    func recordSample(timestamp: CFTimeInterval) -> Double? {
        defer { lastSampleTimestamp = timestamp }
        guard let previous = lastSampleTimestamp else { return nil }
        let delta = timestamp - previous
        guard delta > 0.002 && delta < 0.25 else { return nil }

        recentDeltas.append(delta)
        if recentDeltas.count > 30 {
            recentDeltas.removeFirst(recentDeltas.count - 30)
        }
        guard recentDeltas.count >= 4 else { return nil }
        let avgDelta = recentDeltas.reduce(0, +) / Double(recentDeltas.count)
        guard avgDelta > 0 else { return nil }
        let hz = 1.0 / avgDelta
        measuredRefreshHz = hz
        return hz
    }

    private func handleDisplayLinkTick(_ link: CADisplayLink) {
        let now = link.timestamp
        if let hz = recordSample(timestamp: now), now - lastPublishTimestamp >= 0.25 {
            lastPublishTimestamp = now
            onMeasuredRefreshUpdate?(hz)
        }
    }
}

private final class MPVTaskBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    func store(_ task: Task<Void, Never>) {
        lock.lock()
        tasks.append(task)
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let active = tasks
        tasks.removeAll()
        lock.unlock()
        for task in active {
            task.cancel()
        }
    }

    deinit {
        cancelAll()
    }
}

/// 基于开源 MPVUI (0.11.0) 的播放控制适配器（保留 Metal gpu-next 58 个 GLSL 着色器与 120Hz 时域平滑）
@MainActor
final class MPVPlayerController: ObservableObject {
    static let defaultConfiguration = MPVPlayerConfiguration(
        automaticallyPlays: true,
        hardwareDecoding: .automatic,
        logLevel: .info,
        isLoopingEnabled: true,
        videoOutput: .metal
    )

    @Published var isPaused: Bool = true
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var sourceFPS: Double = 0
    @Published var outputFPS: Double = 0
    @Published var displaySyncFPS: Double = 0
    @Published var targetDisplaySyncFPS: Double = 0
    @Published var measuredProMotionFPS: Double = 0
    @Published var isProMotionKeeperActive: Bool = false
    @Published var videoWidth: Int = 0
    @Published var videoHeight: Int = 0
    @Published var videoCodec: String = ""
    @Published var hardwareDecoder: String = ""
    @Published var decodedPixelFormat: String = ""
    @Published var bitDepthLabel: String = "--"
    @Published var hdrLabel: String = "SDR"
    @Published var isHDRActive: Bool = false
    @Published var droppedFrames: Int64 = 0
    @Published var mistimedFrames: Int64 = 0
    @Published var delayedFrames: Int64 = 0
    @Published var freshRenderPassCount: Int = 0
    @Published var redrawRenderPassCount: Int = 0
    @Published var activeShaderCount: Int = 0
    @Published var isSuperResolutionGatedBy4K: Bool = false
    @Published var statusMessage: String = ""
    @Published var playbackState: String = "待机"
    @Published var lastErrorMessage: String?
    @Published var diagnosticLogs: [String] = []
    @Published var isInitialized: Bool = false
    @Published var latestMPVProbe: MPVProbeSnapshot?
    @Published var lastMeasuredProMotionFPS: Double = 0

    let player: MPVPlayer

    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var on4KSuperResolutionGated: (() -> Void)?

    private let taskBag = MPVTaskBag()
    private let proMotionKeeper = ProMotionDisplayLinkKeeper()
    private var currentPreset: ShaderPreset = .off
    private var currentExtras: Set<String> = []
    private var currentInterpolation: InterpolationMode = .off
    private var currentSpeed: Double = 1.0
    private var lastAppliedReadyGeneration: UInt64?
    private var last4KGateLoggedSize: (Int, Int)?
    private var isStoppedByUser: Bool = false
    private var lastAppliedTscale: String = ""
    private var lastProbeLoggedSignature: String?

    init(configuration: MPVPlayerConfiguration = MPVPlayerController.defaultConfiguration) {
        self.player = MPVPlayer(configuration: configuration)
        self.player.setDiagnosticsEnabled(true)
        self.player.logHandler = { [weak self] logMsg in
            self?.handleIncomingLog(logMsg)
        }

        self.proMotionKeeper.onMeasuredRefreshUpdate = { [weak self] hz in
            self?.measuredProMotionFPS = hz
            if hz > 0 {
                self?.lastMeasuredProMotionFPS = hz
            }
        }

        self.isInitialized = true
        self.playbackState = "内核就绪"
        appendLog("[init] MPVUI 播放器内核已就绪 (output=\(configuration.videoOutput.rawValue))")
        startObservingPlayer()
    }

    func load(url: URL, autoPlay: Bool = true) {
        let target = url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString
        appendLog("[load] 请求播放: \(target) (autoPlay=\(autoPlay))")

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        isStoppedByUser = false
        latestMPVProbe = nil
        lastProbeLoggedSignature = nil
        lastAppliedTscale = ""
        lastMeasuredProMotionFPS = 0
        lastErrorMessage = nil
        statusMessage = ""
        currentTime = 0
        duration = 0
        sourceFPS = 0
        outputFPS = 0
        displaySyncFPS = 0
        targetDisplaySyncFPS = 0
        measuredProMotionFPS = 0
        videoWidth = 0
        videoHeight = 0
        videoCodec = ""
        hardwareDecoder = ""
        decodedPixelFormat = ""
        bitDepthLabel = "--"
        hdrLabel = "SDR"
        isHDRActive = false
        droppedFrames = 0
        mistimedFrames = 0
        delayedFrames = 0
        freshRenderPassCount = 0
        redrawRenderPassCount = 0
        isSuperResolutionGatedBy4K = false
        last4KGateLoggedSize = nil
        lastAppliedReadyGeneration = nil
        isInitialized = true
        isPaused = !autoPlay
        playbackState = autoPlay ? "正在加载媒体..." : "正在加载媒体(暂停)..."

        player.load(url, playAutomatically: autoPlay)
        if abs(currentSpeed - 1.0) > 0.001 {
            player.setPlaybackRate(currentSpeed)
        }
        applyInterpolation(currentInterpolation)
        syncProMotionKeeper()
    }

    func togglePlayPause() {
        player.togglePlayback()
    }

    func pause() {
        player.pause()
        isPaused = true
        syncProMotionKeeper()
    }

    func seek(to seconds: Double) {
        player.seek(to: .seconds(max(0, seconds)))
    }

    func seekRelative(_ delta: Double) {
        player.seek(by: .seconds(delta))
    }

    func setSpeed(_ speed: Double) {
        currentSpeed = speed
        player.setPlaybackRate(speed)
    }

    func applyShaders(preset: ShaderPreset, extras: Set<String>) {
        currentPreset = preset
        currentExtras = extras

        if SuperResolutionPolicy.isAlready4K(width: videoWidth, height: videoHeight) {
            isSuperResolutionGatedBy4K = true
            let filtered = SingleShaderOption.filteredFor4K(preset: preset, extras: extras)
            let hadBlockedUpscaler = preset.id != ShaderPreset.off.id || filtered.extras.count != extras.count
            if hadBlockedUpscaler {
                currentPreset = filtered.preset
                currentExtras = filtered.extras
                on4KSuperResolutionGated?()
            }

            let paths = SingleShaderOption.resolvedShaderPaths(preset: filtered.preset, extras: filtered.extras)
            activeShaderCount = paths.count
            if paths.isEmpty {
                player.executeCommand("change-list", arguments: ["glsl-shaders", "clr", ""])
            } else {
                let joined = paths.joined(separator: ":")
                player.executeCommand("change-list", arguments: ["glsl-shaders", "set", joined])
                appendLog("[shader] 4K片源仅保留 \(paths.count) 个非放大着色器")
            }

            let currentSize = (videoWidth, videoHeight)
            if last4KGateLoggedSize.map({ $0 != currentSize }) ?? true || hadBlockedUpscaler {
                last4KGateLoggedSize = currentSize
                let reason = SuperResolutionPolicy.disabledReason(width: videoWidth, height: videoHeight) ?? "片源已达 4K，自动禁用放大类超分"
                appendLog("[shader] \(reason)")
            }
            return
        }

        isSuperResolutionGatedBy4K = false
        last4KGateLoggedSize = nil
        let paths = SingleShaderOption.resolvedShaderPaths(preset: preset, extras: extras)
        activeShaderCount = paths.count

        if paths.isEmpty {
            player.executeCommand("change-list", arguments: ["glsl-shaders", "clr", ""])
            appendLog("[shader] 已清空着色器（原画直出）")
        } else {
            // Unix / iOS 下 mpv 使用冒号分隔多个着色器路径
            let joined = paths.joined(separator: ":")
            player.executeCommand("change-list", arguments: ["glsl-shaders", "set", joined])
            appendLog("[shader] 应用 \(paths.count) 个 GLSL 着色器 (\(preset.title))")
        }
    }

    func applyInterpolation(_ mode: InterpolationMode) {
        currentInterpolation = mode

        switch mode {
        case .mpvSmooth120Hz:
            let screenMaxFPS = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.screen.maximumFramesPerSecond ?? 120
            let targetDisplayFPS = max(screenMaxFPS, 60)
            let is4K = SuperResolutionPolicy.isAlready4K(width: videoWidth, height: videoHeight)
            let tscale = is4K ? "linear" : "mitchell"
            lastAppliedTscale = tscale

            player.setProperty("video-sync", to: "display-resample")
            player.setProperty("interpolation", to: "yes")
            player.setProperty("interpolation-threshold", to: "-1")
            player.setProperty("interpolation-preserve", to: "yes")
            player.setProperty("tscale", to: tscale)
            player.setProperty("display-fps-override", to: "\(targetDisplayFPS)")
            targetDisplaySyncFPS = Double(targetDisplayFPS)
            syncProMotionKeeper()
            let scaleHint = is4K ? " (4K自适应tscale=linear)" : ""
            appendLog("[interp] 开启 \(targetDisplayFPS)Hz 时域平滑\(scaleHint) (display-resample + interpolation-threshold=-1 + interpolation-preserve=yes + tscale=\(tscale) + display-fps-override=\(targetDisplayFPS))")
            if !isStoppedByUser {
                probeInterpolationState()
            }
        case .off, .vtOpticalFlow2x:
            lastAppliedTscale = ""
            player.setProperty("interpolation", to: "no")
            player.setProperty("interpolation-preserve", to: "no")
            player.setProperty("interpolation-threshold", to: "0.01")
            player.setProperty("video-sync", to: "audio")
            player.setProperty("display-fps-override", to: "0")
            targetDisplaySyncFPS = 0
            displaySyncFPS = 0
            syncProMotionKeeper()
            appendLog("[interp] 关闭时域插值 (video-sync=audio)")
        }
    }

    func probeInterpolationState() {
        guard isInitialized, !isStoppedByUser,
              (player.isPlaybackReady || player.hasVideoFrame || videoWidth > 0) else {
            return
        }
        player.executeCommand(
            "expand-properties",
            arguments: [
                "print-text",
                "[mpv-probe] sync_active=${display-sync-active} video_sync=${video-sync} interp=${interpolation} tscale=${tscale} vsync_ratio=${vsync-ratio} disp_fps=${display-fps} est_disp=${estimated-display-fps}"
            ]
        )
    }

    func releaseMediaForExternalEngine() {
        if isStoppedByUser && isPaused {
            return
        }
        isStoppedByUser = true
        player.stop()
        isPaused = true
        syncProMotionKeeper()
        playbackState = "已释放(外部引擎接管)"
        appendLog("[lifecycle] 已停止 MPV 并释放硬解会话，交由 ANE 光流核接管")
    }

    func clearError() {
        lastErrorMessage = nil
        player.clearLastError()
    }

    func recordExternalError(_ message: String) {
        lastErrorMessage = message
        statusMessage = message
        playbackState = "打开失败"
        appendLog("[error] \(message)")
    }

    func appendLog(_ line: String) {
        let stamp = Self.logTimeFormatter.string(from: Date())
        diagnosticLogs.append("[\(stamp)] \(line)")
        if diagnosticLogs.count > 500 {
            diagnosticLogs.removeFirst(diagnosticLogs.count - 500)
        }
    }

    func refreshDiagnosticsSnapshot() {
        let diag = player.playbackDiagnostics
        let info = player.mediaInformation

        if let containerFPS = diag.containerFramesPerSecond, containerFPS > 0 {
            sourceFPS = containerFPS
        } else if let mediaFPS = info.framesPerSecond, mediaFPS > 0, sourceFPS <= 0 {
            sourceFPS = mediaFPS
        }

        if let vfFPS = diag.estimatedFilterFramesPerSecond, vfFPS > 0 {
            outputFPS = vfFPS
        } else if let decFPS = diag.estimatedDecodedFramesPerSecond, decFPS > 0 {
            outputFPS = decFPS
        } else if let mediaFPS = info.framesPerSecond, mediaFPS > 0 {
            outputFPS = mediaFPS
        }

        if let dispFPS = diag.estimatedDisplayFramesPerSecond ?? diag.nominalDisplayFramesPerSecond, dispFPS > 0 {
            displaySyncFPS = dispFPS
        } else {
            displaySyncFPS = 0
        }
        freshRenderPassCount = diag.freshRenderPasses?.count ?? 0
        redrawRenderPassCount = diag.redrawRenderPasses?.count ?? 0
        droppedFrames = (diag.decoderDroppedFrames ?? 0) + (diag.outputDroppedFrames ?? 0)
        mistimedFrames = diag.mistimedFrames ?? 0
        delayedFrames = diag.delayedFrames ?? 0

        if let codec = diag.decoder.codec ?? info.videoCodec, !codec.isEmpty {
            videoCodec = codec
        }
        if let pixFmt = diag.decoder.decodedPixelFormat ?? info.hdr.decoded.pixelFormat ?? info.hdr.source.pixelFormat,
           !pixFmt.isEmpty {
            decodedPixelFormat = pixFmt
        }
        if let bitDepth = info.hdr.decoded.bitDepth ?? info.hdr.source.bitDepth, bitDepth > 0 {
            bitDepthLabel = "\(bitDepth)-bit"
        } else if !decodedPixelFormat.isEmpty {
            bitDepthLabel = PlaybackHUDMetrics.parseBitDepth(fromPixelFormat: decodedPixelFormat)
        }
        updateHDRMetadata(from: info.hdr)

        switch diag.decoder.session {
        case .hardware(let name):
            hardwareDecoder = name
        case .software:
            hardwareDecoder = "software"
        case .unknown:
            if let hw = info.hardwareDecoder, !hw.isEmpty {
                hardwareDecoder = hw
            }
        }
    }

    func stopPlayback() {
        isStoppedByUser = true
        player.stop()
        isPaused = true
        syncProMotionKeeper()
        currentTime = 0
        duration = 0
        sourceFPS = 0
        outputFPS = 0
        displaySyncFPS = 0
        targetDisplaySyncFPS = 0
        measuredProMotionFPS = 0
        videoWidth = 0
        videoHeight = 0
        videoCodec = ""
        hardwareDecoder = ""
        decodedPixelFormat = ""
        bitDepthLabel = "--"
        hdrLabel = "SDR"
        isHDRActive = false
        droppedFrames = 0
        mistimedFrames = 0
        delayedFrames = 0
        freshRenderPassCount = 0
        redrawRenderPassCount = 0
        activeShaderCount = 0
        isSuperResolutionGatedBy4K = false
        last4KGateLoggedSize = nil
        lastAppliedReadyGeneration = nil
        lastAppliedTscale = ""
        lastErrorMessage = nil
        statusMessage = ""
        playbackState = "待机"
        appendLog("[lifecycle] 已停止播放并返回主界面")
    }

    func shutdown() {
        isStoppedByUser = true
        player.stop()
        isPaused = true
        isInitialized = false
        syncProMotionKeeper()
        playbackState = "已停止"
        appendLog("[lifecycle] 播放器已停止")
    }

    private func syncProMotionKeeper() {
        let shouldRun = isInitialized && currentInterpolation == .mpvSmooth120Hz && !isPaused
        if shouldRun {
            let maxFPS = targetDisplaySyncFPS > 0 ? Int(targetDisplaySyncFPS) : 120
            proMotionKeeper.start(preferredMaxFPS: maxFPS)
        } else {
            proMotionKeeper.stop()
            measuredProMotionFPS = 0
        }
        isProMotionKeeperActive = proMotionKeeper.isActive
    }

    // MARK: - Private Stream Observation

    private func startObservingPlayer() {
        let eventStream = player.makeEventStream()
        let timingStream = player.makeTimingStream()

        let eventTask = Task { @MainActor [weak self] in
            for await event in eventStream {
                guard let self, !Task.isCancelled else { break }
                self.handlePlaybackEvent(event)
            }
        }
        taskBag.store(eventTask)

        let timingTask = Task { @MainActor [weak self] in
            for await timing in timingStream {
                guard let self, !Task.isCancelled else { break }
                guard self.isInitialized, !self.isStoppedByUser else { continue }
                self.currentTime = Self.seconds(from: timing.position)
                let dur = Self.seconds(from: timing.duration)
                if dur > 0 {
                    self.duration = dur
                }
                self.refreshDiagnosticsSnapshot()
            }
        }
        taskBag.store(timingTask)
    }

    private func handleIncomingLog(_ logMsg: MPVLogMessage) {
        if logMsg.message.contains("[mpv-probe]") {
            if let parsed = MPVProbeSnapshot.parse(from: logMsg.message) {
                latestMPVProbe = parsed
                if parsed.stateSignature != lastProbeLoggedSignature {
                    lastProbeLoggedSignature = parsed.stateSignature
                    appendLog("[probe] \(parsed.summaryText)")
                }
            }
            return
        }

        let shouldLog: Bool
        switch logMsg.level {
        case .fatal, .error, .warning:
            shouldLog = true
        case .info, .status, .verbose, .debug, .trace:
            let combined = "\(logMsg.prefix) \(logMsg.message)".lowercased()
            let keywords = [
                "display-sync",
                "interpolation",
                "tscale",
                "videotoolbox",
                "gpu-next",
                "vsync",
                "swapchain",
                "shader",
                "error",
                "fail",
                "drop",
                "vo/"
            ]
            shouldLog = keywords.contains(where: { combined.contains($0) })
        case .none:
            shouldLog = false
        }
        guard shouldLog else { return }
        appendLog("[\(logMsg.level.rawValue)][\(logMsg.prefix)] \(logMsg.message)")
    }

    private func handlePlaybackEvent(_ event: MPVPlaybackEvent) {
        guard !isStoppedByUser else { return }
        switch event.change {
        case .snapshot(let snapshot):
            isPaused = snapshot.isPaused
            currentTime = Self.seconds(from: snapshot.position)
            let dur = Self.seconds(from: snapshot.duration)
            if dur > 0 {
                duration = dur
            }
            applyMediaInfo(snapshot.mediaInformation)
            applyState(snapshot.state, generation: event.generation)
            syncProMotionKeeper()

        case .stateChanged(let state):
            applyState(state, generation: event.generation)
            syncProMotionKeeper()

        case .pauseChanged(let paused):
            isPaused = paused
            syncProMotionKeeper()

        case .readinessChanged(let ready):
            if ready {
                reapplyActivePipelineIfNeeded(for: event.generation)
            }

        case .mediaInformationChanged(let info):
            applyMediaInfo(info)

        case .error(let error, let fatal):
            let msg = error.message
            appendLog("[\(fatal ? "fatal" : "warn")] \(msg)")
            statusMessage = msg
            if fatal {
                lastErrorMessage = msg
                playbackState = "播放失败"
            }

        case .audioChanged, .chapterChanged, .videoFeaturesChanged, .seekCompleted, .externalTrackLoaded:
            break
        }
        refreshDiagnosticsSnapshot()
    }

    private func applyState(_ state: MPVPlaybackState, generation: UInt64) {
        switch state {
        case .idle:
            playbackState = "待机"
        case .loading:
            playbackState = "正在打开媒体..."
        case .ready:
            playbackState = "已加载，开始解码..."
            reapplyActivePipelineIfNeeded(for: generation)
        case .playing:
            isPaused = false
            playbackState = "播放中"
            reapplyActivePipelineIfNeeded(for: generation)
        case .paused:
            isPaused = true
            playbackState = "已暂停"
        case .buffering:
            playbackState = "缓冲中..."
        case .seeking:
            playbackState = "定位中..."
        case .ended:
            playbackState = "播放结束"
        case .stopped:
            playbackState = "已停止"
        case .failed(let error):
            playbackState = "播放失败"
            lastErrorMessage = error.message
            statusMessage = error.message
        }
    }

    private func applyMediaInfo(_ info: MPVMediaInformation) {
        if let dims = info.presentationDimensions ?? info.dimensions {
            videoWidth = dims.width
            videoHeight = dims.height
            let is4K = SuperResolutionPolicy.isAlready4K(width: videoWidth, height: videoHeight)
            let hasBlockedUpscalersUnder4K = is4K && (
                currentPreset.id != ShaderPreset.off.id
                    || currentExtras.contains(where: { SingleShaderOption.isUpscalerOption(id: $0) })
            )
            if is4K != isSuperResolutionGatedBy4K || hasBlockedUpscalersUnder4K {
                applyShaders(preset: currentPreset, extras: currentExtras)
            }
            if currentInterpolation == .mpvSmooth120Hz {
                let desiredTscale = is4K ? "linear" : "mitchell"
                if desiredTscale != lastAppliedTscale {
                    applyInterpolation(.mpvSmooth120Hz)
                }
            }
        }
        if let fps = info.framesPerSecond, fps > 0 {
            sourceFPS = fps
            if outputFPS <= 0 {
                outputFPS = fps
            }
        }
        if let dur = info.duration {
            let secs = Self.seconds(from: dur)
            if secs > 0 {
                duration = secs
            }
        }
        if let codec = info.videoCodec, !codec.isEmpty {
            videoCodec = codec
        }
        if let hw = info.hardwareDecoder, !hw.isEmpty {
            hardwareDecoder = hw
        }
        if let pixFmt = info.hdr.decoded.pixelFormat ?? info.hdr.source.pixelFormat, !pixFmt.isEmpty {
            decodedPixelFormat = pixFmt
        }
        if let bitDepth = info.hdr.decoded.bitDepth ?? info.hdr.source.bitDepth, bitDepth > 0 {
            bitDepthLabel = "\(bitDepth)-bit"
        } else if !decodedPixelFormat.isEmpty {
            bitDepthLabel = PlaybackHUDMetrics.parseBitDepth(fromPixelFormat: decodedPixelFormat)
        }
        updateHDRMetadata(from: info.hdr)
    }

    private func updateHDRMetadata(from hdr: MPVHDRStatus) {
        let transferName: String?
        switch hdr.transferFunction {
        case .pq:
            transferName = "pq"
        case .hlg:
            transferName = "hlg"
        default:
            transferName = hdr.transferFunction.mpvValue
        }
        isHDRActive = hdr.isHDRActive
        hdrLabel = PlaybackHUDMetrics.formatHDRTag(
            isHDRContent: hdr.isHDRContent,
            transferName: transferName,
            isHDRActive: hdr.isHDRActive
        )
    }

    private func reapplyActivePipelineIfNeeded(for generation: UInt64) {
        guard lastAppliedReadyGeneration != generation else { return }
        lastAppliedReadyGeneration = generation

        if currentInterpolation != .off {
            applyInterpolation(currentInterpolation)
        }
        let paths = SingleShaderOption.resolvedShaderPaths(preset: currentPreset, extras: currentExtras)
        if !paths.isEmpty {
            applyShaders(preset: currentPreset, extras: currentExtras)
        }
    }

    private static func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
    }
}

/// SwiftUI 桥接渲染视图（直接复用 MPVUI 的 MPVVideoPlayer）
struct MPVVideoSurface: View {
    let controller: MPVPlayerController

    var body: some View {
        MPVVideoPlayer(player: controller.player)
    }
}
