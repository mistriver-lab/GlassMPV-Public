import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox

struct RemoteSendablePixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

enum RemoteOpticalFlowPayload: @unchecked Sendable {
    case pixelBuffer(CVPixelBuffer)
    case flowWarped(
        prevBuffer: CVPixelBuffer,
        currBuffer: CVPixelBuffer,
        forwardFlow: CVPixelBuffer,
        backwardFlow: CVPixelBuffer,
        phase: Float,
        flowSignX: Float = 1.0,
        flowSignY: Float = 1.0,
        isNormalizedUV: Bool = false
    )
    case metalFlowWarped(
        prevBuffer: CVPixelBuffer,
        currBuffer: CVPixelBuffer,
        forwardFlow: SendableMetalTexture,
        backwardFlow: SendableMetalTexture,
        phase: Float,
        isSceneCut: Bool = false
    )
}

struct RemoteOpticalFlowOutputFrame: @unchecked Sendable {
    let pts: Double
    let payload: RemoteOpticalFlowPayload

    init(pts: Double, payload: RemoteOpticalFlowPayload) {
        self.pts = pts
        self.payload = payload
    }

    init(pts: Double, buffer: CVPixelBuffer) {
        self.pts = pts
        self.payload = .pixelBuffer(buffer)
    }

    var rawFallbackBuffer: CVPixelBuffer {
        switch payload {
        case .pixelBuffer(let buffer):
            return buffer
        case .flowWarped(_, let currBuffer, _, _, _, _, _, _):
            return currBuffer
        case .metalFlowWarped(_, let currBuffer, _, _, _, _):
            return currBuffer
        }
    }
}

struct FlowVectorCalibration: Equatable, Sendable {
    var signX: Float = 1.0
    var signY: Float = 1.0
    var isNormalizedUV: Bool = false
    var isLocked: Bool = false
    var baselineSAD: Float = 0
    var calibratedSAD: Float = 0
    var rawP90: Float = 0
}

enum FlowVectorCalibrator: Sendable {
    static func decodeFloat16(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exp = Int((bits >> 10) & 0x1F)
        let frac = UInt32(bits & 0x03FF)
        if exp == 0 {
            if frac == 0 {
                return Float(bitPattern: sign)
            }
            var val = Float(frac) / 1024.0 * powf(2.0, -14.0)
            if sign != 0 { val = -val }
            return val
        } else if exp == 31 {
            if frac == 0 {
                return Float(bitPattern: sign | 0x7F800000)
            }
            return Float.nan
        }
        let f32Exp = UInt32(exp + 112) << 23
        let f32Mant = frac << 13
        return Float(bitPattern: sign | f32Exp | f32Mant)
    }

    static func encodeFloat16(_ value: Float) -> UInt16 {
        if value.isNaN { return 0x7E00 }
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exp = Int((bits >> 23) & 0xFF) - 127
        let mant = bits & 0x007FFFFF
        if exp > 15 { return sign | 0x7C00 }
        if exp < -14 {
            if exp < -24 { return sign }
            let shifted = (0x00800000 | mant) >> UInt32(-14 - exp + 13)
            return sign | UInt16(shifted & 0x03FF)
        }
        let hExp = UInt16((exp + 15) & 0x1F) << 10
        let hMant = UInt16((mant >> 13) & 0x03FF)
        return sign | hExp | hMant
    }

