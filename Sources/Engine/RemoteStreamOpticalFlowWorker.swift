import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox

struct RemoteSendablePixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

struct RemoteOpticalFlowOutputFrame: @unchecked Sendable {
    let pts: Double
    let buffer: CVPixelBuffer
}

/// 面向云端流媒体 (`AVPlayerItemVideoOutput`) 的实时 ANE 硬件光流异步工作器
final class RemoteStreamOpticalFlowWorker: @unchecked Sendable {
    typealias FrameBatchCallback = @Sendable (
        _ frames: [RemoteOpticalFlowOutputFrame],
        _ interpolatedDelta: Int,
        _ avgMs: Double,
        _ backendLabel: String
    ) -> Void

    private let lock = NSLock()
    private let onBatch: FrameBatchCallback
    private var targetFPS: OpticalFlowTargetFPS
    private var sourceFPS: Double
    private var generation: UInt64 = 0
    private var pendingInput: (pts: Double, box: RemoteSendablePixelBuffer)?
    private var isProcessing = false
    private var wantsReconfigure = false

    private var previousFrame: (pts: Double, buffer: CVPixelBuffer)?
    private var phaseScheduler: OpticalFlowPhaseScheduler
    private var totalInterpolationMs: Double = 0
    private var batchCount: Int = 0

#if !targetEnvironment(simulator)
    private var processor: VTFrameProcessor?
    private var configuration: VTLowLatencyFrameInterpolationConfiguration?
    private var activeCandidate: OpticalFlowCandidate?
    private var activePixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    private var sourceNormPool: CVPixelBufferPool?
    private var sourceTransferSession: VTPixelTransferSession?
    private var destPool: CVPixelBufferPool?
    private var activeSignature: String = ""
    private var lastErrorLogTime: CFTimeInterval = 0
#endif

    init(
        targetFPS: OpticalFlowTargetFPS,
        sourceFPS: Double,
        onBatch: @escaping FrameBatchCallback
    ) {
        self.targetFPS = targetFPS
        let clamped = max(12.0, sourceFPS)
        self.sourceFPS = clamped
        self.phaseScheduler = OpticalFlowPhaseScheduler(targetTier: targetFPS, sourceFPS: clamped)
        self.onBatch = onBatch
    }

    func reconfigure(targetFPS: OpticalFlowTargetFPS, sourceFPS: Double) {
        lock.lock()
        self.targetFPS = targetFPS
        self.sourceFPS = max(12.0, sourceFPS)
        self.generation &+= 1
        self.pendingInput = nil
        self.wantsReconfigure = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        self.generation &+= 1
        self.pendingInput = nil
        self.wantsReconfigure = true
        lock.unlock()
    }

    func submitFrame(pts: Double, box: RemoteSendablePixelBuffer) {
        lock.lock()
        pendingInput = (pts: pts, box: box)
        let shouldLaunch = !isProcessing
        if shouldLaunch {
            isProcessing = true
        }
        lock.unlock()

        if shouldLaunch {
            Task.detached(priority: .userInteractive) { [weak self] in
                await self?.drainLoop()
            }
        }
    }

    private func popNextJob() -> (
        pts: Double,
        box: RemoteSendablePixelBuffer,
        generation: UInt64,
        targetFPS: OpticalFlowTargetFPS,
        sourceFPS: Double,
        needsReconfigure: Bool
    )? {
        lock.lock()
        defer { lock.unlock() }
        guard let next = pendingInput else {
            isProcessing = false
            return nil
        }
        pendingInput = nil
        let reconfig = wantsReconfigure
        wantsReconfigure = false
        return (next.pts, next.box, generation, targetFPS, sourceFPS, reconfig)
    }

    private func readGeneration() -> UInt64 {
        lock.lock()
        let g = generation
        lock.unlock()
        return g
    }

    private func drainLoop() async {
        while let job = popNextJob() {
            if job.needsReconfigure {
                previousFrame = nil
                phaseScheduler = OpticalFlowPhaseScheduler(targetTier: job.targetFPS, sourceFPS: job.sourceFPS)
                totalInterpolationMs = 0
                batchCount = 0
#if !targetEnvironment(simulator)
                teardownSession()
#endif
            }
            await processSingleFrame(
                pts: job.pts,
                currBuffer: job.box.buffer,
                jobGeneration: job.generation,
                targetFPS: job.targetFPS,
                sourceFPS: job.sourceFPS
            )
        }
    }

