import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import QuartzCore
import SwiftUI
import UIKit
import VideoToolbox

final class SampleBufferDisplayContainerView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()
    @MainActor private(set) var videoTransform: CGAffineTransform = .identity

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(displayLayer)
        layoutDisplayLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func isQuarterTurnTransform(_ transform: CGAffineTransform) -> Bool {
        abs(transform.b) > abs(transform.a)
    }

    static func normalizedRotationTransform(from transform: CGAffineTransform) -> CGAffineTransform {
        let isDegenerate = abs(transform.a) < 1e-6
            && abs(transform.b) < 1e-6
            && abs(transform.c) < 1e-6
            && abs(transform.d) < 1e-6
        if isDegenerate {
            return .identity
        }
        return CGAffineTransform(
            a: transform.a,
            b: transform.b,
            c: transform.c,
            d: transform.d,
            tx: 0,
            ty: 0
        )
    }

    func applyVideoTransform(_ transform: CGAffineTransform) {
        videoTransform = transform
        layoutDisplayLayer()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutDisplayLayer()
    }

    private func layoutDisplayLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let isQuarterTurn = Self.isQuarterTurnTransform(videoTransform)
        let layerSize = isQuarterTurn
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size
        displayLayer.setAffineTransform(.identity)
        displayLayer.bounds = CGRect(origin: .zero, size: layerSize)
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        displayLayer.setAffineTransform(Self.normalizedRotationTransform(from: videoTransform))
    }
}

/// 无音轨片源专用的单调合成时钟（支持播放/暂停/倍速/Seek 精确推进）
struct OpticalFlowSyntheticClock: Sendable {
    private(set) var baseMediaTime: Double = 0
    private(set) var anchorHostTime: CFTimeInterval = 0
    private(set) var rate: Double = 0
    private(set) var isRunning: Bool = false

    mutating func reset(to seconds: Double = 0, now: CFTimeInterval = CACurrentMediaTime()) {
        baseMediaTime = max(0, seconds)
        anchorHostTime = now
        rate = 0
        isRunning = false
    }

    mutating func start(rate: Double, now: CFTimeInterval = CACurrentMediaTime()) {
        let current = currentTime(now: now)
        baseMediaTime = current
        anchorHostTime = now
        self.rate = max(0, rate)
        isRunning = self.rate > 0
    }

    mutating func pause(now: CFTimeInterval = CACurrentMediaTime()) {
        baseMediaTime = currentTime(now: now)
        anchorHostTime = now
        isRunning = false
    }

    mutating func setRate(_ newRate: Double, now: CFTimeInterval = CACurrentMediaTime()) {
        let current = currentTime(now: now)
        baseMediaTime = current
        anchorHostTime = now
        rate = max(0, newRate)
        if rate <= 0 {
            isRunning = false
        }
    }

    mutating func seek(to seconds: Double, now: CFTimeInterval = CACurrentMediaTime()) {
        baseMediaTime = max(0, seconds)
        anchorHostTime = now
    }

    func currentTime(now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        guard isRunning, rate > 0 else { return baseMediaTime }
        let elapsed = max(0, now - anchorHostTime)
        return baseMediaTime + elapsed * rate
    }
}

/// Apple Silicon ANE 硬件光流真补帧播放控制器（基于 VideoToolbox VTFrameProcessor）
final class OpticalFlowPlayerController: ObservableObject, @unchecked Sendable {
    @Published @MainActor var isPaused: Bool = true
    @Published @MainActor var currentTime: Double = 0
    @Published @MainActor var duration: Double = 0
    @Published @MainActor var sourceFPS: Double = 0
    @Published @MainActor var interpolatedFPS: Double = 0
    @Published @MainActor var actualOutputFPS: Double = 0
    @Published @MainActor var videoWidth: Int = 0
    @Published @MainActor var videoHeight: Int = 0
    @Published @MainActor var videoCodec: String = ""
    @Published @MainActor var bitDepthLabel: String = "--"
    @Published @MainActor var hdrLabel: String = "SDR"
    @Published @MainActor var isHDRActive: Bool = false
    @Published @MainActor var droppedFrames: Int64 = 0
    @Published @MainActor var errorMessage: String?
    @Published @MainActor var isHardwareSupported: Bool = false
    @Published @MainActor var enableSpatial2xUpscale: Bool = false
    @Published @MainActor var interpolatedFrameCount: Int = 0
    @Published @MainActor var failedInterpolationCount: Int = 0
    @Published @MainActor var presentedFrameCount: Int = 0
    @Published @MainActor var lastInterpolationError: String?
    @Published @MainActor var diagnosticLogs: [String] = []
    @Published @MainActor var isLoadingPipeline: Bool = false
    @Published @MainActor var pipelineStatusText: String = ""
    @Published @MainActor var skippedInterpolationCount: Int = 0
    @Published @MainActor var averageInterpolationMs: Double = 0
    @Published @MainActor var clockSourceLabel: String = "AVPlayer音频"
    @Published @MainActor var videoTransform: CGAffineTransform = .identity

    @MainActor var isLoopingEnabled: Bool = true

    @MainActor
    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    @MainActor
    var capabilityDescription: String {
#if targetEnvironment(simulator)
        return "Simulator (硬件光流仅真机可用)"
#else
        let supported = VTLowLatencyFrameInterpolationConfiguration.isSupported
        return supported ? "真机支持 ANE 光流" : "当前设备不支持 VTLowLatencyFrameInterpolation"
#endif
    }

    private let bufferLock = NSLock()
    private let tokenLock = NSLock()
    private let audioClockLock = NSLock()
    private var frameQueue: [(pts: Double, buffer: CVPixelBuffer)] = []
    private var pendingFirstFrame: (pts: Double, buffer: CVPixelBuffer)?
    private var didAttachDisplayLayer: Bool = false
    private var isReaderEOF: Bool = false
    private var lastEnqueuedPTS: Double = 0
    private var maxQueuedFrames = 24
    private let prebufferFrameTarget = 6