    static func selectOptimalFlowSourceFormat(from supportedFormats: [OSType]) -> OSType {
        let priority: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_32ARGB
        ]
        for candidate in priority where supportedFormats.contains(candidate) {
            return candidate
        }
        return supportedFormats.first ?? kCVPixelFormatType_32BGRA
    }

    private static func sampleLuma(
        base: UnsafePointer<UInt8>,
        bpr: Int,
        width: Int,
        height: Int,
        u: Float,
        v: Float
    ) -> Float {
        let px = max(0.0, min(Float(width - 1), u * Float(width - 1)))
        let py = max(0.0, min(Float(height - 1), v * Float(height - 1)))
        let x0 = Int(floor(px))
        let y0 = Int(floor(py))
        let x1 = min(width - 1, x0 + 1)
        let y1 = min(height - 1, y0 + 1)
        let fx = px - Float(x0)
        let fy = py - Float(y0)
        let p00 = Float(base[y0 * bpr + x0])
        let p10 = Float(base[y0 * bpr + x1])
        let p01 = Float(base[y1 * bpr + x0])
        let p11 = Float(base[y1 * bpr + x1])
        let top = p00 + (p10 - p00) * fx
        let bot = p01 + (p11 - p01) * fx
        return top + (bot - top) * fy
    }

    static func calibrate(
        prevBuffer: CVPixelBuffer,
        currBuffer: CVPixelBuffer,
        forwardFlow: CVPixelBuffer
    ) -> FlowVectorCalibration? {
        let prevW = CVPixelBufferGetWidth(prevBuffer)
        let prevH = CVPixelBufferGetHeight(prevBuffer)
        let currW = CVPixelBufferGetWidth(currBuffer)
        let currH = CVPixelBufferGetHeight(currBuffer)
        let flowW = CVPixelBufferGetWidth(forwardFlow)
        let flowH = CVPixelBufferGetHeight(forwardFlow)
        guard prevW >= 32, prevH >= 32, currW == prevW, currH == prevH, flowW >= 8, flowH >= 8 else {
            return nil
        }

        let flowFmt = CVPixelBufferGetPixelFormatType(forwardFlow)
        let isHalfFlow = (flowFmt == kCVPixelFormatType_TwoComponent16Half)
        let isFloatFlow = (flowFmt == kCVPixelFormatType_TwoComponent32Float)
        guard isHalfFlow || isFloatFlow else {
            return nil
        }

        let prevFmt = CVPixelBufferGetPixelFormatType(prevBuffer)
        let currFmt = CVPixelBufferGetPixelFormatType(currBuffer)
        let prevIsYUV = RemoteOpticalFlowBudgetPlanner.is8BitSDRBiPlanarFormat(prevFmt)
        let currIsYUV = RemoteOpticalFlowBudgetPlanner.is8BitSDRBiPlanarFormat(currFmt)
        guard prevIsYUV, currIsYUV else {
            return nil
        }

        CVPixelBufferLockBaseAddress(prevBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(currBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(forwardFlow, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(forwardFlow, .readOnly)
            CVPixelBufferUnlockBaseAddress(currBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(prevBuffer, .readOnly)
        }

        guard let prevBaseRaw = CVPixelBufferGetBaseAddressOfPlane(prevBuffer, 0),
              let currBaseRaw = CVPixelBufferGetBaseAddressOfPlane(currBuffer, 0) else {
            return nil
        }
        let flowBaseRaw = (CVPixelBufferGetPlaneCount(forwardFlow) > 0)
            ? CVPixelBufferGetBaseAddressOfPlane(forwardFlow, 0)
            : CVPixelBufferGetBaseAddress(forwardFlow)
        guard let flowBaseRaw else {
            return nil
        }

        let prevBase = prevBaseRaw.assumingMemoryBound(to: UInt8.self)
        let currBase = currBaseRaw.assumingMemoryBound(to: UInt8.self)
        let prevBPR = CVPixelBufferGetBytesPerRowOfPlane(prevBuffer, 0)
        let currBPR = CVPixelBufferGetBytesPerRowOfPlane(currBuffer, 0)
        let flowBPR = (CVPixelBufferGetPlaneCount(forwardFlow) > 0)
            ? CVPixelBufferGetBytesPerRowOfPlane(forwardFlow, 0)
            : CVPixelBufferGetBytesPerRow(forwardFlow)

        let gridX = 24
        let gridY = 14
        struct SamplePoint {
            let u: Float
            let v: Float
            let y0: Float
            let dx: Float
            let dy: Float
        }
        var samples: [SamplePoint] = []
        samples.reserveCapacity(gridX * gridY)
        var mags: [Float] = []
        mags.reserveCapacity(gridX * gridY)
        var baselineSum: Float = 0

        for iy in 0..<gridY {
            let v = 0.1 + 0.8 * (Float(iy) / Float(max(1, gridY - 1)))
            let fy = max(0, min(flowH - 1, Int((v * Float(flowH - 1)).rounded())))
            for ix in 0..<gridX {
                let u = 0.1 + 0.8 * (Float(ix) / Float(max(1, gridX - 1)))
                let fx = max(0, min(flowW - 1, Int((u * Float(flowW - 1)).rounded())))
                let dx: Float
                let dy: Float
                if isHalfFlow {
                    let rowPtr = flowBaseRaw.advanced(by: fy * flowBPR + fx * 4).assumingMemoryBound(to: UInt16.self)
                    dx = decodeFloat16(rowPtr[0])
                    dy = decodeFloat16(rowPtr[1])
                } else {
                    let ptr = flowBaseRaw.advanced(by: fy * flowBPR + fx * 8)
                    dx = ptr.loadUnaligned(as: Float.self)
                    dy = ptr.advanced(by: 4).loadUnaligned(as: Float.self)
                }
                guard dx.isFinite, dy.isFinite else { continue }
                let y0 = sampleLuma(base: prevBase, bpr: prevBPR, width: prevW, height: prevH, u: u, v: v)
                let y1Zero = sampleLuma(base: currBase, bpr: currBPR, width: currW, height: currH, u: u, v: v)
                baselineSum += abs(y0 - y1Zero)
                let mag = hypotf(dx, dy)
                mags.append(mag)
                samples.append(SamplePoint(u: u, v: v, y0: y0, dx: dx, dy: dy))
            }
        }

        guard !samples.isEmpty else { return nil }
        let baselineSAD = baselineSum / Float(samples.count)
        let sortedMags = mags.sorted()
        let rawP90 = sortedMags[min(sortedMags.count - 1, Int(Float(sortedMags.count) * 0.9))]
        guard baselineSAD >= 2.5, rawP90 >= 0.002 else {
            return nil
        }

        var unitCandidates: [(isNormalized: Bool, sxScale: Float, syScale: Float)] = [
            (false, 1.0 / Float(flowW), 1.0 / Float(flowH))
        ]
        if rawP90 < 0.25 {
            unitCandidates.append((true, 1.0, 1.0))
        }
        let signPairs: [(Float, Float)] = [(1, 1), (-1, -1), (1, -1), (-1, 1)]

        var bestSAD = Float.greatestFiniteMagnitude
        var bestSignX: Float = 1.0
        var bestSignY: Float = 1.0
        var bestNormalized = false

        for unit in unitCandidates {
            for (sx, sy) in signPairs {
                var sadSum: Float = 0
                for s in samples {
                    let nu = max(0.0, min(1.0, s.u + sx * s.dx * unit.sxScale))
                    let nv = max(0.0, min(1.0, s.v + sy * s.dy * unit.syScale))
                    let y1 = sampleLuma(base: currBase, bpr: currBPR, width: currW, height: currH, u: nu, v: nv)
                    sadSum += abs(s.y0 - y1)
                }
                let meanSAD = sadSum / Float(samples.count)
                if meanSAD < bestSAD {
                    bestSAD = meanSAD
                    bestSignX = sx
                    bestSignY = sy
                    bestNormalized = unit.isNormalized
                }
            }
        }

        guard bestSAD < baselineSAD * 0.90 else {
            return nil
        }
        return FlowVectorCalibration(
            signX: bestSignX,
            signY: bestSignY,
            isNormalizedUV: bestNormalized,
            isLocked: true,
            baselineSAD: baselineSAD,
            calibratedSAD: bestSAD,
            rawP90: rawP90
        )
    }
}

/// 跨平台云端流媒体光流预算与动态送显时钟规划器（可独立在模拟器单测）
enum RemoteOpticalFlowBudgetPlanner: Sendable {
    static func is8BitSDRBiPlanarFormat(_ pixelFormat: OSType) -> Bool {
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    static func shouldUseHybridFlowWarp(
        sourceWidth: Int,
        sourceHeight: Int,
        targetFPS: OpticalFlowTargetFPS,
        isHDR: Bool,
        isDolbyVision: Bool,
        is8BitSDRPixelFormat: Bool = true,
        allowExperimentalFlowWarp: Bool = true
    ) -> Bool {
        guard allowExperimentalFlowWarp else {
            return false
        }
        guard !isHDR, !isDolbyVision, is8BitSDRPixelFormat else {
            return false
        }
        guard targetFPS != .x2 else {
            return false
        }
        return max(sourceWidth, sourceHeight) >= 1280
    }

    static func flowResolutionCaps(forMaxInterpolatedFrames maxInterp: Int) -> [(Int, Int)] {
        _ = maxInterp
        return [(960, 540), (640, 360)]
    }

    static func buildHybridFlowCandidates(
        sourceWidth: Int,
        sourceHeight: Int,
        maxInterpolatedFrames: Int
    ) -> [(width: Int, height: Int)] {
        let safeW = max(2, sourceWidth)
        let safeH = max(2, sourceHeight)
        let caps = flowResolutionCaps(forMaxInterpolatedFrames: max(1, maxInterpolatedFrames))
        var result: [(width: Int, height: Int)] = []
        for (longCap, shortCap) in caps {
            let fitted = OpticalFlowResolutionPlanner.fitProportionally(
                width: safeW,
                height: safeH,
                maxLongSide: longCap,
                maxShortSide: shortCap
            )
            if !result.contains(where: { $0.width == fitted.width && $0.height == fitted.height }) {
                result.append((width: fitted.width, height: fitted.height))
            }
        }
        return result
    }

    static func resolutionCaps(forMaxInterpolatedFrames maxInterp: Int) -> [(Int, Int)] {
        if maxInterp <= 1 {
            return [(1920, 1080), (1440, 810), (1280, 720)]
        }
        if maxInterp <= 3 {
            return [(1440, 810), (1280, 720)]
        }
        return [(1280, 720)]
    }

    static func shouldForceNormalizeSourceBuffer(hasNormPool: Bool) -> Bool {
        hasNormPool
    }

    static func recommendedFlowQueueCap(targetFPS: Double, maxQueued: Int) -> Int {
        let clampedFPS = max(48.0, min(120.0, targetFPS.isFinite ? targetFPS : 60.0))
        let minSafeFrames = max(24, Int(ceil(clampedFPS * 0.30)))
        return min(max(24, maxQueued), minSafeFrames)
    }

    static func recommendedMetalFlowPacerLagSeconds(
        sourceFPS: Double,
        averageFlowMs: Double
    ) -> Double {
        let clampedFPS = max(12.0, min(120.0, sourceFPS.isFinite ? sourceFPS : 24.0))
        let frameInterval = 1.0 / clampedFPS
        let rawFlowMs = (averageFlowMs.isFinite && averageFlowMs > 0) ? averageFlowMs : 4.0
        let flowSec = max(0.002, min(0.030, rawFlowMs / 1000.0))
        return min(0.115, max(0.075, frameInterval + flowSec + 0.030))
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
    private var metalFlowEngine: MetalPyramidOpticalFlowEngine?
    private var metalFlowFailedForSession: Bool = false
    private var consecutiveLowLatencyErrors: Int = 0
    private var lowLatencyFailedForSession: Bool = false

#if !targetEnvironment(simulator)
    private var processor: VTFrameProcessor?
    private var configuration: VTLowLatencyFrameInterpolationConfiguration?
    private var isHybridFlowWarpActive: Bool = false
    private var flowConfiguration: VTOpticalFlowConfiguration?
    private var flowCandidates: [(width: Int, height: Int)] = []
    private var flowCandidateIndex: Int = 0
    private var flowPlanSignature: String = ""
    private var activeFlowWidth: Int = 0
    private var activeFlowHeight: Int = 0
    private var activeFlowPixelFormat: OSType = kCVPixelFormatType_TwoComponent16Half
    private var flowDestPool: CVPixelBufferPool?
    private var flowWarpNeedsRandomSubmission: Bool = true
    private var flowCalibration = FlowVectorCalibration()
    private var hybridFlowWarpFailedForSession: Bool = false
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
                metalFlowFailedForSession = false
                metalFlowEngine?.reset()
                consecutiveLowLatencyErrors = 0
                lowLatencyFailedForSession = false
#if !targetEnvironment(simulator)
                candidateIndex = 0
                candidates.removeAll(keepingCapacity: true)
                candidatePlanSignature = ""
                flowCandidateIndex = 0
                flowCandidates.removeAll(keepingCapacity: true)
                flowPlanSignature = ""
                hybridFlowWarpFailedForSession = false
                flowWarpNeedsRandomSubmission = true
                flowCalibration = FlowVectorCalibration()
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
                onBatch([RemoteOpticalFlowOutputFrame(pts: currPTS, buffer: currBuffer)], 0, 0, "远程硬解直通")
                return nil
            }

            let srcFmt = CVPixelBufferGetPixelFormatType(currBuffer)
            if !metalFlowFailedForSession,
               RemoteOpticalFlowBudgetPlanner.shouldUseHybridFlowWarp(
                   sourceWidth: srcW,
                   sourceHeight: srcH,
                   targetFPS: targetFPS,
                   isHDR: false,
                   isDolbyVision: false,
                   is8BitSDRPixelFormat: RemoteOpticalFlowBudgetPlanner.is8BitSDRBiPlanarFormat(srcFmt)
               ) {
                let flowEngine: MetalPyramidOpticalFlowEngine
                if let existing = metalFlowEngine {
                    flowEngine = existing
                } else {
                    let created = MetalPyramidOpticalFlowEngine()
                    metalFlowEngine = created
                    flowEngine = created
                }

                let maxSlots = max(1, targetFPS.maxInterpolatedFramesPerPair(sourceFPS: sourceFPS))
                let step = phaseScheduler.planStep(previousPTS: prev.pts, currentPTS: currPTS, maxAllowedSlots: maxSlots)
                let dims = MetalPyramidOpticalFlowEngine.recommendedFlowDimensions(sourceWidth: srcW, sourceHeight: srcH)
                let flowLabelPrefix = max(srcW, srcH) >= 3000 ? "远程·4K原生GPU光流" : "远程·原生GPU光流"
                let emittedLabel = "\(flowLabelPrefix) \(dims.width)×\(dims.height)→\(srcW)×\(srcH)"

                if step.interpolatedSlots.isEmpty {
                    previousFrame = (pts: currPTS, rawBuffer: currBuffer, preparedBuffer: nil, preparedWidth: 0, preparedHeight: 0, preparedFormat: 0)
                    let avg = batchCount > 0 ? totalInterpolationMs / Double(batchCount) : 0
                    onBatch([RemoteOpticalFlowOutputFrame(pts: currPTS, buffer: currBuffer)], 0, avg, emittedLabel)
                    return nil
                }

                if let flowResult = await flowEngine.estimateFlow(prevBuffer: prev.rawBuffer, currBuffer: currBuffer) {
                    guard readGeneration() == jobGeneration else { return nil }
                    totalInterpolationMs += flowResult.elapsedMs
                    batchCount += 1
                    let avgMs = totalInterpolationMs / Double(max(1, batchCount))
                    if batchCount == 1 {
                        onLog?("[remote][gpu] 已激活零降采样 Metal 金字塔光流 (\(flowResult.flowWidth)×\(flowResult.flowHeight)→\(srcW)×\(srcH), 耗时=\(String(format: "%.1f", flowResult.elapsedMs))ms)")
                    }

                    var outFrames: [RemoteOpticalFlowOutputFrame] = []
                    outFrames.reserveCapacity(step.interpolatedSlots.count + 1)
                    for slot in step.interpolatedSlots {
                        outFrames.append(
                            RemoteOpticalFlowOutputFrame(
                                pts: slot.pts,
                                payload: .metalFlowWarped(
                                    prevBuffer: prev.rawBuffer,
                                    currBuffer: currBuffer,
                                    forwardFlow: flowResult.forwardFlow,
                                    backwardFlow: flowResult.backwardFlow,
                                    phase: slot.phase,
                                    isSceneCut: flowResult.isSceneCut
                                )
                            )
                        )
                    }
                    if step.shouldEmitOriginalFrame || outFrames.isEmpty {
                        outFrames.append(RemoteOpticalFlowOutputFrame(pts: currPTS, buffer: currBuffer))
                    }

                    previousFrame = (pts: currPTS, rawBuffer: currBuffer, preparedBuffer: nil, preparedWidth: 0, preparedHeight: 0, preparedFormat: 0)
                    onBatch(outFrames, step.interpolatedSlots.count, avgMs, emittedLabel)

                    if warmupPairsRemaining > 0 {
                        warmupPairsRemaining -= 1
                        return nil
                    }

                    let sourceIntervalMs = 1000.0 / max(12.0, sourceFPS)
                    let canDowngradeFPS = targetFPS.nextLowerTier != nil
                    let catchUpOverload = RemoteOpticalFlowBudgetPlanner.isCatchUpOverload(
                        skippedInputs: skippedInputs,
                        processMs: flowResult.elapsedMs,
                        sourceIntervalMs: sourceIntervalMs
                    )
                    let action = budgetGuard.recordPair(
                        processMs: flowResult.elapsedMs,
                        sourceIntervalMs: sourceIntervalMs,
                        skippedForCatchUp: catchUpOverload,
                        canDowngradeResolution: false,
                        canDowngradeTargetFPS: canDowngradeFPS
                    )
                    if action == .downgradeTargetFPS, let lower = targetFPS.nextLowerTier {
                        updateWorkerTargetTier(lower)
                        phaseScheduler = OpticalFlowPhaseScheduler(targetTier: lower, sourceFPS: sourceFPS)
                        totalInterpolationMs = 0
                        batchCount = 0
                        onTargetDowngrade?(lower, "GPU原生光流持续超预算，自动稳帧至 \(lower.shortBadge)")
                        return lower
                    }
                    return nil
                } else {
                    metalFlowFailedForSession = true
                    onLog?("[remote][warn] Metal金字塔光流初始化或执行不可用，回退硬件光流通道: \(flowEngine.shaderInitError ?? "device unavailable")")
                }
            }
        }

#if targetEnvironment(simulator)
        previousFrame = (pts: currPTS, rawBuffer: currBuffer, preparedBuffer: nil, preparedWidth: 0, preparedHeight: 0, preparedFormat: 0)
        let avg = batchCount > 0 ? totalInterpolationMs / Double(batchCount) : 0
        onBatch([RemoteOpticalFlowOutputFrame(pts: currPTS, buffer: currBuffer)], 0, avg, "远程硬解直通")
        return nil
#else
        if let prev = previousFrame {
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
                            consecutiveLowLatencyErrors = 0
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
                            consecutiveLowLatencyErrors += 1
                            let now = CACurrentMediaTime()
                            if consecutiveLowLatencyErrors >= 2 {
                                let prevLabel = activeCandidate.displayLabel
                                if candidateIndex + 1 < candidates.count {
                                    candidateIndex += 1
                                    let nextLabel = candidates[candidateIndex].displayLabel
                                    consecutiveLowLatencyErrors = 0
                                    onLog?("[remote][warn] 远程光流推理异常 (\(prevLabel))，自动降档切换 -> \(nextLabel): \(error.localizedDescription)")
                                } else {
                                    lowLatencyFailedForSession = true
                                    onLog?("[remote][warn] 远程光流候选耗尽 (\(prevLabel))，已熔断切回原画直通: \(error.localizedDescription)")
                                }
                            } else if now - lastErrorLogTime > 2.0 {
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
    private func ensureHybridFlowWarpSession(
        srcWidth: Int,
        srcHeight: Int,
        targetFPS: OpticalFlowTargetFPS,
        sourceFPS: Double,
        srcPixelFormat: OSType
    ) -> Bool {
        guard !hybridFlowWarpFailedForSession,
              VTOpticalFlowConfiguration.isSupported,
              RemoteOpticalFlowBudgetPlanner.shouldUseHybridFlowWarp(
                  sourceWidth: srcWidth,
                  sourceHeight: srcHeight,
                  targetFPS: targetFPS,
                  isHDR: false,
                  isDolbyVision: false,
                  is8BitSDRPixelFormat: RemoteOpticalFlowBudgetPlanner.is8BitSDRBiPlanarFormat(srcPixelFormat)
              ) else {
            return false
        }

        let maxInterp = max(1, targetFPS.maxInterpolatedFramesPerPair(sourceFPS: sourceFPS))
        let planSig = "flow:\(srcWidth)x\(srcHeight):\(maxInterp)"
        if planSig != flowPlanSignature {
            flowCandidates = RemoteOpticalFlowBudgetPlanner.buildHybridFlowCandidates(
                sourceWidth: srcWidth,
                sourceHeight: srcHeight,
                maxInterpolatedFrames: maxInterp
            )
            flowPlanSignature = planSig
            flowCandidateIndex = 0
        }
        guard flowCandidateIndex < flowCandidates.count else {
            return false
        }

        let sig = "\(planSig):idx\(flowCandidateIndex)"
        if sig == activeSignature, isHybridFlowWarpActive, processor != nil, flowDestPool != nil {
            return true
        }
        teardownSession()

        for index in flowCandidateIndex..<flowCandidates.count {
            let flowDims = flowCandidates[index]
            guard let config = VTOpticalFlowConfiguration(
                frameWidth: flowDims.width,
                frameHeight: flowDims.height,
                qualityPrioritization: .normal,
                revision: VTOpticalFlowConfiguration.defaultRevision
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

            let supportedSourceFormats = Self.extractPixelFormatTypes(from: config.sourcePixelBufferAttributes)
            let chosenSourceFormat: OSType = FlowVectorCalibrator.selectOptimalFlowSourceFormat(from: supportedSourceFormats)
            let supportedSrcDesc = supportedSourceFormats.map { HEVCFormatNormalizer.fourCCString($0) }.joined(separator: ",")

            let supportedFlowFormats = Self.extractPixelFormatTypes(from: config.destinationPixelBufferAttributes)
            let chosenFlowFormat: OSType
            if supportedFlowFormats.contains(kCVPixelFormatType_TwoComponent16Half) {
                chosenFlowFormat = kCVPixelFormatType_TwoComponent16Half
            } else if supportedFlowFormats.contains(kCVPixelFormatType_TwoComponent32Float) {
                chosenFlowFormat = kCVPixelFormatType_TwoComponent32Float
            } else if let first = supportedFlowFormats.first {
                chosenFlowFormat = first
            } else {
                chosenFlowFormat = kCVPixelFormatType_TwoComponent16Half
            }

            let srcPoolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 6]
            var srcNormAttrs: [String: Any] = [:]
            for (k, v) in config.sourcePixelBufferAttributes {
                srcNormAttrs[k] = v
            }
            srcNormAttrs[kCVPixelBufferWidthKey as String] = flowDims.width
            srcNormAttrs[kCVPixelBufferHeightKey as String] = flowDims.height
            srcNormAttrs[kCVPixelBufferPixelFormatTypeKey as String] = NSNumber(value: chosenSourceFormat)
            if srcNormAttrs[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
                srcNormAttrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
            }
            if srcNormAttrs[kCVPixelBufferMetalCompatibilityKey as String] == nil {
                srcNormAttrs[kCVPixelBufferMetalCompatibilityKey as String] = true
            }
            var normPool: CVPixelBufferPool?
            let srcStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault, srcPoolAttrs as CFDictionary, srcNormAttrs as CFDictionary, &normPool)
            guard srcStatus == kCVReturnSuccess, let normPool else {
                proc.endSession()
                continue
            }

            let flowPoolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 16]
            var flowDstAttrs: [String: Any] = [:]
            for (k, v) in config.destinationPixelBufferAttributes {
                flowDstAttrs[k] = v
            }
            flowDstAttrs[kCVPixelBufferWidthKey as String] = flowDims.width
            flowDstAttrs[kCVPixelBufferHeightKey as String] = flowDims.height
            flowDstAttrs[kCVPixelBufferPixelFormatTypeKey as String] = NSNumber(value: chosenFlowFormat)
            if flowDstAttrs[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
                flowDstAttrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
            }
            if flowDstAttrs[kCVPixelBufferMetalCompatibilityKey as String] == nil {
                flowDstAttrs[kCVPixelBufferMetalCompatibilityKey as String] = true
            }
            var flowPool: CVPixelBufferPool?
            let dstStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault, flowPoolAttrs as CFDictionary, flowDstAttrs as CFDictionary, &flowPool)
            guard dstStatus == kCVReturnSuccess, let flowPool else {
                proc.endSession()
                continue
            }

            var xfer: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &xfer)

            self.processor = proc
            self.flowConfiguration = config
            self.isHybridFlowWarpActive = true
            self.flowCandidateIndex = index
            self.activeFlowWidth = flowDims.width
            self.activeFlowHeight = flowDims.height
            self.activePixelFormat = chosenSourceFormat
            self.activeFlowPixelFormat = chosenFlowFormat
            self.sourceNormPool = normPool
            self.sourceTransferSession = xfer
            self.flowDestPool = flowPool
            self.flowWarpNeedsRandomSubmission = true
            self.flowCalibration = FlowVectorCalibration()
            self.activeSignature = "\(planSig):idx\(index)"
            self.warmupPairsRemaining = 8
            onLog?("[remote][ane] 已激活4K原生光流变形会话 v2: FlowWarp \(flowDims.width)×\(flowDims.height) -> \(srcWidth)×\(srcHeight) (flowFmt=\(HEVCFormatNormalizer.fourCCString(chosenFlowFormat)), srcFmt=\(HEVCFormatNormalizer.fourCCString(chosenSourceFormat)), supportedSrc=[\(supportedSrcDesc)])")
            return true
        }
        return false
    }

    private static func extractPixelFormatTypes(from attributes: [String: Any]) -> [OSType] {
        let key = kCVPixelBufferPixelFormatTypeKey as String
        if let list = attributes[key] as? [NSNumber] {
            return list.map(\.uint32Value)
        }
        if let single = attributes[key] as? NSNumber {
            return [single.uint32Value]
        }
        return []
    }

    private func ensureSession(
        srcWidth: Int,
        srcHeight: Int,
        targetFPS: OpticalFlowTargetFPS,
        sourceFPS: Double
    ) -> Bool {
        guard !lowLatencyFailedForSession else {
            return false
        }
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
        _ = targetWidth
        _ = targetHeight
        _ = targetFormat
        // 强制经 VTPixelTransferSession 写入由 VTFrameProcessor 属性池分配的标准 IOSurface 缓冲，
        // 避免同分辨率 1440×810 / 1080p AVPlayerItemVideoOutput 解码缓冲直传触发 -19740 与内存泄漏
        guard RemoteOpticalFlowBudgetPlanner.shouldForceNormalizeSourceBuffer(hasNormPool: sourceNormPool != nil),
              let normPool = sourceNormPool,
              let xfer = sourceTransferSession else {
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
        flowConfiguration = nil
        isHybridFlowWarpActive = false
        activeFlowWidth = 0
        activeFlowHeight = 0
        flowDestPool = nil
        flowWarpNeedsRandomSubmission = true
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