    private func processSingleFrame(
        pts currPTS: Double,
        currBuffer: CVPixelBuffer,
        jobGeneration: UInt64,
        targetFPS: OpticalFlowTargetFPS,
        sourceFPS: Double
    ) async {
#if targetEnvironment(simulator)
        previousFrame = (pts: currPTS, buffer: currBuffer)
        let avg = batchCount > 0 ? totalInterpolationMs / Double(batchCount) : 0
        onBatch([RemoteOpticalFlowOutputFrame(pts: currPTS, buffer: currBuffer)], 0, avg, "远程硬解直通")
        return
#else
        let srcW = CVPixelBufferGetWidth(currBuffer)
        let srcH = CVPixelBufferGetHeight(currBuffer)
        guard srcW >= 64, srcH >= 64 else {
            onBatch([RemoteOpticalFlowOutputFrame(pts: currPTS, buffer: currBuffer)], 0, 0, "远程硬解直通")
            return
        }

        if let prev = previousFrame {
            let dt = currPTS - prev.pts
            if dt <= 0.008 || dt >= 0.25 {
                previousFrame = (pts: currPTS, buffer: currBuffer)
                phaseScheduler.reset()
                onBatch([RemoteOpticalFlowOutputFrame(pts: currPTS, buffer: currBuffer)], 0, 0, activeCandidate?.displayLabel ?? "远程流直通")
                return
            }

            if ensureSession(srcWidth: srcW, srcHeight: srcH, targetFPS: targetFPS, sourceFPS: sourceFPS),
               let processor,
               let activeCandidate,
               let destPool {
                let maxSlots = max(1, targetFPS.maxInterpolatedFramesPerPair(sourceFPS: sourceFPS))
                let step = phaseScheduler.planStep(previousPTS: prev.pts, currentPTS: currPTS, maxAllowedSlots: maxSlots)
                if !step.interpolatedSlots.isEmpty,
                   let preparedPrev = prepareSourceBuffer(prev.buffer, targetWidth: activeCandidate.width, targetHeight: activeCandidate.height, targetFormat: activePixelFormat),
                   let preparedCurr = prepareSourceBuffer(currBuffer, targetWidth: activeCandidate.width, targetHeight: activeCandidate.height, targetFormat: activePixelFormat),
                   let prevFrame = VTFrameProcessorFrame(buffer: preparedPrev, presentationTimeStamp: CMTime(seconds: prev.pts, preferredTimescale: 600)),
                   let currFrame = VTFrameProcessorFrame(buffer: preparedCurr, presentationTimeStamp: CMTime(seconds: currPTS, preferredTimescale: 600)) {

                    var phases: [Float] = []
                    var destBuffers: [CVPixelBuffer] = []
                    var destFrames: [VTFrameProcessorFrame] = []
                    phases.reserveCapacity(step.interpolatedSlots.count)
                    destBuffers.reserveCapacity(step.interpolatedSlots.count)
                    destFrames.reserveCapacity(step.interpolatedSlots.count)

                    var allocOK = true
                    for slot in step.interpolatedSlots {
                        var destOpt: CVPixelBuffer?
                        let st = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, destPool, &destOpt)
                        guard st == kCVReturnSuccess,
                              let destBuf = destOpt,
                              let destFrame = VTFrameProcessorFrame(buffer: destBuf, presentationTimeStamp: CMTime(seconds: slot.pts, preferredTimescale: 600)) else {
                            allocOK = false
                            break
                        }
                        phases.append(slot.phase)
                        destBuffers.append(destBuf)
                        destFrames.append(destFrame)
                    }

                    if allocOK,
                       let params = VTLowLatencyFrameInterpolationParameters(
                           sourceFrame: currFrame,
                           previousFrame: prevFrame,
                           interpolationPhase: phases,
                           destinationFrames: destFrames
                       ) {
                        do {
                            let startHost = CACurrentMediaTime()
                            _ = try await processor.process(parameters: params)
                            guard readGeneration() == jobGeneration else { return }
                            let elapsedMs = (CACurrentMediaTime() - startHost) * 1000.0
                            totalInterpolationMs += elapsedMs
                            batchCount += 1
                            let avgMs = totalInterpolationMs / Double(max(1, batchCount))

                            var outFrames: [RemoteOpticalFlowOutputFrame] = []
                            outFrames.reserveCapacity(step.interpolatedSlots.count + 1)
                            for (slot, destBuf) in zip(step.interpolatedSlots, destBuffers) {
                                CVBufferPropagateAttachments(currBuffer, destBuf)
                                outFrames.append(RemoteOpticalFlowOutputFrame(pts: slot.pts, buffer: destBuf))
                            }
                            if step.shouldEmitOriginalFrame {
                                outFrames.append(RemoteOpticalFlowOutputFrame(pts: currPTS, buffer: currBuffer))
                            }
                            previousFrame = (pts: currPTS, buffer: currBuffer)
                            onBatch(outFrames, step.interpolatedSlots.count, avgMs, "远程·\(activeCandidate.displayLabel)")
                            return
                        } catch {
                            let now = CACurrentMediaTime()
                            if now - lastErrorLogTime > 2.0 {
                                lastErrorLogTime = now
                            }
                            teardownSession()
                        }
                    }
                }
            }
        }

        previousFrame = (pts: currPTS, buffer: currBuffer)
        let avg = batchCount > 0 ? totalInterpolationMs / Double(batchCount) : 0
        onBatch([RemoteOpticalFlowOutputFrame(pts: currPTS, buffer: currBuffer)], 0, avg, "远程硬解直通")
#endif
    }