    private weak var displayContainer: SampleBufferDisplayContainerView?
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var displayTimebase: CMTimebase?
    private var audioPlayer: AVPlayer?
    private var timeObserver: Any?
    private var displayLink: CADisplayLink?
    @MainActor private var syntheticClock = OpticalFlowSyntheticClock()
    @MainActor private var usesSyntheticClock: Bool = false
    @MainActor private var lastCurrentTimePublishTimestamp: CFTimeInterval = 0

    private var currentURL: URL?
    private var sessionToken = UUID()
    private var playbackSpeed: Float = 1.0
    private var latestAudioTimeSeconds: Double = 0
    @MainActor private var isPipelineReadyToPlay: Bool = false
    private var presentedTimestamps: [CFTimeInterval] = []
    private var lastFPSPublishTimestamp: CFTimeInterval = 0

    @MainActor
    func attach(to container: SampleBufferDisplayContainerView) {
        self.displayContainer = container
        container.applyVideoTransform(videoTransform)
        attach(to: container.displayLayer)
    }

    @MainActor
    func attach(to layer: AVSampleBufferDisplayLayer) {
        self.displayLayer = layer
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        if status == noErr, let timebase {
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 1.0)
            layer.controlTimebase = timebase
            self.displayTimebase = timebase
        }

        bufferLock.lock()
        didAttachDisplayLayer = true
        let pending = pendingFirstFrame
        pendingFirstFrame = nil
        bufferLock.unlock()

        if let pending {
            presentFrame(pending.buffer, ptsSeconds: pending.pts, on: layer)
        }
        if isPipelineReadyToPlay && !isPaused {
            startActiveClockIfNeeded()
        }
    }

    func cachePendingFirstFrame(_ buffer: CVPixelBuffer, ptsSeconds: Double) {
        bufferLock.lock()
        if !didAttachDisplayLayer && pendingFirstFrame == nil {
            pendingFirstFrame = (pts: ptsSeconds, buffer: buffer)
        }
        bufferLock.unlock()
    }

    static func isValidInterpolationDelta(_ deltaSeconds: Double) -> Bool {
        (0.004...0.5).contains(deltaSeconds)
    }

    @MainActor
    func load(url: URL, spatial2x: Bool, startAt: Double = 0) {
        stopInternal()
        currentURL = url
        enableSpatial2xUpscale = spatial2x
        errorMessage = nil
        interpolatedFrameCount = 0
        failedInterpolationCount = 0
        presentedFrameCount = 0
        skippedInterpolationCount = 0
        averageInterpolationMs = 0
        lastInterpolationError = nil
        isLoadingPipeline = true
        pipelineStatusText = "正在初始化 ANE 光流核..."
        updateLatestAudioTime(max(0, startAt))
        appendLog("[ane] 请求加载光流核: \(url.lastPathComponent) (请求空间2×=\(spatial2x), startAt=\(String(format: "%.2f", startAt))s)")

#if targetEnvironment(simulator)
        isHardwareSupported = false
        isLoadingPipeline = false
        pipelineStatusText = ""
        appendLog("[ane] Simulator 环境不支持 VideoToolbox ANE 硬件光流")
        errorMessage = "iOS 模拟器不支持 VideoToolbox ANE 硬件光流，请切换回「MPV 超分核」。"
        return
#else
        let supported = VTLowLatencyFrameInterpolationConfiguration.isSupported
        isHardwareSupported = supported
        guard supported else {
            isLoadingPipeline = false
            pipelineStatusText = ""
            appendLog("[ane] 当前设备不支持 VTLowLatencyFrameInterpolation")
            errorMessage = "当前设备不支持 VTLowLatencyFrameInterpolation，请切换回「MPV 超分核」。"
            return
        }

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        self.isPaused = false

        let link = CADisplayLink(target: self, selector: #selector(onDisplayTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.displayLink = link

        let token = rotateToken()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let asset = AVURLAsset(url: url)
                let assetDuration = try await asset.load(.duration)
                guard self.isTokenValid(token) else { return }
                self.duration = assetDuration.seconds.isFinite ? assetDuration.seconds : 0

                let tracks = try await asset.loadTracks(withMediaType: .video)
                let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                guard self.isTokenValid(token) else { return }
                guard let videoTrack = tracks.first else {
                    self.isPaused = true
                    self.isLoadingPipeline = false
                    self.pipelineStatusText = ""
                    self.appendLog("[ane] 未发现视频轨道（仅支持 MP4/MOV 容器）")
                    self.errorMessage = "光流核仅支持原生 MP4/MOV 容器；MKV/FLV 等封装请切换回「MPV 超分核」。"
                    return
                }

                let preferredTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
                let nominalRate = try await videoTrack.load(.nominalFrameRate)
                let naturalSize = try await videoTrack.load(.naturalSize)
                let formatDescriptions = (try? await videoTrack.load(.formatDescriptions)) ?? []
                guard self.isTokenValid(token) else { return }

                self.videoTransform = preferredTransform
                self.displayContainer?.applyVideoTransform(preferredTransform)

                let trackMetrics = Self.extractTrackMetrics(from: formatDescriptions.first, naturalSize: naturalSize)
                let displayDims = Self.displayDimensions(naturalSize: naturalSize, transform: preferredTransform)
                let is4K = SuperResolutionPolicy.isAlready4K(width: displayDims.width, height: displayDims.height)
                let effectiveSpatial2x = spatial2x && !is4K
                if spatial2x && is4K {
                    self.appendLog("[ane] 片源已达 4K（\(displayDims.width)×\(displayDims.height)），自动禁用 ANE 2× 空间超分，仅保留光流补帧")
                }

                let srcFps = nominalRate > 0 ? Double(nominalRate) : 24.0
                self.sourceFPS = srcFps
                self.interpolatedFPS = srcFps * 2.0
                self.videoWidth = displayDims.width
                self.videoHeight = displayDims.height
                self.videoCodec = trackMetrics.codec
                self.bitDepthLabel = trackMetrics.bitDepth
                self.hdrLabel = trackMetrics.hdrTag
                self.isHDRActive = false
                self.enableSpatial2xUpscale = effectiveSpatial2x

                let clampedStart = self.duration > 0 ? max(0, min(startAt, self.duration)) : max(0, startAt)
                if audioTracks.isEmpty {
                    self.usesSyntheticClock = true
                    self.clockSourceLabel = "合成单调时钟"
                    self.audioPlayer = nil
                    self.syntheticClock.reset(to: clampedStart)
                    self.currentTime = clampedStart
                    self.updateLatestAudioTime(clampedStart)
                    self.appendLog("[ane] 片源无音轨，启用合成单调时钟驱动渲染")
                } else {
                    self.usesSyntheticClock = false
                    self.clockSourceLabel = "AVPlayer音频"
                    let item = AVPlayerItem(url: url)
                    for pTrack in item.tracks where pTrack.assetTrack?.mediaType == .video {
                        pTrack.isEnabled = false
                    }
                    let player = AVPlayer(playerItem: item)
                    player.rate = 0
                    self.audioPlayer = player

                    let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
                    self.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                        let seconds = time.seconds.isFinite ? time.seconds : 0
                        Task { @MainActor [weak self] in
                            self?.currentTime = seconds
                        }
                    }

                    if clampedStart > 0.1 {
                        let targetCM = CMTime(seconds: clampedStart, preferredTimescale: 600)
                        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                            player.seek(to: targetCM, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                                continuation.resume()
                            }
                        }
                        guard self.isTokenValid(token) else { return }
                        self.currentTime = clampedStart
                        self.updateLatestAudioTime(clampedStart)
                    } else {
                        self.updateLatestAudioTime(0)
                    }
                }

                self.pipelineStatusText = "正在预热 ANE 光流缓冲..."
                let prefer10Bit = Self.shouldPrefer10Bit(from: trackMetrics)
                self.startPipeline(
                    url: url,
                    width: Int(abs(naturalSize.width)),
                    height: Int(abs(naturalSize.height)),
                    startSeconds: clampedStart,
                    spatial2x: effectiveSpatial2x,
                    prefer10Bit: prefer10Bit,
                    token: token
                )
            } catch {
                self.isPaused = true
                self.isLoadingPipeline = false
                self.pipelineStatusText = ""
                self.appendLog("[ane][error] 加载轨道信息失败: \(error.localizedDescription)")
                self.errorMessage = "光流核加载失败（\(error.localizedDescription)），建议切换回「MPV 超分核」。"
            }
        }
