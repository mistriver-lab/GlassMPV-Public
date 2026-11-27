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

/// 跨平台云端流媒体光流预算与动态送显时钟规划器（可独立在模拟器单测）
enum RemoteOpticalFlowBudgetPlanner: Sendable {
    static func resolutionCaps(forMaxInterpolatedFrames maxInterp: Int) -> [(Int, Int)] {
        if maxInterp <= 1 {
            return [(1920, 1080), (1280, 720)]
        }
        if maxInterp <= 3 {
            return [(1440, 810), (1280, 720), (960, 540)]
        }
        return [(1280, 720), (960, 540)]
    }

    static func shouldEmitPreparedOriginalFrame(
        sourceWidth: Int,
        sourceHeight: Int,
        candidateWidth: Int,
        candidateHeight: Int
    ) -> Bool {
        candidateWidth < sourceWidth || candidateHeight < sourceHeight
    }

    static func isCatchUpOverload(
        skippedInputs: Int,
        processMs: Double,
        sourceIntervalMs: Double
    ) -> Bool {
        guard skippedInputs > 0 else { return false }
        return processMs > max(4.0, sourceIntervalMs) * 0.85
    }

    static func recommendedPacerLagSeconds(
        sourceFPS: Double,
        averageInterpolationMs: Double,
        targetFPS: OpticalFlowTargetFPS
    ) -> Double {
        let clampedFPS = max(12.0, min(120.0, sourceFPS.isFinite ? sourceFPS : 24.0))
        let frameInterval = 1.0 / clampedFPS
        let defaultInferMs = targetFPS == .x2 ? 18.0 : 28.0
        let rawInferMs = (averageInterpolationMs.isFinite && averageInterpolationMs > 0)
            ? averageInterpolationMs
            : defaultInferMs
        let inferSec = max(0.015, min(0.095, rawInferMs / 1000.0))
        return min(0.195, max(0.095, frameInterval + inferSec + 0.040))
    }

    static func buildRemoteCandidatePlan(
        sourceWidth: Int,
        sourceHeight: Int,
        maxInterpolatedFrames: Int
    ) -> [OpticalFlowCandidate] {
        let safeW = max(2, sourceWidth)
        let safeH = max(2, sourceHeight)
        let safeMaxInterp = max(1, maxInterpolatedFrames)
        let caps = resolutionCaps(forMaxInterpolatedFrames: safeMaxInterp)

        var plan: [OpticalFlowCandidate] = []
        for (longCap, shortCap) in caps {
            let fitted = OpticalFlowResolutionPlanner.fitProportionally(
                width: safeW,
                height: safeH,
                maxLongSide: longCap,
                maxShortSide: shortCap
            )
            let candidate = OpticalFlowCandidate(
                backend: .lowLatency,
                width: fitted.width,
                height: fitted.height,
                spatial2x: false,
                maxInterpolatedFrames: safeMaxInterp
            )
            if !plan.contains(candidate) {
                plan.append(candidate)
            }
        }
        return plan
    }
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
    private let onTargetDowngrade: (@Sendable (_ newTarget: OpticalFlowTargetFPS, _ reason: String) -> Void)?
    private let onLog: (@Sendable (_ message: String) -> Void)?

    private var targetFPS: OpticalFlowTargetFPS
    private var sourceFPS: Double
    private var generation: UInt64 = 0
    private var pendingInputs: [(pts: Double, box: RemoteSendablePixelBuffer)] = []
    private var isProcessing = false
    private var wantsReconfigure = false
    private var droppedInputCounter: Int = 0

