import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import QuartzCore
import SwiftUI
import UIKit
import VideoToolbox

final class SampleBufferDisplayContainerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable:next force_cast
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Apple Silicon ANE 硬件光流真补帧播放控制器（基于 VideoToolbox VTFrameProcessor）
final class OpticalFlowPlayerController: ObservableObject, @unchecked Sendable {
    @Published @MainActor var isPaused: Bool = true
    @Published @MainActor var currentTime: Double = 0
    @Published @MainActor var duration: Double = 0
    @Published @MainActor var sourceFPS: Double = 0
    @Published @MainActor var interpolatedFPS: Double = 0
    @Published @MainActor var errorMessage: String?
    @Published @MainActor var isHardwareSupported: Bool = false
    @Published @MainActor var enableSpatial2xUpscale: Bool = false

    private let bufferLock = NSLock()
    private let tokenLock = NSLock()
    private var frameQueue: [(pts: Double, buffer: CVPixelBuffer)] = []
    private var maxQueuedFrames = 16

    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var audioPlayer: AVPlayer?
    private var timeObserver: Any?
    private var displayLink: CADisplayLink?

    private var currentURL: URL?
    private var sessionToken = UUID()
    private var playbackSpeed: Float = 1.0

    @MainActor
    func attach(to layer: AVSampleBufferDisplayLayer) {
        self.displayLayer = layer
    }

    @MainActor
    func load(url: URL, spatial2x: Bool) {
        stopInternal()
        currentURL = url
        enableSpatial2xUpscale = spatial2x
        errorMessage = nil

#if targetEnvironment(simulator)
        isHardwareSupported = false
        errorMessage = "iOS 模拟器不支持 VideoToolbox ANE 硬件光流，请切换回「MPV 超分核」。"
        return
#else
        let supported = VTLowLatencyFrameInterpolationConfiguration.isSupported
        isHardwareSupported = supported
        guard supported else {
            errorMessage = "当前设备不支持 VTLowLatencyFrameInterpolation，请切换回「MPV 超分核」。"
            return
        }

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.audioPlayer = player

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds.isFinite ? time.seconds : 0
            Task { @MainActor [weak self] in
                self?.currentTime = seconds
            }
        }

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
                self.duration = assetDuration.seconds.isFinite ? assetDuration.seconds : 0

                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = tracks.first else {
                    self.errorMessage = "光流核仅支持原生 MP4/MOV 容器；MKV/FLV 等封装请切换回「MPV 超分核」。"
                    return
                }

                // 仅保留音频时钟输出，关闭 AVPlayer 默认视频解码轨道
                for pTrack in item.tracks where pTrack.assetTrack?.mediaType == .video {
                    pTrack.isEnabled = false
                }

                let nominalRate = try await videoTrack.load(.nominalFrameRate)
                let naturalSize = try await videoTrack.load(.naturalSize)
                let srcFps = nominalRate > 0 ? Double(nominalRate) : 24.0
                self.sourceFPS = srcFps
                self.interpolatedFPS = srcFps * 2.0

                self.startPipeline(
                    url: url,
                    width: Int(abs(naturalSize.width)),
                    height: Int(abs(naturalSize.height)),
                    startSeconds: 0,
                    spatial2x: spatial2x,
                    token: token
                )

                player.rate = self.playbackSpeed
                self.isPaused = false
            } catch {
                self.errorMessage = "光流核加载失败（\(error.localizedDescription)），建议切换回「MPV 超分核」。"
            }
        }