#endif
    }

    @MainActor
    func togglePlayPause() {
        if usesSyntheticClock {
            if isPaused {
                isPaused = false
                startActiveClockIfNeeded()
            } else {
                syntheticClock.pause()
                currentTime = syntheticClock.currentTime()
                isPaused = true
            }
            return
        }

        guard audioPlayer != nil else { return }
        if isPaused {
            isPaused = false
            startActiveClockIfNeeded()
        } else {
            audioPlayer?.pause()
            isPaused = true
        }
    }

    @MainActor
    func pause() {
        if usesSyntheticClock {
            syntheticClock.pause()
            currentTime = syntheticClock.currentTime()
        } else {
            audioPlayer?.pause()
        }
        isPaused = true
    }

    @MainActor
    func setSpeed(_ speed: Double) {
        playbackSpeed = Float(speed)
        if usesSyntheticClock {
            syntheticClock.setRate(speed)
            return
        }
        if !isPaused && isPipelineReadyToPlay {
            audioPlayer?.rate = playbackSpeed
        }
    }

    @MainActor
    func seek(to seconds: Double) {
        guard let url = currentURL else { return }
        let clamped = duration > 0 ? max(0, min(seconds, duration)) : max(0, seconds)
        isPipelineReadyToPlay = false
        isLoadingPipeline = true
        pipelineStatusText = "正在重定位并预热光流..."
        currentTime = clamped
        updateLatestAudioTime(clamped)

        if usesSyntheticClock {
            syntheticClock.pause()
            syntheticClock.seek(to: clamped)
        } else if let audioPlayer {
            audioPlayer.rate = 0
            let targetCM = CMTime(seconds: clamped, preferredTimescale: 600)
            audioPlayer.seek(to: targetCM, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        clearBufferedFrames()
        displayLayer?.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)

        let token = rotateToken()
        let spatial2x = self.enableSpatial2xUpscale

        Task { @MainActor [weak self] in
            guard let self, self.isTokenValid(token) else { return }
            let asset = AVURLAsset(url: url)
            guard let tracks = try? await asset.loadTracks(withMediaType: .video),
                  let videoTrack = tracks.first else { return }
            let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
            let formatDescriptions = (try? await videoTrack.load(.formatDescriptions)) ?? []
            let trackMetrics = Self.extractTrackMetrics(from: formatDescriptions.first, naturalSize: naturalSize)
            let prefer10Bit = Self.shouldPrefer10Bit(from: trackMetrics)
            guard self.isTokenValid(token) else { return }
            self.startPipeline(
                url: url,
                width: Int(abs(naturalSize.width)),
                height: Int(abs(naturalSize.height)),
                startSeconds: clamped,
                spatial2x: spatial2x,
                prefer10Bit: prefer10Bit,
                token: token
            )
        }
    }

    @MainActor
    func seekRelative(_ delta: Double) {
        seek(to: currentTime + delta)
    }

    @MainActor
    func stop() {
        stopInternal()
    }

    @MainActor
    private func stopInternal() {
        _ = rotateToken()
        displayLink?.invalidate()
        displayLink = nil
        if let observer = timeObserver {
            audioPlayer?.removeTimeObserver(observer)
            timeObserver = nil
        }
        audioPlayer?.pause()
        audioPlayer = nil
        syntheticClock.reset(to: 0)
        usesSyntheticClock = false
        clockSourceLabel = "AVPlayer音频"
        videoTransform = .identity
        displayContainer?.applyVideoTransform(.identity)
        clearBufferedFrames()
        bufferLock.lock()
        didAttachDisplayLayer = (displayLayer != nil)
        bufferLock.unlock()
        displayLayer?.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        presentedTimestamps.removeAll()
        lastFPSPublishTimestamp = 0
        lastCurrentTimePublishTimestamp = 0
        actualOutputFPS = 0
        currentTime = 0
        duration = 0
        updateLatestAudioTime(0)
        videoWidth = 0
        videoHeight = 0
        videoCodec = ""
        bitDepthLabel = "--"
        hdrLabel = "SDR"
        isHDRActive = false
        droppedFrames = 0
        interpolatedFrameCount = 0
        failedInterpolationCount = 0
        presentedFrameCount = 0
        skippedInterpolationCount = 0
        averageInterpolationMs = 0
        lastInterpolationError = nil
        isLoadingPipeline = false
        pipelineStatusText = ""
        isPipelineReadyToPlay = false
        isPaused = true
        appendLog("[ane] 光流核已停止")
    }

    @MainActor
    private func startActiveClockIfNeeded() {
        guard displayLayer != nil, isPipelineReadyToPlay, !isPaused else { return }
        if usesSyntheticClock {
            if !syntheticClock.isRunning {
                syntheticClock.start(rate: Double(playbackSpeed))
            }
        } else if let audioPlayer, audioPlayer.rate == 0 {
            audioPlayer.rate = playbackSpeed
        }
    }

    @MainActor
    func appendLog(_ line: String) {
        let stamp = Self.logTimeFormatter.string(from: Date())
        diagnosticLogs.append("[\(stamp)] \(line)")
        if diagnosticLogs.count > 120 {
            diagnosticLogs.removeFirst(diagnosticLogs.count - 120)
        }
    }

    private func logAsync(_ line: String) {
        Task { @MainActor [weak self] in
            self?.appendLog(line)
        }
    }

    private func clearBufferedFrames() {
        bufferLock.lock()
        frameQueue.removeAll()
        pendingFirstFrame = nil
        isReaderEOF = false
        lastEnqueuedPTS = 0
        bufferLock.unlock()
    }

    private func startPipeline(
        url: URL,
        width: Int,
        height: Int,
        startSeconds: Double,
        spatial2x: Bool,
        prefer10Bit: Bool,
        token: UUID
    ) {
#if !targetEnvironment(simulator)
        let safeW = max(width, 2)
        let safeH = max(height, 2)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runOpticalFlowTask(
                url: url,
                width: safeW,
                height: safeH,
                startSeconds: startSeconds,
                spatial2x: spatial2x,
                prefer10Bit: prefer10Bit,
                token: token
            )
        }
#endif
    }

