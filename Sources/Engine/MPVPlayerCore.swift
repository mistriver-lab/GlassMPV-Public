import AVFoundation
import Combine
import Foundation
import MPVUI
import SwiftUI
import UIKit

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
        logLevel: .warning,
        isLoopingEnabled: true,
        videoOutput: .metal
    )

    @Published var isPaused: Bool = true
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var sourceFPS: Double = 0
    @Published var outputFPS: Double = 0
    @Published var displaySyncFPS: Double = 0
    @Published var videoWidth: Int = 0
    @Published var videoHeight: Int = 0
    @Published var videoCodec: String = ""
    @Published var hardwareDecoder: String = ""
    @Published var decodedPixelFormat: String = ""
    @Published var bitDepthLabel: String = "--"
    @Published var hdrLabel: String = "SDR"
    @Published var isHDRActive: Bool = false
    @Published var droppedFrames: Int64 = 0
    @Published var freshRenderPassCount: Int = 0
    @Published var activeShaderCount: Int = 0
    @Published var isSuperResolutionGatedBy4K: Bool = false
    @Published var statusMessage: String = ""
    @Published var playbackState: String = "待机"
    @Published var lastErrorMessage: String?
    @Published var diagnosticLogs: [String] = []
    @Published var isInitialized: Bool = false

    let player: MPVPlayer

    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private let taskBag = MPVTaskBag()
    private var currentPreset: ShaderPreset = .off
    private var currentExtras: Set<String> = []
    private var currentInterpolation: InterpolationMode = .off
    private var currentSpeed: Double = 1.0
    private var lastAppliedReadyGeneration: UInt64?
    private var last4KGateLoggedSize: (Int, Int)?

    init(configuration: MPVPlayerConfiguration = MPVPlayerController.defaultConfiguration) {
        self.player = MPVPlayer(configuration: configuration)
        self.player.setDiagnosticsEnabled(true)
        self.player.logHandler = { [weak self] logMsg in
            self?.appendLog("[\(logMsg.level.rawValue)][\(logMsg.prefix)] \(logMsg.message)")
        }

        self.isInitialized = true
        self.playbackState = "内核就绪"
        appendLog("[init] MPVUI 播放器内核已就绪 (output=\(configuration.videoOutput.rawValue))")
        startObservingPlayer()
    }

    func load(url: URL) {
        let target = url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString
        appendLog("[load] 请求播放: \(target)")

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        lastErrorMessage = nil
        statusMessage = ""
        currentTime = 0
        duration = 0
        sourceFPS = 0
        outputFPS = 0
        displaySyncFPS = 0
        videoWidth = 0
        videoHeight = 0
        videoCodec = ""
        hardwareDecoder = ""
        decodedPixelFormat = ""
        bitDepthLabel = "--"
        hdrLabel = "SDR"
        isHDRActive = false
        droppedFrames = 0
        freshRenderPassCount = 0
        isSuperResolutionGatedBy4K = false
        last4KGateLoggedSize = nil
        lastAppliedReadyGeneration = nil
        isInitialized = true
        playbackState = "正在加载媒体..."

        player.load(url, playAutomatically: true)
        if abs(currentSpeed - 1.0) > 0.001 {
            player.setPlaybackRate(currentSpeed)
        }
        applyInterpolation(currentInterpolation)
    }

    func togglePlayPause() {
        player.togglePlayback()
    }

    func pause() {
        player.pause()
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
            activeShaderCount = 0
            player.executeCommand("change-list", arguments: ["glsl-shaders", "clr", ""])
            let currentSize = (videoWidth, videoHeight)
            if last4KGateLoggedSize.map({ $0 != currentSize }) ?? true {
                last4KGateLoggedSize = currentSize
                let reason = SuperResolutionPolicy.disabledReason(width: videoWidth, height: videoHeight) ?? "片源已达 4K，自动禁用超分"
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
            player.setProperty("video-sync", to: "display-resample")
            player.setProperty("interpolation", to: "yes")
            player.setProperty("interpolation-threshold", to: "-1")
            player.setProperty("interpolation-preserve", to: "yes")
            player.setProperty("tscale", to: "mitchell")
            player.setProperty("display-fps-override", to: "\(targetDisplayFPS)")
            displaySyncFPS = Double(targetDisplayFPS)
            appendLog("[interp] 开启 \(targetDisplayFPS)Hz 时域平滑 (display-resample + interpolation-threshold=-1 + interpolation-preserve=yes + tscale=mitchell + display-fps-override=\(targetDisplayFPS))")
        case .off, .vtOpticalFlow2x:
            player.setProperty("interpolation", to: "no")
            player.setProperty("interpolation-preserve", to: "no")
            player.setProperty("interpolation-threshold", to: "0.01")
            player.setProperty("video-sync", to: "audio")
            player.setProperty("display-fps-override", to: "0")
            displaySyncFPS = 0
            appendLog("[interp] 关闭时域插值 (video-sync=audio)")
        }
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
        if diagnosticLogs.count > 120 {
            diagnosticLogs.removeFirst(diagnosticLogs.count - 120)
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
        } else if currentInterpolation == .mpvSmooth120Hz {
            let screenMaxFPS = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.screen.maximumFramesPerSecond ?? 120
            displaySyncFPS = Double(max(screenMaxFPS, 60))
        }
        freshRenderPassCount = diag.freshRenderPasses?.count ?? 0
        droppedFrames = (diag.decoderDroppedFrames ?? 0) + (diag.outputDroppedFrames ?? 0)

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
        player.stop()
        isPaused = true
        currentTime = 0
        duration = 0
        sourceFPS = 0
        outputFPS = 0
        displaySyncFPS = 0
        videoWidth = 0
        videoHeight = 0
        videoCodec = ""
        hardwareDecoder = ""
        decodedPixelFormat = ""
        bitDepthLabel = "--"
        hdrLabel = "SDR"
        isHDRActive = false
        droppedFrames = 0
        freshRenderPassCount = 0
        activeShaderCount = 0
        isSuperResolutionGatedBy4K = false
        last4KGateLoggedSize = nil
        lastAppliedReadyGeneration = nil
        lastErrorMessage = nil
        statusMessage = ""
        playbackState = "待机"
        appendLog("[lifecycle] 已停止播放并返回主界面")
    }

    func shutdown() {
        player.stop()
        isInitialized = false
        playbackState = "已停止"
        appendLog("[lifecycle] 播放器已停止")
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

    private func handlePlaybackEvent(_ event: MPVPlaybackEvent) {
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

        case .stateChanged(let state):
            applyState(state, generation: event.generation)

        case .pauseChanged(let paused):
            isPaused = paused

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
            playbackState = "播放中"
            reapplyActivePipelineIfNeeded(for: generation)
        case .paused:
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
            if is4K != isSuperResolutionGatedBy4K || (is4K && activeShaderCount > 0) {
                applyShaders(preset: currentPreset, extras: currentExtras)
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