#endif
    }

    @MainActor
    func togglePlayPause() {
        guard let audioPlayer else { return }
        if isPaused {
            audioPlayer.rate = playbackSpeed
            isPaused = false
        } else {
            audioPlayer.pause()
            isPaused = true
        }
    }

    @MainActor
    func pause() {
        audioPlayer?.pause()
        isPaused = true
    }

    @MainActor
    func setSpeed(_ speed: Double) {
        playbackSpeed = Float(speed)
        if !isPaused {
            audioPlayer?.rate = playbackSpeed
        }
    }

    @MainActor
    func seek(to seconds: Double) {
        guard let url = currentURL, let audioPlayer else { return }
        let clamped = max(0, min(seconds, duration))
        let targetCM = CMTime(seconds: clamped, preferredTimescale: 600)
        audioPlayer.seek(to: targetCM, toleranceBefore: .zero, toleranceAfter: .zero)
        clearBufferedFrames()

        let token = rotateToken()
        let spatial2x = self.enableSpatial2xUpscale

        Task { @MainActor [weak self] in
            guard let self else { return }
            let asset = AVURLAsset(url: url)
            guard let tracks = try? await asset.loadTracks(withMediaType: .video),
                  let videoTrack = tracks.first else { return }
            let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
            self.startPipeline(
                url: url,
                width: Int(abs(naturalSize.width)),
                height: Int(abs(naturalSize.height)),
                startSeconds: clamped,
                spatial2x: spatial2x,
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
        clearBufferedFrames()
        displayLayer?.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        isPaused = true
    }

    private func clearBufferedFrames() {
        bufferLock.lock()
        frameQueue.removeAll()
        bufferLock.unlock()
    }

    private func startPipeline(
        url: URL,
        width: Int,
        height: Int,
        startSeconds: Double,
        spatial2x: Bool,
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
        token: UUID
    ) async {
        do {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = tracks.first else {
                Task { @MainActor [weak self] in
                    self?.errorMessage = "未找到视频轨道，请切换回「MPV 超分核」。"
                }
                return
            }

            let configuration: VTLowLatencyFrameInterpolationConfiguration
            if spatial2x,
               let scaledConfig = VTLowLatencyFrameInterpolationConfiguration(
                   frameWidth: width,
                   frameHeight: height,
                   spatialScaleFactor: 2
               ) {
                configuration = scaledConfig
            } else if let frcConfig = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: width,
                frameHeight: height,
                numberOfInterpolatedFrames: 1
            ) {
                configuration = frcConfig
            } else {
                Task { @MainActor [weak self] in
                    self?.errorMessage = "无法初始化 VideoToolbox 光流配置（\(width)x\(height)）。"
                }
                return
            }

            let processor = VTFrameProcessor()
            try processor.startSession(configuration: configuration)
            defer { processor.endSession() }

            let pixelFormat = resolveSourcePixelFormat(from: configuration)

            let reader = try AVAssetReader(asset: asset)
            if startSeconds > 0 {
                reader.timeRange = CMTimeRange(
                    start: CMTime(seconds: startSeconds, preferredTimescale: 600),
                    duration: .positiveInfinity
                )
            }

            let outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
            trackOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(trackOutput) else {
                Task { @MainActor [weak self] in
                    self?.errorMessage = "无法读取视频轨道，建议切换「MPV 超分核」。"
                }
                return
            }
            reader.add(trackOutput)
            reader.startReading()

            let destPool = try makeDestinationPool(
                configuration: configuration,
                fallbackWidth: spatial2x ? width * 2 : width,
                fallbackHeight: spatial2x ? height * 2 : height,
                fallbackFormat: pixelFormat
            )

            var previousBuffer: CVPixelBuffer?
            var previousPTS: CMTime = .invalid

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

                if let prevBuf = previousBuffer,
                   previousPTS.isValid,
                   currentPTS > previousPTS,
                   let prevFrame = VTFrameProcessorFrame(buffer: prevBuf, presentationTimeStamp: previousPTS),
                   let currFrame = VTFrameProcessorFrame(buffer: currentBuffer, presentationTimeStamp: currentPTS) {
                    var destBufOpt: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, destPool, &destBufOpt)

                    if let destBuf = destBufOpt {
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
                                _ = try await processor.process(parameters: params)
                                enqueueDecodedFrame(pts: midSeconds, buffer: destBuf)
                            } catch {
                                // 单帧光流跳过，仍保留原帧播放
                            }
                        }
                    }
                }

                enqueueDecodedFrame(pts: currentPTS.seconds, buffer: currentBuffer)
                previousBuffer = currentBuffer
                previousPTS = currentPTS
            }
        } catch {
            let desc = error.localizedDescription
            Task { @MainActor [weak self] in
                self?.errorMessage = "光流插帧运行异常：\(desc)"
            }
        }
    }
#endif

    @MainActor
    @objc private func onDisplayTick() {
        guard let layer = displayLayer, let audioPlayer else { return }
        if let item = audioPlayer.currentItem {
            for pTrack in item.tracks where pTrack.isEnabled && pTrack.assetTrack?.mediaType == .video {
                pTrack.isEnabled = false
            }
        }

        let now = audioPlayer.currentTime().seconds
        guard now.isFinite else { return }

        var frameToPresent: CVPixelBuffer?
        bufferLock.lock()
        while let head = frameQueue.first, head.pts <= now + 0.004 {
            frameToPresent = head.buffer
            frameQueue.removeFirst()
        }
        bufferLock.unlock()

        if let buffer = frameToPresent,
           let sampleBuffer = makeSampleBuffer(from: buffer, ptsSeconds: now) {
            if layer.sampleBufferRenderer.status == .failed {
                layer.sampleBufferRenderer.flush()
            }
            if layer.sampleBufferRenderer.isReadyForMoreMediaData {
                layer.sampleBufferRenderer.enqueue(sampleBuffer)
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
        bufferLock.unlock()
    }

#if !targetEnvironment(simulator)
    private func resolveSourcePixelFormat(from configuration: VTLowLatencyFrameInterpolationConfiguration) -> OSType {
        let raw = configuration.sourcePixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String]
        if let num = raw as? NSNumber {
            return num.uint32Value
        }
        if let arr = raw as? [NSNumber], let first = arr.first {
            return first.uint32Value
        }
        return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
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
        if attrs[kCVPixelBufferPixelFormatTypeKey as String] == nil {
            attrs[kCVPixelBufferPixelFormatTypeKey as String] = fallbackFormat
        }
        attrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw NSError(domain: "GlassMPV.OpticalFlow", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "无法创建 CVPixelBufferPool (\(status))"
            ])
        }
        return pool
    }
#endif

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, ptsSeconds: Double) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        let descStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard descStatus == noErr, let formatDesc else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 120),
            presentationTimeStamp: CMTime(seconds: ptsSeconds, preferredTimescale: 600),
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
        return status == noErr ? sampleBuffer : nil
    }
}

/// Apple Silicon 光流渲染图层桥接视图
struct OpticalFlowVideoSurface: UIViewRepresentable {
    let controller: OpticalFlowPlayerController

    func makeUIView(context: Context) -> SampleBufferDisplayContainerView {
        let view = SampleBufferDisplayContainerView(frame: .zero)
        controller.attach(to: view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: SampleBufferDisplayContainerView, context: Context) {}
}