#if !targetEnvironment(simulator)
    private func runOpticalFlowTask(
        url: URL,
        width: Int,
        height: Int,
        startSeconds: Double,
        spatial2x: Bool,
        prefer10Bit: Bool,
        token: UUID
    ) async {
        do {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = tracks.first else {
                Task { @MainActor [weak self] in
                    self?.isLoadingPipeline = false
                    self?.pipelineStatusText = ""
                    self?.errorMessage = "未找到视频轨道，请切换回「MPV 超分核」。"
                }
                return
            }

            var activeWidth = width
            var activeHeight = height
            var activeSpatial2x = spatial2x && !SuperResolutionPolicy.isAlready4K(width: width, height: height)

            guard let initialSetup = createProcessorConfiguration(
                width: activeWidth,
                height: activeHeight,
                requestedSpatial2x: activeSpatial2x
            ) else {
                logAsync("[ane] 无法初始化 VideoToolbox 光流配置（\(activeWidth)×\(activeHeight)）")
                Task { @MainActor [weak self] in
                    self?.isLoadingPipeline = false
                    self?.pipelineStatusText = ""
                    self?.errorMessage = "无法初始化 VideoToolbox 光流配置（\(activeWidth)x\(activeHeight)）。"
                }
                return
            }

            var configuration = initialSetup.configuration
            activeSpatial2x = initialSetup.effectiveSpatial2x

            var processor = VTFrameProcessor()
            try processor.startSession(configuration: configuration)
            defer { processor.endSession() }

            let pixelFormat = resolveSourcePixelFormat(from: configuration, prefer10Bit: prefer10Bit)
            let resolvedPixFmtString = Self.fourCCString(pixelFormat)
            logAsync("[ane] 光流会话启动: \(activeWidth)×\(activeHeight), pixFmt=\(resolvedPixFmtString), spatial2x=\(activeSpatial2x), prefer10Bit=\(prefer10Bit)")

            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.bitDepthLabel == "--" {
                    let parsed = PlaybackHUDMetrics.parseBitDepth(fromPixelFormat: resolvedPixFmtString)
                    if parsed != "--" {
                        self.bitDepthLabel = parsed
                    }
                }
            }

            let reader = try AVAssetReader(asset: asset)
            if startSeconds > 0 {
                reader.timeRange = CMTimeRange(
                    start: CMTime(seconds: startSeconds, preferredTimescale: 600),
                    duration: .positiveInfinity
                )
            }

            let preferredSettings = Self.buildReaderOutputSettings(from: configuration, pixelFormat: pixelFormat)
            var trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: preferredSettings)
            trackOutput.alwaysCopiesSampleData = false
            if !reader.canAdd(trackOutput) {
                let minimalSettings: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ]
                trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: minimalSettings)
                trackOutput.alwaysCopiesSampleData = false
                guard reader.canAdd(trackOutput) else {
                    logAsync("[ane] 无法添加 AVAssetReaderTrackOutput，建议切换 MPV 超分核")
                    Task { @MainActor [weak self] in
                        self?.isLoadingPipeline = false
                        self?.pipelineStatusText = ""
                        self?.errorMessage = "无法读取视频轨道，建议切换「MPV 超分核」。"
                    }
                    return
                }
            }
            reader.add(trackOutput)
            guard reader.startReading() else {
                let errDesc = reader.error?.localizedDescription ?? "AVAssetReader 启动失败"
                logAsync("[ane][error] AVAssetReader startReading 失败: \(errDesc)")
                Task { @MainActor [weak self] in
                    self?.isLoadingPipeline = false
                    self?.pipelineStatusText = ""
                    self?.errorMessage = "光流读取视频失败：\(errDesc)"
                }
                return
            }

            var destPool = try makeDestinationPool(
                configuration: configuration,
                fallbackWidth: activeSpatial2x ? activeWidth * 2 : activeWidth,
                fallbackHeight: activeSpatial2x ? activeHeight * 2 : activeHeight,
                fallbackFormat: pixelFormat
            )

            var transferSession: VTPixelTransferSession?
            if activeSpatial2x {
                VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transferSession)
            }
            defer {
                if let transferSession {
                    VTPixelTransferSessionInvalidate(transferSession)
                }
            }

            var previousBuffer: CVPixelBuffer?
            var previousPTS: CMTime = .invalid
            var localSuccessCount = 0
            var localConsecutiveFailures = 0
            var totalInterpolationMs: Double = 0
            var didCheckActualDimensions = false
            var didStartAudioClock = false
            var didLogCatchUp = false
            var didCachePendingFirstFrame = false

            while reader.status == .reading {
                if !isTokenValid(token) {
                    reader.cancelReading()
                    return
                }

                while queuedCount() >= maxQueuedFrames {
                    if !isTokenValid(token) {
                        reader.cancelReading()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(8))
                }

                guard let sample = trackOutput.copyNextSampleBuffer(),
                      let currentBuffer = CMSampleBufferGetImageBuffer(sample) else {
                    break
                }
                let currentPTS = CMSampleBufferGetPresentationTimeStamp(sample)

                if !didCheckActualDimensions {
                    didCheckActualDimensions = true
                    let actualW = CVPixelBufferGetWidth(currentBuffer)
                    let actualH = CVPixelBufferGetHeight(currentBuffer)
                    if actualW >= 2, actualH >= 2, (actualW != activeWidth || actualH != activeHeight) {
                        logAsync("[ane] 实际解码缓冲尺寸 \(actualW)×\(actualH) 与轨道声明 \(activeWidth)×\(activeHeight) 不一致，重建光流会话")
                        let rebuiltSpatial2x = activeSpatial2x && !SuperResolutionPolicy.isAlready4K(width: actualW, height: actualH)
                        if let rebuilt = createProcessorConfiguration(
                            width: actualW,
                            height: actualH,
                            requestedSpatial2x: rebuiltSpatial2x
                        ) {
                            processor.endSession()
                            let nextProcessor = VTFrameProcessor()
                            try nextProcessor.startSession(configuration: rebuilt.configuration)
                            processor = nextProcessor
                            configuration = rebuilt.configuration
                            activeWidth = actualW
                            activeHeight = actualH
                            activeSpatial2x = rebuilt.effectiveSpatial2x
                            destPool = try makeDestinationPool(
                                configuration: configuration,
                                fallbackWidth: activeSpatial2x ? activeWidth * 2 : activeWidth,
                                fallbackHeight: activeSpatial2x ? activeHeight * 2 : activeHeight,
                                fallbackFormat: pixelFormat
                            )
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.enableSpatial2xUpscale = rebuilt.effectiveSpatial2x
                            }
                        }
                    }
                }

                let behindAudioClock = didStartAudioClock && (currentPTS.seconds < readLatestAudioTime() - 0.18)
                if behindAudioClock {
                    if !didLogCatchUp {
                        didLogCatchUp = true
                        logAsync("[ane][perf] 光流处理落后时钟，临时跳过部分帧插帧以保持音画同步")
                    }
                    Task { @MainActor [weak self] in
                        self?.skippedInterpolationCount += 1
                    }
                } else if let prevBuf = previousBuffer,
                          previousPTS.isValid,
                          currentPTS > previousPTS,
                          Self.isValidInterpolationDelta(currentPTS.seconds - previousPTS.seconds) {
                    if let prevFrame = VTFrameProcessorFrame(buffer: prevBuf, presentationTimeStamp: previousPTS),
                       let currFrame = VTFrameProcessorFrame(buffer: currentBuffer, presentationTimeStamp: currentPTS) {
                        var destBufOpt: CVPixelBuffer?
                        let poolStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, destPool, &destBufOpt)

                        if poolStatus == kCVReturnSuccess, let destBuf = destBufOpt {
                            let midSeconds = (previousPTS.seconds + currentPTS.seconds) * 0.5
                            let midPTS = CMTime(seconds: midSeconds, preferredTimescale: 600)
                            if let destFrame = VTFrameProcessorFrame(buffer: destBuf, presentationTimeStamp: midPTS),
                               let params = VTLowLatencyFrameInterpolationParameters(
                                   sourceFrame: currFrame,
                                   previousFrame: prevFrame,
                                   interpolationPhase: [0.5],
                                   destinationFrames: [destFrame]
                               ) {
                                do {
                                    let processStart = CACurrentMediaTime()
                                    _ = try await processor.process(parameters: params)
                                    let elapsedMs = (CACurrentMediaTime() - processStart) * 1000.0
                                    totalInterpolationMs += elapsedMs
                                    CVBufferPropagateAttachments(currentBuffer, destBuf)
                                    enqueueDecodedFrame(pts: midSeconds, buffer: destBuf)
                                    localSuccessCount += 1
                                    localConsecutiveFailures = 0
                                    let avgMs = totalInterpolationMs / Double(localSuccessCount)
                                    if localSuccessCount == 1 {
                                        logAsync("[ane] 首帧光流补帧成功（\(activeWidth)×\(activeHeight), 耗时 \(String(format: "%.1f", elapsedMs))ms）")
                                    }
                                    Task { @MainActor [weak self] in
                                        guard let self else { return }
                                        self.interpolatedFrameCount += 1
                                        self.averageInterpolationMs = avgMs
                                    }
                                } catch {
                                    localConsecutiveFailures += 1
                                    recordInterpolationFailure(
                                        "process 异常: \(error.localizedDescription)",
                                        consecutiveFailures: localConsecutiveFailures,
                                        totalSuccesses: localSuccessCount
                                    )
                                }
                            } else {
                                localConsecutiveFailures += 1
                                recordInterpolationFailure(
                                    "VTLowLatencyFrameInterpolationParameters/destFrame 初始化返回 nil",
                                    consecutiveFailures: localConsecutiveFailures,
                                    totalSuccesses: localSuccessCount
                                )
                            }
                        } else {
                            localConsecutiveFailures += 1
                            recordInterpolationFailure(
                                "CVPixelBufferPoolCreatePixelBuffer 失败 (\(poolStatus))",
                                consecutiveFailures: localConsecutiveFailures,
                                totalSuccesses: localSuccessCount
                            )
                        }
                    } else {
                        localConsecutiveFailures += 1
                        recordInterpolationFailure(
                            "VTFrameProcessorFrame(prev/curr) 初始化返回 nil",
                            consecutiveFailures: localConsecutiveFailures,
                            totalSuccesses: localSuccessCount
                        )
                    }
                }

                let outputBuffer = scaleIfNeeded(currentBuffer, spatial2x: activeSpatial2x, transferSession: transferSession, pool: destPool)
                if !didCachePendingFirstFrame {
                    didCachePendingFirstFrame = true
                    cachePendingFirstFrame(outputBuffer, ptsSeconds: currentPTS.seconds)
                }
                enqueueDecodedFrame(pts: currentPTS.seconds, buffer: outputBuffer)
                if !didStartAudioClock && queuedCount() >= prebufferFrameTarget {
                    didStartAudioClock = true
                    Task { @MainActor [weak self] in
                        guard let self, self.isTokenValid(token) else { return }
                        self.isPipelineReadyToPlay = true
                        self.pipelineStatusText = ""
                        self.startActiveClockIfNeeded()
                    }
                }
                previousBuffer = currentBuffer
                previousPTS = currentPTS
            }

            if reader.status == .failed && isTokenValid(token) {
                let errDesc = reader.error?.localizedDescription ?? "读取中断"
                logAsync("[ane][error] AVAssetReader 读取异常终止: \(errDesc)")
                if !didStartAudioClock {
                    Task { @MainActor [weak self] in
                        self?.isLoadingPipeline = false
                        self?.pipelineStatusText = ""
                        self?.errorMessage = "光流解码异常：\(errDesc)"
                    }
                }
            } else if isTokenValid(token) {
                bufferLock.lock()
                isReaderEOF = true
                bufferLock.unlock()

                if !didStartAudioClock && queuedCount() > 0 {
                    didStartAudioClock = true
                    Task { @MainActor [weak self] in
                        guard let self, self.isTokenValid(token) else { return }
                        self.isPipelineReadyToPlay = true
                        self.pipelineStatusText = ""
                        self.startActiveClockIfNeeded()
                    }
                } else if queuedCount() == 0 && !didStartAudioClock {
                    Task { @MainActor [weak self] in
                        self?.isLoadingPipeline = false
                        self?.pipelineStatusText = ""
                    }
                }
            }
        } catch {
            let desc = error.localizedDescription
            logAsync("[ane][error] 光流插帧运行异常：\(desc)")
            Task { @MainActor [weak self] in
                self?.isLoadingPipeline = false
                self?.pipelineStatusText = ""
                self?.errorMessage = "光流插帧运行异常：\(desc)"
            }
        }
    }