    private var previousFrame: (
        pts: Double,
        rawBuffer: CVPixelBuffer,
        preparedBuffer: CVPixelBuffer?,
        preparedWidth: Int,
        preparedHeight: Int,
        preparedFormat: OSType
    )?
    private var phaseScheduler: OpticalFlowPhaseScheduler
    private var budgetGuard = OpticalFlowBudgetGuard(
        windowSize: 12,
        overloadRatioThreshold: 0.92,
        consecutiveOverloadWindowsRequired: 2,
        maxConsecutiveCatchUpSkips: 5,
        cooldownPairs: 30
    )
    private var warmupPairsRemaining: Int = 8
    private var totalInterpolationMs: Double = 0
    private var batchCount: Int = 0

#if !targetEnvironment(simulator)
    private var processor: VTFrameProcessor?
    private var configuration: VTLowLatencyFrameInterpolationConfiguration?
    private var activeCandidate: OpticalFlowCandidate?
    private var candidates: [OpticalFlowCandidate] = []
    private var candidateIndex: Int = 0
    private var candidatePlanSignature: String = ""
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
        onTargetDowngrade: (@Sendable (_ newTarget: OpticalFlowTargetFPS, _ reason: String) -> Void)? = nil,
        onLog: (@Sendable (_ message: String) -> Void)? = nil,
        onBatch: @escaping FrameBatchCallback
    ) {
        self.targetFPS = targetFPS
        let clamped = max(12.0, sourceFPS)
        self.sourceFPS = clamped
        self.phaseScheduler = OpticalFlowPhaseScheduler(targetTier: targetFPS, sourceFPS: clamped)
        self.onTargetDowngrade = onTargetDowngrade
        self.onLog = onLog
        self.onBatch = onBatch
    }

    func reconfigure(targetFPS: OpticalFlowTargetFPS, sourceFPS: Double) {
        lock.lock()
        self.targetFPS = targetFPS
        self.sourceFPS = max(12.0, sourceFPS)
        self.generation &+= 1
        self.pendingInputs.removeAll(keepingCapacity: true)
        self.droppedInputCounter = 0
        self.wantsReconfigure = true
        self.warmupPairsRemaining = 8
        lock.unlock()
    }

    func reset() {
        lock.lock()
        self.generation &+= 1
        self.pendingInputs.removeAll(keepingCapacity: true)
        self.droppedInputCounter = 0
        self.wantsReconfigure = true
        self.warmupPairsRemaining = 8
        lock.unlock()
    }

    func submitFrame(pts: Double, box: RemoteSendablePixelBuffer) {
        lock.lock()
        if pendingInputs.count >= 6 {
            pendingInputs.removeFirst()
            droppedInputCounter += 1
        }
        pendingInputs.append((pts: pts, box: box))
        let shouldLaunch = !isProcessing
        if shouldLaunch {
            isProcessing = true
        }
        lock.unlock()

        if shouldLaunch {
            Task.detached(priority: .high) { [weak self] in
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
        needsReconfigure: Bool,
        skippedCount: Int
    )? {
        lock.lock()
        defer { lock.unlock() }
        guard !pendingInputs.isEmpty else {
            isProcessing = false
            return nil
        }
        let next = pendingInputs.removeFirst()
        let reconfig = wantsReconfigure
        wantsReconfigure = false
        let skipped = droppedInputCounter
        droppedInputCounter = 0
        return (next.pts, next.box, generation, targetFPS, sourceFPS, reconfig, skipped)
    }

    private func readGeneration() -> UInt64 {
        lock.lock()
        let g = generation
        lock.unlock()
        return g
    }

    private func updateWorkerTargetTier(_ newTier: OpticalFlowTargetFPS) {
        lock.lock()
        self.targetFPS = newTier
        lock.unlock()
    }

    private func drainLoop() async {
        var workingTargetFPS: OpticalFlowTargetFPS?
        while let job = popNextJob() {
            if job.needsReconfigure {
                previousFrame = nil
                workingTargetFPS = job.targetFPS
                phaseScheduler = OpticalFlowPhaseScheduler(targetTier: job.targetFPS, sourceFPS: job.sourceFPS)
                budgetGuard.reset()
                warmupPairsRemaining = 8
                totalInterpolationMs = 0
                batchCount = 0
#if !targetEnvironment(simulator)
                candidateIndex = 0
                candidates.removeAll(keepingCapacity: true)
                candidatePlanSignature = ""
                teardownSession()
#endif
            }
            let effectiveTier = workingTargetFPS ?? job.targetFPS
            let updatedTier = await processSingleFrame(
                pts: job.pts,
                currBuffer: job.box.buffer,
                jobGeneration: job.generation,
                targetFPS: effectiveTier,
                sourceFPS: job.sourceFPS,
                skippedInputs: job.skippedCount
            )
            if let updatedTier {
                workingTargetFPS = updatedTier
            }
        }
    }

    private func processSingleFrame(
        pts currPTS: Double,
        currBuffer: CVPixelBuffer,
        jobGeneration: UInt64,
        targetFPS: OpticalFlowTargetFPS,
        sourceFPS: Double,
        skippedInputs: Int
    ) async -> OpticalFlowTargetFPS? {
#if targetEnvironment(simulator)
        previousFrame = (pts: currPTS, rawBuffer: currBuffer, preparedBuffer: nil, preparedWidth: 0, preparedHeight: 0, preparedFormat: 0)
        let avg = batchCount > 0 ? totalInterpolationMs / Double(batchCount) : 0
        onBatch([RemoteOpticalFlowOutputFrame(pts: currPTS, buffer: currBuffer)], 0, avg, "远程硬解直通")
        return nil
#else
        let srcW = CVPixelBufferGetWidth(currBuffer)
        let srcH = CVPixelBufferGetHeight(currBuffer)
        guard srcW >= 64, srcH >= 64 else {
            onBatch([RemoteOpticalFlowOutputFrame(pts: currPTS, buffer: currBuffer)], 0, 0, "远程硬解直通")
            return nil
        }

        if let prev = previousFrame {
            let dt = currPTS - prev.pts
            if dt <= 0.008 || dt >= 0.35 {
                previousFrame = (pts: currPTS, rawBuffer: currBuffer, preparedBuffer: nil, preparedWidth: 0, preparedHeight: 0, preparedFormat: 0)
                phaseScheduler.reset()
                onBatch([RemoteOpticalFlowOutputFrame(pts: currPTS, buffer: currBuffer)], 0, 0, activeCandidate?.displayLabel ?? "远程流直通")
                return nil
            }

            if ensureSession(srcWidth: srcW, srcHeight: srcH, targetFPS: targetFPS, sourceFPS: sourceFPS),
               let processor,
               let activeCandidate,
               let destPool {
                let maxSlots = max(1, targetFPS.maxInterpolatedFramesPerPair(sourceFPS: sourceFPS))
                let step = phaseScheduler.planStep(previousPTS: prev.pts, currentPTS: currPTS, maxAllowedSlots: maxSlots)
                let pairStartHost = CACurrentMediaTime()
                let reusedPrev: CVPixelBuffer? = (prev.preparedWidth == activeCandidate.width
                    && prev.preparedHeight == activeCandidate.height
                    && prev.preparedFormat == activePixelFormat)
                    ? prev.preparedBuffer
                    : nil
                if !step.interpolatedSlots.isEmpty,
                   let preparedPrev = reusedPrev ?? prepareSourceBuffer(
                       prev.rawBuffer,
                       targetWidth: activeCandidate.width,
                       targetHeight: activeCandidate.height,
                       targetFormat: activePixelFormat
                   ),
                   let preparedCurr = prepareSourceBuffer(
                       currBuffer,
                       targetWidth: activeCandidate.width,
                       targetHeight: activeCandidate.height,
                       targetFormat: activePixelFormat
                   ),
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
                            _ = try await processor.process(parameters: params)
                            guard readGeneration() == jobGeneration else { return nil }
                            let elapsedMs = (CACurrentMediaTime() - pairStartHost) * 1000.0
                            totalInterpolationMs += elapsedMs
                            batchCount += 1
                            let avgMs = totalInterpolationMs / Double(max(1, batchCount))

                            var outFrames: [RemoteOpticalFlowOutputFrame] = []
                            outFrames.reserveCapacity(step.interpolatedSlots.count + 1)
                            for (slot, destBuf) in zip(step.interpolatedSlots, destBuffers) {
                                CVBufferPropagateAttachments(currBuffer, destBuf)
                                outFrames.append(RemoteOpticalFlowOutputFrame(pts: slot.pts, buffer: destBuf))
                            }
                            if step.shouldEmitOriginalFrame || outFrames.isEmpty {
                                let originalOutBuffer: CVPixelBuffer = RemoteOpticalFlowBudgetPlanner.shouldEmitPreparedOriginalFrame(
                                    sourceWidth: srcW,
                                    sourceHeight: srcH,
                                    candidateWidth: activeCandidate.width,
                                    candidateHeight: activeCandidate.height
                                ) ? preparedCurr : currBuffer
                                outFrames.append(RemoteOpticalFlowOutputFrame(pts: currPTS, buffer: originalOutBuffer))
                            }
                            let emittedLabel = "远程·\(activeCandidate.displayLabel)"
                            previousFrame = (
                                pts: currPTS,
                                rawBuffer: currBuffer,
                                preparedBuffer: preparedCurr,
                                preparedWidth: activeCandidate.width,
                                preparedHeight: activeCandidate.height,
                                preparedFormat: activePixelFormat
                            )
                            onBatch(outFrames, step.interpolatedSlots.count, avgMs, emittedLabel)

                            if warmupPairsRemaining > 0 {
                                warmupPairsRemaining -= 1
                                return nil
                            }

                            let sourceIntervalMs = 1000.0 / max(12.0, sourceFPS)
                            let canDowngradeRes = (candidateIndex + 1) < candidates.count
                            let canDowngradeFPS = targetFPS.nextLowerTier != nil
                            let catchUpOverload = RemoteOpticalFlowBudgetPlanner.isCatchUpOverload(
                                skippedInputs: skippedInputs,
                                processMs: elapsedMs,
                                sourceIntervalMs: sourceIntervalMs
                            )
                            let action = budgetGuard.recordPair(
                                processMs: elapsedMs,
                                sourceIntervalMs: sourceIntervalMs,
                                skippedForCatchUp: catchUpOverload,
                                canDowngradeResolution: canDowngradeRes,
                                canDowngradeTargetFPS: canDowngradeFPS
                            )
                            switch action {
                            case .keep:
                                return nil
                            case .downgradeResolution:
                                if candidateIndex + 1 < candidates.count {
                                    let prevLabel = activeCandidate.displayLabel
                                    candidateIndex += 1
                                    let nextLabel = candidates[candidateIndex].displayLabel
                                    teardownSession()
                                    totalInterpolationMs = 0
                                    batchCount = 0
                                    onLog?("[remote][perf] 远程光流超预算 (单对=\(String(format: "%.1f", elapsedMs))ms, 均值=\(String(format: "%.1f", avgMs))ms, 预算=\(String(format: "%.1f", sourceIntervalMs))ms)，\(prevLabel) 自动降分辨率 -> \(nextLabel)")
                                    return nil
                                } else if let lower = targetFPS.nextLowerTier {
                                    updateWorkerTargetTier(lower)
                                    phaseScheduler = OpticalFlowPhaseScheduler(targetTier: lower, sourceFPS: sourceFPS)
                                    candidateIndex = 0
                                    candidates.removeAll(keepingCapacity: true)
                                    candidatePlanSignature = ""
                                    teardownSession()
                                    totalInterpolationMs = 0
                                    batchCount = 0
                                    onTargetDowngrade?(lower, "远程光流分辨率已触底，自动稳帧降档至 \(lower.shortBadge)")
                                    return lower
                                }
                            case .downgradeTargetFPS:
                                if let lower = targetFPS.nextLowerTier {
                                    updateWorkerTargetTier(lower)
                                    phaseScheduler = OpticalFlowPhaseScheduler(targetTier: lower, sourceFPS: sourceFPS)
                                    candidateIndex = 0
                                    candidates.removeAll(keepingCapacity: true)
                                    candidatePlanSignature = ""
                                    teardownSession()
                                    totalInterpolationMs = 0
                                    batchCount = 0
                                    onTargetDowngrade?(lower, "远程光流持续超预算或追帧跳过，自动稳帧至 \(lower.shortBadge)")
                                    return lower
                                }
                            }
                            return nil
                        } catch {
                            let now = CACurrentMediaTime()
                            if now - lastErrorLogTime > 2.0 {
                                lastErrorLogTime = now
                                onLog?("[remote][warn] 远程光流推理异常 (\(activeCandidate.displayLabel)): \(error.localizedDescription)")
                            }
                            teardownSession()
                        }
                    }
                } else if step.interpolatedSlots.isEmpty {
                    previousFrame = (pts: currPTS, rawBuffer: currBuffer, preparedBuffer: nil, preparedWidth: 0, preparedHeight: 0, preparedFormat: 0)
                    let avg = batchCount > 0 ? totalInterpolationMs / Double(batchCount) : 0
                    onBatch([RemoteOpticalFlowOutputFrame(pts: currPTS, buffer: currBuffer)], 0, avg, "远程·\(activeCandidate.displayLabel)")
                    return nil
                }
            }
        }

        previousFrame = (pts: currPTS, rawBuffer: currBuffer, preparedBuffer: nil, preparedWidth: 0, preparedHeight: 0, preparedFormat: 0)
        let avg = batchCount > 0 ? totalInterpolationMs / Double(batchCount) : 0
        onBatch([RemoteOpticalFlowOutputFrame(pts: currPTS, buffer: currBuffer)], 0, avg, "远程硬解直通")
        return nil
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
        let planSig = "\(srcWidth)x\(srcHeight):\(maxInterp)"
        if planSig != candidatePlanSignature {
            candidates = RemoteOpticalFlowBudgetPlanner.buildRemoteCandidatePlan(
                sourceWidth: srcWidth,
                sourceHeight: srcHeight,
                maxInterpolatedFrames: maxInterp
            )
            candidatePlanSignature = planSig
            candidateIndex = 0
        }
        guard candidateIndex < candidates.count else {
            return false
        }
        let sig = "\(planSig):\(exponent):idx\(candidateIndex)"
        if sig == activeSignature, processor != nil, destPool != nil {
            return true
        }
        teardownSession()

        guard VTLowLatencyFrameInterpolationConfiguration.isSupported else {
            return false
        }

        for index in candidateIndex..<candidates.count {
            let candidate = candidates[index]
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

            let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 6]
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
            self.candidateIndex = index
            self.activeCandidate = candidate
            self.activePixelFormat = chosenFormat
            self.sourceNormPool = normPool
            self.sourceTransferSession = xfer
            self.destPool = outPool
            self.activeSignature = "\(planSig):\(exponent):idx\(index)"
            self.warmupPairsRemaining = 8
            onLog?("[remote][ane] 已激活远程光流会话: \(candidate.displayLabel) (exp=\(exponent), fmt=\(HEVCFormatNormalizer.fourCCString(chosenFormat)))")
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