#if !targetEnvironment(simulator)
    private func ensureSession(
        srcWidth: Int,
        srcHeight: Int,
        targetFPS: OpticalFlowTargetFPS,
        sourceFPS: Double
    ) -> Bool {
        let maxInterp = max(1, targetFPS.maxInterpolatedFramesPerPair(sourceFPS: sourceFPS))
        let exponent = OpticalFlowResolutionPlanner.lowLatencyExponent(forInterpolatedFrames: maxInterp)
        let sig = "\(srcWidth)x\(srcHeight):\(exponent)"
        if sig == activeSignature, processor != nil, destPool != nil {
            return true
        }
        teardownSession()

        guard VTLowLatencyFrameInterpolationConfiguration.isSupported else {
            return false
        }
        let allCandidates = OpticalFlowResolutionPlanner.buildCandidatePlan(
            sourceWidth: srcWidth,
            sourceHeight: srcHeight,
            requestedSpatial2x: false,
            lowLatencySupported: true,
            frcSupported: false,
            maxInterpolatedFrames: maxInterp
        )
        let cappedCandidates = allCandidates.filter { max($0.width, $0.height) <= 1280 }
        let searchList = cappedCandidates.isEmpty ? allCandidates : cappedCandidates

        for candidate in searchList where candidate.backend == .lowLatency {
            guard let config = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: candidate.width,
                frameHeight: candidate.height,
                numberOfInterpolatedFrames: exponent
            ) else {
                continue
            }
            let proc = VTFrameProcessor()
            do {
                try proc.startSession(configuration: config)
            } catch {
                proc.endSession()
                continue
            }

            let supportedFormats = (config.sourcePixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String] as? [NSNumber])?.map(\.uint32Value) ?? []
            let chosenFormat: OSType = supportedFormats.isEmpty
                ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                : OpticalFlowResolutionPlanner.selectOptimalPixelFormat(from: supportedFormats, prefer10Bit: false)

            let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 4]
            var srcNormAttrs: [String: Any] = [:]
            for (k, v) in config.sourcePixelBufferAttributes {
                srcNormAttrs[k] = v
            }
            srcNormAttrs[kCVPixelBufferWidthKey as String] = candidate.width
            srcNormAttrs[kCVPixelBufferHeightKey as String] = candidate.height
            srcNormAttrs[kCVPixelBufferPixelFormatTypeKey as String] = NSNumber(value: chosenFormat)
            if srcNormAttrs[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
                srcNormAttrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
            }
            if srcNormAttrs[kCVPixelBufferMetalCompatibilityKey as String] == nil {
                srcNormAttrs[kCVPixelBufferMetalCompatibilityKey as String] = true
            }
            var normPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, srcNormAttrs as CFDictionary, &normPool)

            var dstAttrs: [String: Any] = [:]
            for (k, v) in config.destinationPixelBufferAttributes {
                dstAttrs[k] = v
            }
            dstAttrs[kCVPixelBufferWidthKey as String] = candidate.width
            dstAttrs[kCVPixelBufferHeightKey as String] = candidate.height
            dstAttrs[kCVPixelBufferPixelFormatTypeKey as String] = NSNumber(value: chosenFormat)
            if dstAttrs[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
                dstAttrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
            }
            if dstAttrs[kCVPixelBufferMetalCompatibilityKey as String] == nil {
                dstAttrs[kCVPixelBufferMetalCompatibilityKey as String] = true
            }
            var outPool: CVPixelBufferPool?
            let dstStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, dstAttrs as CFDictionary, &outPool)
            guard dstStatus == kCVReturnSuccess, let outPool else {
                proc.endSession()
                continue
            }

            var xfer: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &xfer)

            self.processor = proc
            self.configuration = config
            self.activeCandidate = candidate
            self.activePixelFormat = chosenFormat
            self.sourceNormPool = normPool
            self.sourceTransferSession = xfer
            self.destPool = outPool
            self.activeSignature = sig
            return true
        }
        return false
    }

    private func prepareSourceBuffer(
        _ buffer: CVPixelBuffer,
        targetWidth: Int,
        targetHeight: Int,
        targetFormat: OSType
    ) -> CVPixelBuffer? {
        let hasIOSurface = CVPixelBufferGetIOSurface(buffer) != nil
        if hasIOSurface,
           CVPixelBufferGetWidth(buffer) == targetWidth,
           CVPixelBufferGetHeight(buffer) == targetHeight,
           CVPixelBufferGetPixelFormatType(buffer) == targetFormat {
            return buffer
        }
        guard let normPool = sourceNormPool, let xfer = sourceTransferSession else {
            return nil
        }
        var outOpt: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, normPool, &outOpt)
        guard status == kCVReturnSuccess, let outBuf = outOpt else { return nil }
        let xferStatus = VTPixelTransferSessionTransferImage(xfer, from: buffer, to: outBuf)
        guard xferStatus == noErr else { return nil }
        CVBufferPropagateAttachments(buffer, outBuf)
        return outBuf
    }

    private func teardownSession() {
        processor?.endSession()
        processor = nil
        configuration = nil
        activeCandidate = nil
        sourceNormPool = nil
        destPool = nil
        if let xfer = sourceTransferSession {
            VTPixelTransferSessionInvalidate(xfer)
            sourceTransferSession = nil
        }
        activeSignature = ""
    }
#endif
}