#endif

    @MainActor
    @objc private func onDisplayTick() {
        guard let layer = displayLayer else { return }

        let now: Double
        if usesSyntheticClock {
            now = syntheticClock.currentTime()
            let hostNow = CACurrentMediaTime()
            if hostNow - lastCurrentTimePublishTimestamp >= 0.1 {
                lastCurrentTimePublishTimestamp = hostNow
                currentTime = now
            }
        } else if let audioPlayer {
            if let item = audioPlayer.currentItem {
                for pTrack in item.tracks where pTrack.isEnabled && pTrack.assetTrack?.mediaType == .video {
                    pTrack.isEnabled = false
                }
            }
            let audioNow = audioPlayer.currentTime().seconds
            guard audioNow.isFinite else { return }
            now = audioNow
        } else {
            return
        }

        updateLatestAudioTime(now)

        var droppedInTick = 0
        var frameToPresent: CVPixelBuffer?
        bufferLock.lock()
        while let head = frameQueue.first, head.pts <= now + 0.004 {
            if frameToPresent != nil {
                droppedInTick += 1
            }
            frameToPresent = head.buffer
            frameQueue.removeFirst()
        }
        let remainingQueueCount = frameQueue.count
        let eofReached = isReaderEOF
        let lastPTS = lastEnqueuedPTS
        bufferLock.unlock()

        if droppedInTick > 0 {
            droppedFrames += Int64(droppedInTick)
        }

        if let buffer = frameToPresent {
            presentFrame(buffer, ptsSeconds: now, on: layer)
        }

        if isLoopingEnabled,
           isPipelineReadyToPlay,
           !isPaused,
           eofReached,
           remainingQueueCount == 0,
           presentedFrameCount > 0 {
            let reachedDurationEnd = duration > 0 && now >= duration - 0.05
            let passedLastFrame = lastPTS > 0 && now >= lastPTS + 0.08
            if reachedDurationEnd || passedLastFrame {
                appendLog("[ane] 播放到达末尾，自动循环重播")
                seek(to: 0)
            }
        }
    }

    @MainActor
    private func presentFrame(_ buffer: CVPixelBuffer, ptsSeconds: Double, on layer: AVSampleBufferDisplayLayer) {
        guard let sampleBuffer = makeSampleBuffer(from: buffer, ptsSeconds: ptsSeconds) else { return }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            let reason = renderer.error?.localizedDescription ?? "requiresFlushToResumeDecoding"
            appendLog("[ane][renderer] 渲染器异常或需重置，执行 flush: \(reason)")
            renderer.flush()
            if let tb = displayTimebase {
                CMTimebaseSetTime(tb, time: .zero)
                CMTimebaseSetRate(tb, rate: 1.0)
            }
        }
        if renderer.isReadyForMoreMediaData {
            renderer.enqueue(sampleBuffer)
            presentedFrameCount += 1
            if isLoadingPipeline {
                isLoadingPipeline = false
                pipelineStatusText = ""
            }
            let nowMedia = CACurrentMediaTime()
            presentedTimestamps.append(nowMedia)
            presentedTimestamps.removeAll { nowMedia - $0 > 1.0 }
            if nowMedia - lastFPSPublishTimestamp >= 0.25 {
                lastFPSPublishTimestamp = nowMedia
                if presentedTimestamps.count >= 2, let first = presentedTimestamps.first {
                    let span = nowMedia - first
                    if span > 0.05 {
                        actualOutputFPS = Double(presentedTimestamps.count - 1) / span
                    }
                }
            }
        }
    }

    private func rotateToken() -> UUID {
        let next = UUID()
        tokenLock.lock()
        sessionToken = next
        tokenLock.unlock()
        return next
    }

    private func isTokenValid(_ token: UUID) -> Bool {
        tokenLock.lock()
        let valid = (sessionToken == token)
        tokenLock.unlock()
        return valid
    }

    private func queuedCount() -> Int {
        bufferLock.lock()
        let count = frameQueue.count
        bufferLock.unlock()
        return count
    }

    private func enqueueDecodedFrame(pts: Double, buffer: CVPixelBuffer) {
        bufferLock.lock()
        frameQueue.append((pts: pts, buffer: buffer))
        if pts > lastEnqueuedPTS {
            lastEnqueuedPTS = pts
        }
        bufferLock.unlock()
    }

    private func updateLatestAudioTime(_ seconds: Double) {
        audioClockLock.lock()
        latestAudioTimeSeconds = seconds
        audioClockLock.unlock()
    }

    private func readLatestAudioTime() -> Double {
        audioClockLock.lock()
        let val = latestAudioTimeSeconds
        audioClockLock.unlock()
        return val
    }

#if !targetEnvironment(simulator)
    private func createProcessorConfiguration(
        width: Int,
        height: Int,
        requestedSpatial2x: Bool
    ) -> (configuration: VTLowLatencyFrameInterpolationConfiguration, effectiveSpatial2x: Bool)? {
        if requestedSpatial2x {
            if let scaledConfig = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: width,
                frameHeight: height,
                spatialScaleFactor: 2
            ) {
                return (scaledConfig, true)
            }
            logAsync("[ane] spatialScaleFactor=2 初始化失败（\(width)×\(height)），自动降级为仅 2× 光流补帧")
            Task { @MainActor [weak self] in
                self?.enableSpatial2xUpscale = false
            }
        }
        if let frcConfig = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: width,
            frameHeight: height,
            numberOfInterpolatedFrames: 1
        ) {
            return (frcConfig, false)
        }
        return nil
    }

    private func recordInterpolationFailure(_ reason: String, consecutiveFailures: Int, totalSuccesses: Int) {
        let shouldSurfaceError = (totalSuccesses == 0 && consecutiveFailures >= 5)
        if consecutiveFailures == 1 || shouldSurfaceError {
            logAsync("[ane][warn] 补帧失败(#\(consecutiveFailures)): \(reason)")
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.failedInterpolationCount += 1
            self.lastInterpolationError = reason
            if shouldSurfaceError && self.errorMessage == nil {
                self.isLoadingPipeline = false
                self.pipelineStatusText = ""
                self.errorMessage = "ANE 光流补帧连续失败：\(reason)"
            }
        }
    }

    private func resolveSourcePixelFormat(
        from configuration: VTLowLatencyFrameInterpolationConfiguration,
        prefer10Bit: Bool
    ) -> OSType {
        let raw = configuration.sourcePixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String]
        let preferredFormats: [OSType] = prefer10Bit ? [
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA
        ] : [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA
        ]
        if let num = raw as? NSNumber {
            return num.uint32Value
        }
        if let arr = raw as? [NSNumber] {
            let supported = arr.map(\.uint32Value)
            for candidate in preferredFormats where supported.contains(candidate) {
                return candidate
            }
            if let first = arr.first {
                return first.uint32Value
            }
        }
        return prefer10Bit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    private static func buildReaderOutputSettings(
        from configuration: VTLowLatencyFrameInterpolationConfiguration,
        pixelFormat: OSType
    ) -> [String: Any] {
        var settings: [String: Any] = [:]
        let inheritedKeys: [String] = [
            kCVPixelBufferBytesPerRowAlignmentKey as String,
            kCVPixelBufferPlaneAlignmentKey as String,
            kCVPixelBufferExtendedPixelsLeftKey as String,
            kCVPixelBufferExtendedPixelsRightKey as String,
            kCVPixelBufferExtendedPixelsTopKey as String,
            kCVPixelBufferExtendedPixelsBottomKey as String
        ]
        for key in inheritedKeys {
            if let value = configuration.sourcePixelBufferAttributes[key] {
                settings[key] = value
            }
        }
        settings[kCVPixelBufferPixelFormatTypeKey as String] = pixelFormat
        settings[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
        settings[kCVPixelBufferMetalCompatibilityKey as String] = true
        return settings
    }

    private func makeDestinationPool(
        configuration: VTLowLatencyFrameInterpolationConfiguration,
        fallbackWidth: Int,
        fallbackHeight: Int,
        fallbackFormat: OSType
    ) throws -> CVPixelBufferPool {
        var attrs: [String: Any] = [:]
        for (k, v) in configuration.destinationPixelBufferAttributes {
            attrs[k] = v
        }
        if attrs[kCVPixelBufferWidthKey as String] == nil {
            attrs[kCVPixelBufferWidthKey as String] = fallbackWidth
        }
        if attrs[kCVPixelBufferHeightKey as String] == nil {
            attrs[kCVPixelBufferHeightKey as String] = fallbackHeight
        }
        if let rawFmt = attrs[kCVPixelBufferPixelFormatTypeKey as String] {
            if let arr = rawFmt as? [NSNumber] {
                let fallbackNum = NSNumber(value: fallbackFormat)
                if arr.contains(fallbackNum) {
                    attrs[kCVPixelBufferPixelFormatTypeKey as String] = fallbackNum
                } else if let first = arr.first {
                    attrs[kCVPixelBufferPixelFormatTypeKey as String] = first
                } else {
                    attrs[kCVPixelBufferPixelFormatTypeKey as String] = fallbackFormat
                }
            }
        } else {
            attrs[kCVPixelBufferPixelFormatTypeKey as String] = fallbackFormat
        }
        attrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
        attrs[kCVPixelBufferMetalCompatibilityKey as String] = true

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw NSError(domain: "GlassMPV.OpticalFlow", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "无法创建 CVPixelBufferPool (\(status))"
            ])
        }
        return pool
    }

    private func scaleIfNeeded(
        _ sourceBuffer: CVPixelBuffer,
        spatial2x: Bool,
        transferSession: VTPixelTransferSession?,
        pool: CVPixelBufferPool
    ) -> CVPixelBuffer {
        guard spatial2x, let transferSession else {
            return sourceBuffer
        }
        var scaledBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &scaledBuffer) == kCVReturnSuccess,
              let destBuffer = scaledBuffer else {
            return sourceBuffer
        }
        let status = VTPixelTransferSessionTransferImage(transferSession, from: sourceBuffer, to: destBuffer)
        if status == noErr {
            CVBufferPropagateAttachments(sourceBuffer, destBuffer)
            return destBuffer
        }
        return sourceBuffer
    }
#endif

    func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, ptsSeconds: Double) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        let descStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard descStatus == noErr, let formatDesc else { return nil }

        let resolvedPTS: CMTime
        if let displayTimebase {
            resolvedPTS = CMTimebaseGetTime(displayTimebase)
        } else {
            resolvedPTS = CMTime(seconds: ptsSeconds, preferredTimescale: 600)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 120),
            presentationTimeStamp: resolvedPTS,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }

    private static func displayDimensions(naturalSize: CGSize, transform: CGAffineTransform) -> (width: Int, height: Int) {
        let w = Int(abs(naturalSize.width))
        let h = Int(abs(naturalSize.height))
        if SampleBufferDisplayContainerView.isQuarterTurnTransform(transform) {
            return (h, w)
        }
        return (w, h)
    }

    private static func shouldPrefer10Bit(from metrics: (width: Int, height: Int, codec: String, bitDepth: String, hdrTag: String)) -> Bool {
        metrics.bitDepth == "10-bit" || metrics.hdrTag != "SDR"
    }

    private static func extractTrackMetrics(
        from formatDescription: CMFormatDescription?,
        naturalSize: CGSize
    ) -> (width: Int, height: Int, codec: String, bitDepth: String, hdrTag: String) {
        let width = Int(abs(naturalSize.width))
        let height = Int(abs(naturalSize.height))
        guard let desc = formatDescription else {
            return (width, height, "", "--", "SDR")
        }

        let subType = CMFormatDescriptionGetMediaSubType(desc)
        let codec = fourCCString(subType)
        let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any]
        let transfer = extensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let transferLower = (transfer ?? "").lowercased()
        let isHDR = transferLower.contains("2084") || transferLower.contains("pq") || transferLower.contains("hlg")
        let hdrTag = PlaybackHUDMetrics.formatHDRTag(
            isHDRContent: isHDR,
            transferName: transfer,
            isHDRActive: false
        )

        let bitDepth: String
        if let bpc = extensions?[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int, bpc > 0 {
            bitDepth = "\(bpc)-bit"
        } else if isHDR {
            bitDepth = "10-bit"
        } else {
            bitDepth = "--"
        }

        return (width, height, codec, bitDepth, hdrTag)
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        let chars = bytes.map { byte -> Character in
            (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "?"
        }
        return String(chars).trimmingCharacters(in: .whitespaces)
    }
}

/// Apple Silicon 光流渲染图层桥接视图
struct OpticalFlowVideoSurface: UIViewRepresentable {
    let controller: OpticalFlowPlayerController

    func makeUIView(context: Context) -> SampleBufferDisplayContainerView {
        let view = SampleBufferDisplayContainerView(frame: .zero)
        controller.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: SampleBufferDisplayContainerView, context: Context) {
        uiView.applyVideoTransform(controller.videoTransform)
    }
}
