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
    let proMotionPulseLayer = CALayer()
    @MainActor private var proMotionToggle: Bool = false
    @MainActor private var updateLink: UIUpdateLink?
    @MainActor private var desiredProMotionActive: Bool = false
    @MainActor private var desiredProMotionRange: CAFrameRateRange = .default
    @MainActor var onProMotionTick: (@MainActor () -> Void)?
    @MainActor private(set) var videoTransform: CGAffineTransform = .identity

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.preferredDynamicRange = .high
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        layer.addSublayer(displayLayer)

        // 2×2 活跃视口内微扰层：每 VSync 仅提交一次微幅位姿+透明度变化，避免被 OLED 圆角裁切或同帧双向翻转抵消
        proMotionPulseLayer.frame = CGRect(x: 64, y: 12, width: 2, height: 2)
        proMotionPulseLayer.backgroundColor = UIColor.white.cgColor
        proMotionPulseLayer.opacity = 0
        proMotionPulseLayer.zPosition = 10
        layer.addSublayer(proMotionPulseLayer)

        layoutDisplayLayer()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window?.windowScene != nil {
            updateProMotionLink(isActive: desiredProMotionActive, range: desiredProMotionRange)
        } else {
            updateLink?.isEnabled = false
            updateLink = nil
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        layoutDisplayLayer()
    }

    @MainActor
    private func handleUpdateLinkTick() {
        onProMotionTick?()
    }

    @MainActor
    func updateProMotionLink(isActive: Bool, range: CAFrameRateRange) {
        desiredProMotionActive = isActive
        desiredProMotionRange = range
        if !isActive {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            proMotionPulseLayer.opacity = 0
            CATransaction.commit()
        }
        guard window?.windowScene != nil else {
            updateLink?.isEnabled = false
            return
        }
        if updateLink == nil {
            guard isActive else { return }
            let link = UIUpdateLink(view: self)
            link.addAction { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.handleUpdateLinkTick()
                }
            }
            link.wantsImmediatePresentation = true
            link.requiresContinuousUpdates = true
            self.updateLink = link
        }
        updateLink?.preferredFrameRateRange = range
        updateLink?.isEnabled = isActive
    }

    @MainActor
    func pulseProMotionCommit() {
        proMotionToggle.toggle()
        let safeX = max(64.0, bounds.midX)
        let safeY = max(12.0, safeAreaInsets.top + 4.0)
        let jitterX = proMotionToggle ? 0.5 : 0.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        proMotionPulseLayer.frame = CGRect(x: safeX + jitterX, y: safeY, width: 2, height: 2)
        proMotionPulseLayer.opacity = proMotionToggle ? 0.012 : 0.005
        CATransaction.commit()
    }

    @MainActor
    func setAspectFill(_ aspectFill: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.videoGravity = aspectFill ? .resizeAspectFill : .resizeAspect
        CATransaction.commit()
    }

    @MainActor
    func setEDREnabled(_ enabled: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.preferredDynamicRange = enabled ? .high : .standard
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated static func isQuarterTurnTransform(_ transform: CGAffineTransform) -> Bool {
        abs(transform.b) > abs(transform.a)
    }

    nonisolated static func normalizedRotationTransform(from transform: CGAffineTransform) -> CGAffineTransform {
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

        let safeX = max(64.0, bounds.midX)
        let safeY = max(12.0, safeAreaInsets.top + 4.0)
        let jitterX = proMotionToggle ? 0.5 : 0.0
        proMotionPulseLayer.frame = CGRect(x: safeX + jitterX, y: safeY, width: 2, height: 2)
        proMotionPulseLayer.zPosition = 10
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

/// 用于将解码顺序的 B 帧输出重排为严格单调递增的显示顺序 (PTS)
struct OpticalFlowPTSReorderBuffer<Frame> {
    let maxDepth: Int
    private var entries: [(pts: Double, frame: Frame)] = []

    init(maxDepth: Int = 6) {
        self.maxDepth = max(1, maxDepth)
    }

    var count: Int { entries.count }

    mutating func insert(pts: Double, frame: Frame) {
        let insertionIndex = entries.firstIndex(where: { $0.pts > pts }) ?? entries.endIndex
        entries.insert((pts: pts, frame: frame), at: insertionIndex)
    }

    mutating func popNextIfReady() -> (pts: Double, frame: Frame)? {
        guard entries.count > maxDepth else { return nil }
        return entries.removeFirst()
    }

    mutating func drainAll() -> [(pts: Double, frame: Frame)] {
        let all = entries
        entries.removeAll(keepingCapacity: false)
        return all
    }
}

/// 跨平台送显帧步进调度器：开启光流时每 VSync 至多弹出 1 帧并保留 55ms 容错窗口，防止轻微抖动整批丢帧坍缩至 24fps
enum OpticalFlowFramePacer {
    static func dequeueNextFrame<Frame>(
        from queue: inout [(pts: Double, buffer: Frame)],
        now: Double,
        isInterpolationEnabled: Bool,
        maxLateGraceSeconds: Double = 0.055,
        earlySnapSeconds: Double = 0.006
    ) -> (frame: Frame?, presentedPTS: Double?, droppedCount: Int) {
        guard !queue.isEmpty else {
            return (nil, nil, 0)
        }
        if !isInterpolationEnabled {
            var dropped = 0
            var frameToPresent: Frame?
            var presentedPTS: Double?
            while let head = queue.first, head.pts <= now + earlySnapSeconds {
                if frameToPresent != nil {
                    dropped += 1
                }
                frameToPresent = head.buffer
                presentedPTS = head.pts
                queue.removeFirst()
            }
            return (frameToPresent, presentedPTS, dropped)
        }

        var dropped = 0
        let staleCutoff = now - maxLateGraceSeconds
        while queue.count > 1, queue[0].pts < staleCutoff {
            queue.removeFirst()
            dropped += 1
        }

        if let head = queue.first, head.pts <= now + earlySnapSeconds {
            queue.removeFirst()
            return (head.buffer, head.pts, dropped)
        }
        return (nil, nil, dropped)
    }
}

struct OpticalFlowSendableFrame: @unchecked Sendable {
    let pts: CMTime
    let buffer: CVPixelBuffer
}

/// 有界异步解码管道：将硬件解码 (VDEC) 与 ANE 光流推理彻底并行流水线化
final class OpticalFlowDecodedFramePipe: @unchecked Sendable {
    enum ReceiveResult: @unchecked Sendable {
        case frame(OpticalFlowSendableFrame)
        case finished(Error?)
    }

    let capacity: Int
    private let lock = NSLock()
    private var queue: [OpticalFlowSendableFrame] = []
    private var isClosed: Bool = false
    private var terminalError: Error?
    private var waitingProducer: CheckedContinuation<Bool, Never>?
    private var waitingConsumer: CheckedContinuation<ReceiveResult, Never>?

    init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    func send(_ frame: OpticalFlowSendableFrame) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enum Action {
                    case resumeNow(Bool)
                    case resumeConsumer(CheckedContinuation<ReceiveResult, Never>, OpticalFlowSendableFrame)
                    case wait
                }
                let action: Action
                lock.lock()
                if isClosed || Task.isCancelled {
                    action = .resumeNow(false)
                } else if let consumer = waitingConsumer {
                    waitingConsumer = nil
                    action = .resumeConsumer(consumer, frame)
                } else {
                    queue.append(frame)
                    if queue.count <= capacity {
                        action = .resumeNow(true)
                    } else {
                        waitingProducer = continuation
                        action = .wait
                    }
                }
                lock.unlock()

                switch action {
                case .resumeNow(let ok):
                    continuation.resume(returning: ok)
                case .resumeConsumer(let consumer, let item):
                    consumer.resume(returning: .frame(item))
                    continuation.resume(returning: true)
                case .wait:
                    break
                }
            }
        } onCancel: {
            discardAllAndClose()
        }
    }

    func receive() async -> ReceiveResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enum Action {
                    case resumeFrame(OpticalFlowSendableFrame, CheckedContinuation<Bool, Never>?, Bool)
                    case resumeFinished(Error?)
                    case wait
                }
                let action: Action
                lock.lock()
                if Task.isCancelled {
                    action = .resumeFinished(nil)
                } else if !queue.isEmpty {
                    let next = queue.removeFirst()
                    var producerToResume: CheckedContinuation<Bool, Never>?
                    var producerResult = false
                    if let producer = waitingProducer {
                        if !isClosed && queue.count <= capacity {
                            waitingProducer = nil
                            producerToResume = producer
                            producerResult = true
                        } else if isClosed && queue.isEmpty {
                            waitingProducer = nil
                            producerToResume = producer
                            producerResult = false
                        }
                    }
                    action = .resumeFrame(next, producerToResume, producerResult)
                } else if isClosed {
                    action = .resumeFinished(terminalError)
                } else {
                    waitingConsumer = continuation
                    action = .wait
                }
                lock.unlock()

                switch action {
                case .resumeFrame(let item, let producer, let ok):
                    producer?.resume(returning: ok)
                    continuation.resume(returning: .frame(item))
                case .resumeFinished(let err):
                    continuation.resume(returning: .finished(err))
                case .wait:
                    break
                }
            }
        } onCancel: {
            discardAllAndClose()
        }
    }

    func finishProducer(error: Error? = nil) {
        lock.lock()
        isClosed = true
        if terminalError == nil {
            terminalError = error
        }
        let producer = waitingProducer
        waitingProducer = nil
        var consumer: CheckedContinuation<ReceiveResult, Never>?
        var errForConsumer: Error?
        if queue.isEmpty {
            consumer = waitingConsumer
            waitingConsumer = nil
            errForConsumer = terminalError
        }
        lock.unlock()

        producer?.resume(returning: false)
        consumer?.resume(returning: .finished(errForConsumer))
    }

    func discardAllAndClose() {
        lock.lock()
        isClosed = true
        queue.removeAll(keepingCapacity: false)
        let producer = waitingProducer
        waitingProducer = nil
        let consumer = waitingConsumer
        waitingConsumer = nil
        let err = terminalError
        lock.unlock()

        producer?.resume(returning: false)
        consumer?.resume(returning: .finished(err))
    }
}

/// 将 hev1 / avc3 等非苹果默认描述重写为 VideoToolbox 可直接硬解的 hvc1 / avc1 FormatDescription
enum HEVCFormatNormalizer {
    private static let safeColorExtensionKeys: [String] = [
        kCMFormatDescriptionExtension_ColorPrimaries as String,
        kCMFormatDescriptionExtension_TransferFunction as String,
        kCMFormatDescriptionExtension_YCbCrMatrix as String,
        kCMFormatDescriptionExtension_FullRangeVideo as String,
        kCMFormatDescriptionExtension_PixelAspectRatio as String,
        kCMFormatDescriptionExtension_CleanAperture as String,
        kCMFormatDescriptionExtension_BitsPerComponent as String,
        kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String,
        kCMFormatDescriptionExtension_ContentLightLevelInfo as String,
        kCMFormatDescriptionExtension_AmbientViewingEnvironment as String,
        kCMFormatDescriptionExtension_ChromaLocationTopField as String,
        kCMFormatDescriptionExtension_ChromaLocationBottomField as String
    ]

    static func isDolbyVision(subType: FourCharCode, atoms: [String: Any]?) -> Bool {
        let dvCodecs: Set<FourCharCode> = [
            fourCCCode("dvh1"),
            fourCCCode("dvhe"),
            fourCCCode("dva1"),
            fourCCCode("dvav"),
            fourCCCode("dav1")
        ]
        if dvCodecs.contains(subType) {
            return true
        }
        guard let atoms else { return false }
        return atoms["dvcC"] != nil || atoms["dvvC"] != nil || atoms["dvwC"] != nil
    }

    static func fourCCCode(_ string: String) -> FourCharCode {
        let bytes = Array(string.utf8.prefix(4))
        var result: FourCharCode = 0
        for index in 0..<4 {
            let b: UInt8 = index < bytes.count ? bytes[index] : 0x20
            result = (result << 8) | FourCharCode(b)
        }
        return result
    }

    static func fourCCString(_ code: FourCharCode) -> String {
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

    static func describeFormat(_ desc: CMFormatDescription) -> String {
        let subType = CMFormatDescriptionGetMediaSubType(desc)
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let exts = CMFormatDescriptionGetExtensions(desc) as? [String: Any]
        let atoms = exts?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any]
        let atomKeys = atoms.map { Array($0.keys).sorted().joined(separator: ",") } ?? "none"
        let hvccLen = (atoms?["hvcC"] as? Data)?.count ?? 0
        let transfer = exts?[kCMFormatDescriptionExtension_TransferFunction as String] as? String ?? "none"
        let isDV = isDolbyVision(subType: subType, atoms: atoms)
        return "fourCC=\(fourCCString(subType)), dims=\(dims.width)x\(dims.height), dv=\(isDV), transfer=\(transfer), atoms=[\(atomKeys)], hvcC=\(hvccLen)B"
    }

    static func parseHEVCParameterSets(fromHVCC data: Data) -> (nalLengthSize: Int32, parameterSets: [Data])? {
        let bytes = [UInt8](data)
        guard bytes.count >= 23 else { return nil }
        let nalLengthSize = Int32((bytes[21] & 0x03) + 1)
        guard nalLengthSize == 1 || nalLengthSize == 2 || nalLengthSize == 4 else { return nil }
        let numArrays = Int(bytes[22])
        var offset = 23
        var parameterSets: [Data] = []

        for _ in 0..<numArrays {
            guard offset + 3 <= bytes.count else { return nil }
            let arrayNalType = bytes[offset] & 0x3F
            offset += 1
            let numNalus = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2
            for _ in 0..<numNalus {
                guard offset + 2 <= bytes.count else { return nil }
                let naluLength = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
                offset += 2
                guard naluLength > 0, naluLength <= bytes.count - offset else { return nil }
                let nalu = Array(bytes[offset..<(offset + naluLength)])
                offset += naluLength
                let naluType = (nalu[0] >> 1) & 0x3F
                if (32...34).contains(naluType) || (32...34).contains(arrayNalType) {
                    parameterSets.append(Data(nalu))
                }
            }
        }

        guard !parameterSets.isEmpty else { return nil }
        return (nalLengthSize: nalLengthSize, parameterSets: parameterSets)
    }

    static func extractHEVCParameterSets(fromLengthPrefixed data: Data, nalLengthSize: Int = 4) -> [Data] {
        guard nalLengthSize == 1 || nalLengthSize == 2 || nalLengthSize == 4 else { return [] }
        let bytes = [UInt8](data)
        var offset = 0
        var seen = Set<Data>()
        var result: [Data] = []

        while offset + nalLengthSize <= bytes.count {
            var length = 0
            for index in 0..<nalLengthSize {
                length = (length << 8) | Int(bytes[offset + index])
            }
            offset += nalLengthSize
            guard length > 0, length <= bytes.count - offset else { break }
            let naluSlice = bytes[offset..<(offset + length)]
            let nalType = (naluSlice[naluSlice.startIndex] >> 1) & 0x3F
            if nalType == 32 || nalType == 33 || nalType == 34 {
                let naluData = Data(naluSlice)
                if seen.insert(naluData).inserted {
                    result.append(naluData)
                }
            }
            offset += length
        }
        return result
    }

    static func copyLeadingData(from sample: CMSampleBuffer, maxBytes: Int = 512 * 1024) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        let copyLength = min(totalLength, maxBytes)
        guard copyLength > 0 else { return nil }

        var data = Data(count: copyLength)
        let status = data.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else {
                return OSStatus(-12701)
            }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: copyLength,
                destination: baseAddress
            )
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }

    static func makeNormalizedFormatDescriptionCandidates(
        from rawDesc: CMVideoFormatDescription,
        fallbackSampleData: Data? = nil
    ) -> [(strategy: String, description: CMVideoFormatDescription)] {
        var candidates: [(strategy: String, description: CMVideoFormatDescription)] = []
        let subType = CMFormatDescriptionGetMediaSubType(rawDesc)
        let dims = CMVideoFormatDescriptionGetDimensions(rawDesc)
        let rawExtensions = CMFormatDescriptionGetExtensions(rawDesc) as? [String: Any]
        let atoms = rawExtensions?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any]

        var safeColorExtensions: [String: Any] = [:]
        if let rawExtensions {
            for key in safeColorExtensionKeys {
                if let value = rawExtensions[key] {
                    safeColorExtensions[key] = value
                }
            }
        }

        let isDV = isDolbyVision(subType: subType, atoms: atoms)
        let isHEVCBase = (subType == fourCCCode("hev1")
            || subType == fourCCCode("hvc1")
            || subType == fourCCCode("dvh1")
            || subType == fourCCCode("dvhe")
            || atoms?["hvcC"] != nil)

        var dvCandidates: [(strategy: String, description: CMVideoFormatDescription)] = []
        if isDV && isHEVCBase, let atoms {
            var dvAtoms: [String: Any] = [:]
            for key in ["hvcC", "dvcC", "dvvC", "dvwC", "hvcE", "lhvC"] {
                if let val = atoms[key] {
                    dvAtoms[key] = val
                }
            }
            if !dvAtoms.isEmpty {
                var dvExt = safeColorExtensions
                dvExt[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = dvAtoms
                var dvh1Desc: CMVideoFormatDescription?
                let dvStatus = CMVideoFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    codecType: fourCCCode("dvh1"),
                    width: dims.width,
                    height: dims.height,
                    extensions: dvExt as CFDictionary,
                    formatDescriptionOut: &dvh1Desc
                )
                if dvStatus == noErr, let dvh1Desc {
                    if subType == fourCCCode("dvh1") {
                        dvCandidates.append((strategy: "dvh1-clean", description: dvh1Desc))
                    } else {
                        dvCandidates.append((strategy: "dvhe-to-dvh1", description: dvh1Desc))
                    }
                }
            }
        }

        var hevcFallbackCandidates: [(strategy: String, description: CMVideoFormatDescription)] = []
        var parsedHVCC: (nalLengthSize: Int32, parameterSets: [Data])?
        if let hvcCData = atoms?["hvcC"] as? Data, !hvcCData.isEmpty {
            parsedHVCC = parseHEVCParameterSets(fromHVCC: hvcCData)

            var cleanExt = safeColorExtensions
            cleanExt[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = ["hvcC": hvcCData]
            var hvc1Desc: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_HEVC,
                width: dims.width,
                height: dims.height,
                extensions: cleanExt as CFDictionary,
                formatDescriptionOut: &hvc1Desc
            )
            if status == noErr, let hvc1Desc {
                hevcFallbackCandidates.append((strategy: "hvcC-to-hvc1", description: hvc1Desc))
            }

            if let parsed = parsedHVCC,
               let paramDesc = createHEVCDescription(
                   parameterSets: parsed.parameterSets,
                   nalLengthSize: parsed.nalLengthSize,
                   extensions: safeColorExtensions
               ) {
                hevcFallbackCandidates.append((strategy: "hvcc-param-sets", description: paramDesc))
            }
        }

        if isHEVCBase, let sampleData = fallbackSampleData, !sampleData.isEmpty {
            let nalLen = Int(parsedHVCC?.nalLengthSize ?? 4)
            let inbandSets = extractHEVCParameterSets(fromLengthPrefixed: sampleData, nalLengthSize: nalLen)
            if inbandSets.count >= 2,
               let inbandDesc = createHEVCDescription(
                   parameterSets: inbandSets,
                   nalLengthSize: Int32(nalLen),
                   extensions: safeColorExtensions
               ) {
                hevcFallbackCandidates.append((strategy: "inband-param-sets", description: inbandDesc))
            }
        }

        if isDV && isHEVCBase {
            if subType == fourCCCode("dvh1") {
                candidates.append((strategy: "passthrough", description: rawDesc))
                candidates.append(contentsOf: dvCandidates)
            } else {
                candidates.append(contentsOf: dvCandidates)
                candidates.append((strategy: "passthrough", description: rawDesc))
            }
            candidates.append(contentsOf: hevcFallbackCandidates)
            return candidates
        }

        candidates.append(contentsOf: hevcFallbackCandidates)

        if subType == fourCCCode("av01") || subType == fourCCCode("dav1") {
            candidates.append((strategy: "passthrough", description: rawDesc))
            return candidates
        }

        if subType == fourCCCode("avc3"),
           let avcCData = atoms?["avcC"] as? Data,
           !avcCData.isEmpty {
            var cleanExt = safeColorExtensions
            cleanExt[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = ["avcC": avcCData]
            var avc1Desc: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_H264,
                width: dims.width,
                height: dims.height,
                extensions: cleanExt as CFDictionary,
                formatDescriptionOut: &avc1Desc
            )
            if status == noErr, let avc1Desc {
                candidates.append((strategy: "avcC-to-avc1", description: avc1Desc))
            }
        }

        candidates.append((strategy: "passthrough", description: rawDesc))
        return candidates
    }

    static func rewriteSampleBuffer(
        _ sample: CMSampleBuffer,
        with formatDescription: CMFormatDescription
    ) -> CMSampleBuffer? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let sampleCount = CMSampleBufferGetNumSamples(sample)
        guard sampleCount >= 1 else { return nil }

        var timingCount: CMItemCount = 0
        let timingQueryStatus = CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount
        )
        var timingArray: [CMSampleTimingInfo]
        if timingQueryStatus == noErr && timingCount > 0 {
            timingArray = [CMSampleTimingInfo](
                repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid),
                count: Int(timingCount)
            )
            let fillStatus = timingArray.withUnsafeMutableBufferPointer { buf in
                CMSampleBufferGetSampleTimingInfoArray(
                    sample,
                    entryCount: timingCount,
                    arrayToFill: buf.baseAddress,
                    entriesNeededOut: &timingCount
                )
            }
            if fillStatus != noErr {
                timingArray = [
                    CMSampleTimingInfo(
                        duration: CMSampleBufferGetDuration(sample),
                        presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
                        decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sample)
                    )
                ]
            }
        } else {
            timingArray = [
                CMSampleTimingInfo(
                    duration: CMSampleBufferGetDuration(sample),
                    presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
                    decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sample)
                )
            ]
        }

        var sizeCount: CMItemCount = 0
        let sizeQueryStatus = CMSampleBufferGetSampleSizeArray(
            sample,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &sizeCount
        )
        var sizeArray: [Int] = []
        if sizeQueryStatus == noErr && sizeCount > 0 {
            var filledSizes = [Int](repeating: 0, count: Int(sizeCount))
            let fillSizeStatus = filledSizes.withUnsafeMutableBufferPointer { buf in
                CMSampleBufferGetSampleSizeArray(
                    sample,
                    entryCount: sizeCount,
                    arrayToFill: buf.baseAddress,
                    entriesNeededOut: &sizeCount
                )
            }
            if fillSizeStatus == noErr {
                sizeArray = filledSizes
            }
        } else if sampleCount == 1 {
            let singleSize = CMSampleBufferGetSampleSize(sample, at: 0)
            if singleSize > 0 {
                sizeArray = [singleSize]
            } else {
                let blockLen = CMBlockBufferGetDataLength(dataBuffer)
                if blockLen > 0 {
                    sizeArray = [blockLen]
                }
            }
        }

        return timingArray.withUnsafeBufferPointer { timingPtr in
            if sizeArray.isEmpty {
                var outSample: CMSampleBuffer?
                let status = CMSampleBufferCreateReady(
                    allocator: kCFAllocatorDefault,
                    dataBuffer: dataBuffer,
                    formatDescription: formatDescription,
                    sampleCount: sampleCount,
                    sampleTimingEntryCount: timingArray.count,
                    sampleTimingArray: timingPtr.baseAddress,
                    sampleSizeEntryCount: 0,
                    sampleSizeArray: nil,
                    sampleBufferOut: &outSample
                )
                return status == noErr ? outSample : nil
            } else {
                return sizeArray.withUnsafeBufferPointer { sizePtr in
                    var outSample: CMSampleBuffer?
                    let status = CMSampleBufferCreateReady(
                        allocator: kCFAllocatorDefault,
                        dataBuffer: dataBuffer,
                        formatDescription: formatDescription,
                        sampleCount: sampleCount,
                        sampleTimingEntryCount: timingArray.count,
                        sampleTimingArray: timingPtr.baseAddress,
                        sampleSizeEntryCount: sizeArray.count,
                        sampleSizeArray: sizePtr.baseAddress,
                        sampleBufferOut: &outSample
                    )
                    return status == noErr ? outSample : nil
                }
            }
        }
    }

    private static func createHEVCDescription(
        parameterSets: [Data],
        nalLengthSize: Int32,
        extensions: [String: Any]
    ) -> CMVideoFormatDescription? {
        let nonEmptySets = parameterSets.filter { !$0.isEmpty }
        let totalBytes = nonEmptySets.reduce(0) { $0 + $1.count }
        guard !nonEmptySets.isEmpty, totalBytes > 0 else { return nil }

        let flatBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: totalBytes)
        defer { flatBuffer.deallocate() }

        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        pointers.reserveCapacity(nonEmptySets.count)
        sizes.reserveCapacity(nonEmptySets.count)

        var offset = 0
        for ps in nonEmptySets {
            ps.withUnsafeBytes { rawBuffer in
                guard let src = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                flatBuffer.advanced(by: offset).initialize(from: src, count: ps.count)
            }
            pointers.append(UnsafePointer(flatBuffer.advanced(by: offset)))
            sizes.append(ps.count)
            offset += ps.count
        }

        func invokeCreate(withExtensions extDict: CFDictionary?) -> CMVideoFormatDescription? {
            var outDesc: CMVideoFormatDescription?
            let status = pointers.withUnsafeBufferPointer { ptrBuf in
                sizes.withUnsafeBufferPointer { sizeBuf in
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointers.count,
                        parameterSetPointers: ptrBuf.baseAddress!,
                        parameterSetSizes: sizeBuf.baseAddress!,
                        nalUnitHeaderLength: nalLengthSize,
                        extensions: extDict,
                        formatDescriptionOut: &outDesc
                    )
                }
            }
            return status == noErr ? outDesc : nil
        }

        if !extensions.isEmpty, let withExt = invokeCreate(withExtensions: extensions as CFDictionary) {
            return withExt
        }
        return invokeCreate(withExtensions: nil)
    }
}

/// VideoToolbox 光流后端类型
enum OpticalFlowBackendKind: String, Hashable, Sendable {
    case lowLatency = "LowLatency"
    case frameRateConversion = "FRC"
}

/// 单个分辨率 + 后端 + 插帧数上限组合候选
struct OpticalFlowCandidate: Hashable, Sendable {
    let backend: OpticalFlowBackendKind
    let width: Int
    let height: Int
    let spatial2x: Bool
    let maxInterpolatedFrames: Int

    init(
        backend: OpticalFlowBackendKind,
        width: Int,
        height: Int,
        spatial2x: Bool,
        maxInterpolatedFrames: Int = 1
    ) {
        self.backend = backend
        self.width = width
        self.height = height
        self.spatial2x = spatial2x
        self.maxInterpolatedFrames = max(1, maxInterpolatedFrames)
    }

    var displayLabel: String {
        let base = spatial2x
            ? "\(backend.rawValue) \(width)×\(height)+2×"
            : "\(backend.rawValue) \(width)×\(height)"
        if maxInterpolatedFrames > 1 {
            return "\(base) [×\(maxInterpolatedFrames + 1)]"
        }
        return base
    }
}

/// 跨平台分辨率自适应与双后端候选规划器（自动将 4K 降档至 1080p/720p/540p 等比偶对齐档位）
enum OpticalFlowResolutionPlanner: Sendable {
    struct DimensionBounds: Equatable, Sendable {
        let minWidth: Int
        let minHeight: Int
        let maxWidth: Int
        let maxHeight: Int
    }

    static func alignEven(_ value: Int, minimum: Int = 64) -> Int {
        let clamped = max(minimum, value)
        return clamped - (clamped % 2)
    }

    static func fitProportionally(
        width: Int,
        height: Int,
        maxLongSide: Int,
        maxShortSide: Int
    ) -> (width: Int, height: Int) {
        let safeW = max(2, width)
        let safeH = max(2, height)
        let capW = safeW >= safeH ? maxLongSide : maxShortSide
        let capH = safeW >= safeH ? maxShortSide : maxLongSide
        let scale = min(1.0, min(Double(capW) / Double(safeW), Double(capH) / Double(safeH)))
        let scaledW = alignEven(Int(floor(Double(safeW) * scale)))
        let scaledH = alignEven(Int(floor(Double(safeH) * scale)))
        return (scaledW, scaledH)
    }

    static func clampToBounds(
        width: Int,
        height: Int,
        bounds: DimensionBounds?
    ) -> (width: Int, height: Int)? {
        var w = alignEven(width)
        var h = alignEven(height)
        guard let bounds else {
            return (w, h)
        }
        if bounds.maxWidth > 0 && bounds.maxHeight > 0 {
            if w > bounds.maxWidth || h > bounds.maxHeight {
                let scale = min(Double(bounds.maxWidth) / Double(w), Double(bounds.maxHeight) / Double(h))
                w = alignEven(Int(floor(Double(w) * scale)))
                h = alignEven(Int(floor(Double(h) * scale)))
            }
        }
        if bounds.minWidth > 0 && w < bounds.minWidth {
            return nil
        }
        if bounds.minHeight > 0 && h < bounds.minHeight {
            return nil
        }
        return (w, h)
    }

    static func lowLatencyExponent(forInterpolatedFrames count: Int) -> Int {
        if count <= 1 {
            return 1
        }
        if count <= 3 {
            return 2
        }
        return 3
    }

    static func isHeavyPixelFormat(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_64RGBAHalf || format == kCVPixelFormatType_128RGBAFloat
    }

    static func selectOptimalPixelFormat(from supported: [OSType], prefer10Bit: Bool) -> OSType {
        let fallbackDefault = prefer10Bit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard !supported.isEmpty else { return fallbackDefault }

        let yuv10: [OSType] = [
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        ]
        let yuv8: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        let lossless10: [OSType] = [
            HEVCFormatNormalizer.fourCCCode("&xv0"),
            HEVCFormatNormalizer.fourCCCode("&xf0")
        ]
        let lossless8: [OSType] = [
            HEVCFormatNormalizer.fourCCCode("&8v0"),
            HEVCFormatNormalizer.fourCCCode("&8f0")
        ]
        let rgb32: [OSType] = [
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_32RGBA,
            kCVPixelFormatType_32ARGB,
            HEVCFormatNormalizer.fourCCCode("&BGA")
        ]

        var preferredOrder: [OSType] = []
        if prefer10Bit {
            preferredOrder.append(contentsOf: yuv10)
            preferredOrder.append(contentsOf: yuv8)
            preferredOrder.append(contentsOf: lossless10)
            preferredOrder.append(contentsOf: lossless8)
        } else {
            preferredOrder.append(contentsOf: yuv8)
            preferredOrder.append(contentsOf: yuv10)
            preferredOrder.append(contentsOf: lossless8)
            preferredOrder.append(contentsOf: lossless10)
        }
        preferredOrder.append(contentsOf: rgb32)

        for candidate in preferredOrder where supported.contains(candidate) {
            return candidate
        }
        if let nonHeavy = supported.first(where: { !isHeavyPixelFormat($0) }) {
            return nonHeavy
        }
        if supported.contains(kCVPixelFormatType_64RGBAHalf) {
            return kCVPixelFormatType_64RGBAHalf
        }
        return supported.first ?? fallbackDefault
    }

    static func nativeDecodePixelFormats(prefer10Bit: Bool, preferredPixelFormat: OSType) -> [OSType] {
        let baseOrder: [OSType] = prefer10Bit ? [
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA
        ] : [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            kCVPixelFormatType_32BGRA
        ]

        var result: [OSType] = []
        if !isHeavyPixelFormat(preferredPixelFormat), baseOrder.contains(preferredPixelFormat) {
            result.append(preferredPixelFormat)
        }
        for fmt in baseOrder where !result.contains(fmt) {
            result.append(fmt)
        }
        return result
    }

    static func recommendedQueueLimits(targetFPS: Double, isHeavyPixelFormat: Bool = false) -> (maxQueued: Int, prebuffer: Int) {
        let clampedFPS = max(24.0, min(120.0, targetFPS.isFinite ? targetFPS : 48.0))
        var maxQueued = max(24, min(72, Int((clampedFPS * 0.5).rounded())))
        var prebuffer = max(6, min(18, Int((clampedFPS * 0.15).rounded())))
        if isHeavyPixelFormat {
            maxQueued = min(30, max(16, maxQueued))
            prebuffer = min(10, max(4, prebuffer))
        }
        return (maxQueued: maxQueued, prebuffer: prebuffer)
    }

    static func recommendedDisplayFrameRateRange(
        targetFPS: Double,
        isInterpolationEnabled: Bool = true,
        maxScreenFPS: Int = 120,
        isLowPowerMode: Bool = false
    ) -> (minimum: Float, maximum: Float, preferred: Float) {
        let safeFPS = (targetFPS.isFinite && targetFPS > 1.0) ? targetFPS : 48.0
        if isInterpolationEnabled {
            if maxScreenFPS >= 120 {
                if safeFPS >= 47.0 && safeFPS <= 48.5 {
                    return (48, 48, 48)
                }
                if isLowPowerMode || safeFPS <= 60.5 {
                    return (60, 60, 60)
                }
                return (80, 120, 120)
            }
            return (60, 60, 60)
        }
        if safeFPS <= 60.0 {
            return (24, 60, Float(max(24.0, min(60.0, safeFPS.rounded()))))
        }
        if maxScreenFPS >= 120 && !isLowPowerMode {
            return (60, 120, 120)
        }
        return (60, 60, 60)
    }

    static func recommendedDecodeDimensions(
        sourceWidth: Int,
        sourceHeight: Int,
        forOpticalFlow: Bool
    ) -> (width: Int, height: Int)? {
        guard forOpticalFlow, sourceWidth >= 2, sourceHeight >= 2 else { return nil }
        if max(sourceWidth, sourceHeight) <= 1920 && min(sourceWidth, sourceHeight) <= 1080 {
            return nil
        }
        return fitProportionally(
            width: sourceWidth,
            height: sourceHeight,
            maxLongSide: 1920,
            maxShortSide: 1080
        )
    }

    static func thermalMaxTargetTier(for state: ProcessInfo.ThermalState) -> OpticalFlowTargetFPS? {
        switch state {
        case .nominal, .fair:
            return nil
        case .serious:
            return .fps60
        case .critical:
            return .x2
        @unknown default:
            return nil
        }
    }

    static func targetTierRank(_ tier: OpticalFlowTargetFPS) -> Int {
        switch tier {
        case .x2: return 0
        case .fps60: return 1
        case .fps96: return 2
        case .fps120: return 3
        }
    }

    static func exceedsThermalCap(
        active: OpticalFlowTargetFPS,
        thermalState: ProcessInfo.ThermalState
    ) -> OpticalFlowTargetFPS? {
        guard let cap = thermalMaxTargetTier(for: thermalState) else { return nil }
        return targetTierRank(active) > targetTierRank(cap) ? cap : nil
    }

    static func effectivePowerThermalCap(
        active: OpticalFlowTargetFPS,
        thermalState: ProcessInfo.ThermalState,
        isLowPowerMode: Bool
    ) -> (tier: OpticalFlowTargetFPS, reason: String)? {
        if thermalState == .critical, targetTierRank(active) > targetTierRank(.x2) {
            return (.x2, "严重过热")
        }
        if isLowPowerMode, targetTierRank(active) > targetTierRank(.fps60) {
            return (.fps60, "低电量60Hz上限")
        }
        if thermalState == .serious, targetTierRank(active) > targetTierRank(.fps60) {
            return (.fps60, "过热保护")
        }
        return nil
    }

    static func buildCandidatePlan(
        sourceWidth: Int,
        sourceHeight: Int,
        requestedSpatial2x: Bool,
        lowLatencySupported: Bool,
        frcSupported: Bool,
        lowLatencyBounds: DimensionBounds? = nil,
        frcBounds: DimensionBounds? = nil,
        preferFRC: Bool = false,
        maxInterpolatedFrames: Int = 1
    ) -> [OpticalFlowCandidate] {
        guard lowLatencySupported || frcSupported else { return [] }
        let safeW = max(2, sourceWidth)
        let safeH = max(2, sourceHeight)
        let safeMaxInterp = max(1, maxInterpolatedFrames)

        let caps: [(Int, Int)]
        if safeMaxInterp >= 2 {
            // 2 相及以上（60/72/96/120fps）：统一从 720p 起跑并支持降至 540p/480p，避免 1080p 超预算
            caps = [
                (1280, 720),
                (960, 540),
                (854, 480)
            ]
        } else {
            caps = [
                (1920, 1080),
                (1280, 720),
                (960, 540)
            ]
        }
        var tiers: [(width: Int, height: Int)] = []
        for (longCap, shortCap) in caps {
            let fitted = fitProportionally(
                width: safeW,
                height: safeH,
                maxLongSide: longCap,
                maxShortSide: shortCap
            )
            if !tiers.contains(where: { $0.width == fitted.width && $0.height == fitted.height }) {
                tiers.append(fitted)
            }
        }

        var plan: [OpticalFlowCandidate] = []
        func appendCandidate(_ candidate: OpticalFlowCandidate) {
            if !plan.contains(candidate) {
                plan.append(candidate)
            }
        }

        let allowSpatial2x = requestedSpatial2x
            && !preferFRC
            && safeMaxInterp == 1
            && lowLatencySupported
            && !SuperResolutionPolicy.isAlready4K(width: safeW, height: safeH)

        if allowSpatial2x,
           let topTier = tiers.first,
           let bounded = clampToBounds(width: topTier.width, height: topTier.height, bounds: lowLatencyBounds) {
            appendCandidate(
                OpticalFlowCandidate(
                    backend: .lowLatency,
                    width: bounded.width,
                    height: bounded.height,
                    spatial2x: true,
                    maxInterpolatedFrames: 1
                )
            )
        }

        if preferFRC {
            for tier in tiers {
                if frcSupported,
                   let bounded = clampToBounds(width: tier.width, height: tier.height, bounds: frcBounds) {
                    appendCandidate(
                        OpticalFlowCandidate(
                            backend: .frameRateConversion,
                            width: bounded.width,
                            height: bounded.height,
                            spatial2x: false,
                            maxInterpolatedFrames: safeMaxInterp
                        )
                    )
                }
            }
            for tier in tiers {
                if lowLatencySupported,
                   let bounded = clampToBounds(width: tier.width, height: tier.height, bounds: lowLatencyBounds) {
                    appendCandidate(
                        OpticalFlowCandidate(
                            backend: .lowLatency,
                            width: bounded.width,
                            height: bounded.height,
                            spatial2x: false,
                            maxInterpolatedFrames: safeMaxInterp
                        )
                    )
                }
            }
        } else {
            for tier in tiers {
                if lowLatencySupported,
                   let bounded = clampToBounds(width: tier.width, height: tier.height, bounds: lowLatencyBounds) {
                    appendCandidate(
                        OpticalFlowCandidate(
                            backend: .lowLatency,
                            width: bounded.width,
                            height: bounded.height,
                            spatial2x: false,
                            maxInterpolatedFrames: safeMaxInterp
                        )
                    )
                }
            }
            for tier in tiers {
                if frcSupported,
                   let bounded = clampToBounds(width: tier.width, height: tier.height, bounds: frcBounds) {
                    appendCandidate(
                        OpticalFlowCandidate(
                            backend: .frameRateConversion,
                            width: bounded.width,
                            height: bounded.height,
                            spatial2x: false,
                            maxInterpolatedFrames: safeMaxInterp
                        )
                    )
                }
            }
        }

        return plan
    }
}

/// 单个插帧槽位的归一化相位与对应显示时间戳
struct OpticalFlowPhaseSlot: Equatable, Sendable {
    let phase: Float
    let pts: Double
}

/// 相位调度器针对一对源帧输出的插帧槽位与当前源帧是否送显指令
struct OpticalFlowPhaseStep: Equatable, Sendable {
    let interpolatedSlots: [OpticalFlowPhaseSlot]
    let shouldEmitOriginalFrame: Bool
}

/// 跨平台光流多档位相位调度器（支持整倍等分与非整倍时间栅格重采样，如 24→60/72/96/120）
struct OpticalFlowPhaseScheduler: Sendable {
    let targetTier: OpticalFlowTargetFPS
    let sourceFPS: Double
    let effectiveTargetFPS: Double
    private let exactIntegerMultiplier: Int?
    private var nextGridPTS: Double?

    init(targetTier: OpticalFlowTargetFPS, sourceFPS: Double) {
        let safeSrc = (sourceFPS.isFinite && sourceFPS > 1.0) ? sourceFPS : 24.0
        self.targetTier = targetTier
        self.sourceFPS = safeSrc
        let resolvedTarget = targetTier.effectiveTargetFPS(sourceFPS: safeSrc)
        self.effectiveTargetFPS = resolvedTarget

        if targetTier == .x2 {
            self.exactIntegerMultiplier = 2
        } else {
            let ratio = resolvedTarget / safeSrc
            if ratio <= 1.05 {
                self.exactIntegerMultiplier = 1
            } else {
                let rounded = Int(ratio.rounded())
                if rounded >= 2 && abs(ratio - Double(rounded)) <= 0.03 {
                    self.exactIntegerMultiplier = min(9, rounded)
                } else {
                    self.exactIntegerMultiplier = nil
                }
            }
        }
    }

    mutating func reset() {
        nextGridPTS = nil
    }

    mutating func planStep(
        previousPTS: Double,
        currentPTS: Double,
        maxAllowedSlots: Int = 8
    ) -> OpticalFlowPhaseStep {
        let dt = currentPTS - previousPTS
        guard dt.isFinite, dt > 0 else {
            return OpticalFlowPhaseStep(interpolatedSlots: [], shouldEmitOriginalFrame: true)
        }
        let maxSlots = max(1, maxAllowedSlots)

        if let mult = exactIntegerMultiplier {
            if mult <= 1 {
                return OpticalFlowPhaseStep(interpolatedSlots: [], shouldEmitOriginalFrame: true)
            }
            let count = min(maxSlots, mult - 1)
            var slots: [OpticalFlowPhaseSlot] = []
            slots.reserveCapacity(count)
            for k in 1...count {
                let phase = Float(k) / Float(count + 1)
                let pts = previousPTS + Double(phase) * dt
                slots.append(OpticalFlowPhaseSlot(phase: phase, pts: pts))
            }
            return OpticalFlowPhaseStep(interpolatedSlots: slots, shouldEmitOriginalFrame: true)
        }

        let targetStep = 1.0 / max(effectiveTargetFPS, 1.0)
        let snapEpsilon = min(targetStep * 0.08, dt * 0.04)

        if let existing = nextGridPTS {
            if existing < previousPTS - targetStep * 0.5 || existing > currentPTS + dt {
                nextGridPTS = previousPTS + targetStep
            }
        } else {
            nextGridPTS = previousPTS + targetStep
        }

        var slots: [OpticalFlowPhaseSlot] = []
        var shouldEmitOriginal = false

        while let t = nextGridPTS, t <= currentPTS + snapEpsilon {
            nextGridPTS = t + targetStep
            if abs(t - previousPTS) <= snapEpsilon {
                continue
            }
            if abs(t - currentPTS) <= snapEpsilon {
                shouldEmitOriginal = true
                continue
            }
            var rawPhase = Float((t - previousPTS) / dt)
            rawPhase = min(max(rawPhase, 0.01), 0.99)
            if let lastPhase = slots.last?.phase, rawPhase <= lastPhase {
                rawPhase = min(0.995, lastPhase + 0.001)
            }
            if rawPhase < 0.995, slots.count < maxSlots {
                slots.append(OpticalFlowPhaseSlot(phase: rawPhase, pts: t))
            }
        }

        return OpticalFlowPhaseStep(
            interpolatedSlots: slots,
            shouldEmitOriginalFrame: shouldEmitOriginal
        )
    }
}

/// 跨平台光流算力预算守卫：持续超预算或追帧跳过时执行「先降分辨率，再降目标帧率档位」
struct OpticalFlowBudgetGuard: Sendable {
    enum Action: Equatable, Sendable {
        case keep
        case downgradeResolution
        case downgradeTargetFPS
    }

    let windowSize: Int
    let overloadRatioThreshold: Double
    let consecutiveOverloadWindowsRequired: Int
    let maxConsecutiveCatchUpSkips: Int
    let cooldownPairs: Int

    private var windowRatios: [Double] = []
    private var consecutiveOverloadWindows: Int = 0
    private var consecutiveSkips: Int = 0
    private var cooldownRemaining: Int = 0

    init(
        windowSize: Int = 12,
        overloadRatioThreshold: Double = 0.88,
        consecutiveOverloadWindowsRequired: Int = 2,
        maxConsecutiveCatchUpSkips: Int = 4,
        cooldownPairs: Int = 24
    ) {
        self.windowSize = max(1, windowSize)
        self.overloadRatioThreshold = overloadRatioThreshold
        self.consecutiveOverloadWindowsRequired = max(1, consecutiveOverloadWindowsRequired)
        self.maxConsecutiveCatchUpSkips = max(1, maxConsecutiveCatchUpSkips)
        self.cooldownPairs = max(0, cooldownPairs)
    }

    mutating func reset() {
        windowRatios.removeAll(keepingCapacity: true)
        consecutiveOverloadWindows = 0
        consecutiveSkips = 0
        cooldownRemaining = 0
    }

    mutating func recordPair(
        processMs: Double,
        sourceIntervalMs: Double,
        skippedForCatchUp: Bool,
        canDowngradeResolution: Bool,
        canDowngradeTargetFPS: Bool
    ) -> Action {
        if cooldownRemaining > 0 {
            cooldownRemaining -= 1
            return .keep
        }

        if skippedForCatchUp {
            consecutiveSkips += 1
            if consecutiveSkips >= maxConsecutiveCatchUpSkips {
                return triggerDowngrade(
                    canDowngradeResolution: canDowngradeResolution,
                    canDowngradeTargetFPS: canDowngradeTargetFPS
                )
            }
            return .keep
        }

        consecutiveSkips = 0
        let safeInterval = max(sourceIntervalMs, 4.0)
        let ratio = max(0, processMs) / safeInterval
        windowRatios.append(ratio)

        if windowRatios.count >= windowSize {
            let avgRatio = windowRatios.reduce(0, +) / Double(windowRatios.count)
            windowRatios.removeAll(keepingCapacity: true)
            if avgRatio > overloadRatioThreshold {
                consecutiveOverloadWindows += 1
                if consecutiveOverloadWindows >= consecutiveOverloadWindowsRequired {
                    return triggerDowngrade(
                        canDowngradeResolution: canDowngradeResolution,
                        canDowngradeTargetFPS: canDowngradeTargetFPS
                    )
                }
            } else {
                consecutiveOverloadWindows = 0
            }
        }

        return .keep
    }

    private mutating func triggerDowngrade(
        canDowngradeResolution: Bool,
        canDowngradeTargetFPS: Bool
    ) -> Action {
        windowRatios.removeAll(keepingCapacity: true)
        consecutiveOverloadWindows = 0
        consecutiveSkips = 0
        cooldownRemaining = cooldownPairs

        if canDowngradeResolution {
            return .downgradeResolution
        }
        if canDowngradeTargetFPS {
            return .downgradeTargetFPS
        }
        return .keep
    }
}

private final class VTDecodedFrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(pts: CMTime, buffer: CVPixelBuffer)] = []
    private var lastStatus: OSStatus = noErr

    func record(status: OSStatus, infoFlags: VTDecodeInfoFlags, imageBuffer: CVImageBuffer?, pts: CMTime) {
        lock.lock()
        if status != noErr {
            lastStatus = status
        } else if !infoFlags.contains(.frameDropped), let buffer = imageBuffer {
            frames.append((pts: pts, buffer: buffer))
        }
        lock.unlock()
    }

    func drain() -> (frames: [(pts: CMTime, buffer: CVPixelBuffer)], lastStatus: OSStatus) {
        lock.lock()
        let outFrames = frames
        let status = lastStatus
        frames.removeAll(keepingCapacity: true)
        lastStatus = noErr
        lock.unlock()
        return (outFrames, status)
    }
}

private final class VTDecompressionSessionHolder: @unchecked Sendable {
    private(set) var session: VTDecompressionSession?
    let formatDescription: CMVideoFormatDescription
    let strategy: String
    let isHardwareScaled: Bool
    let collector = VTDecodedFrameCollector()

    init(
        session: VTDecompressionSession,
        formatDescription: CMVideoFormatDescription,
        strategy: String,
        isHardwareScaled: Bool = false
    ) {
        self.session = session
        self.formatDescription = formatDescription
        self.strategy = strategy
        self.isHardwareScaled = isHardwareScaled
    }

    func decode(sampleBuffer: CMSampleBuffer) -> (decodeStatus: OSStatus, drained: (frames: [(pts: CMTime, buffer: CVPixelBuffer)], lastStatus: OSStatus)) {
        guard let session else {
            return (kVTInvalidSessionErr, ([], kVTInvalidSessionErr))
        }
        guard let rewritten = HEVCFormatNormalizer.rewriteSampleBuffer(sampleBuffer, with: formatDescription) else {
            let errStatus: OSStatus = -12902
            return (errStatus, ([], errStatus))
        }
        let localCollector = collector
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: rewritten,
            flags: [],
            infoFlagsOut: nil
        ) { status, infoFlags, imageBuffer, pts, _ in
            localCollector.record(status: status, infoFlags: infoFlags, imageBuffer: imageBuffer, pts: pts)
        }
        let drained = collector.drain()
        return (decodeStatus, drained)
    }

    func waitForAsyncFrames() -> (frames: [(pts: CMTime, buffer: CVPixelBuffer)], lastStatus: OSStatus) {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        return collector.drain()
    }

    func invalidate() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
    }

    deinit {
        invalidate()
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
    @Published @MainActor var activeBackendLabel: String = "--"
    @Published @MainActor var videoTransform: CGAffineTransform = .identity
    @Published @MainActor var requestedTargetFPS: OpticalFlowTargetFPS = .x2
    @Published @MainActor var effectiveTargetFPS: OpticalFlowTargetFPS = .x2
    @Published @MainActor var latestAVDeltaMs: Double? = nil
    @Published @MainActor var isInterpolationEnabled: Bool = true
    @Published @MainActor var isAspectFill: Bool = false
    @Published @MainActor var isEDREnabled: Bool = true
    @Published @MainActor var isDolbyVisionContent: Bool = false
    @Published @MainActor var isHDRContent: Bool = false
    @Published @MainActor var videoEnhancementPreset: VideoEnhancementPreset = .off
    @Published @MainActor var videoEnhancementStrength: VideoEnhancementStrength = .standard
    @Published @MainActor var isComparingOriginalQuality: Bool = false
    @Published @MainActor var activeQualityPipelineLabel: String = "关闭"
    @Published @MainActor var averageQualityEnhanceMs: Double = 0
    @MainActor private var rawHDRTransferName: String? = nil
    @MainActor private var metalEnhancerStorage: MetalVideoEnhancer? = nil

    @MainActor
    private var metalEnhancer: MetalVideoEnhancer {
        if let existing = metalEnhancerStorage {
            return existing
        }
        let created = MetalVideoEnhancer()
        metalEnhancerStorage = created
        return created
    }

    @MainActor
    var targetSummaryBadge: String {
        effectiveTargetFPS == requestedTargetFPS
            ? effectiveTargetFPS.shortBadge
            : "\(requestedTargetFPS.shortBadge)→\(effectiveTargetFPS.shortBadge)"
    }

    @MainActor var isLoopingEnabled: Bool = true

    @MainActor
    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    @MainActor
    var capabilityDescription: String {
#if targetEnvironment(simulator)
        return "Simulator (硬件光流仅真机可用)"
#else
        let lowLatencySupported = VTLowLatencyFrameInterpolationConfiguration.isSupported
        let frcSupported = VTFrameRateConversionConfiguration.isSupported
        switch (lowLatencySupported, frcSupported) {
        case (true, true):
            return "真机支持 ANE 光流 (LowLatency+FRC)"
        case (true, false):
            return "真机支持 ANE 光流 (LowLatency)"
        case (false, true):
            return "真机支持 ANE 光流 (FRC)"
        case (false, false):
            return "当前设备不支持 ANE 光流"
        }
#endif
    }

    private struct TrackColorFallbackMetadata {
        var isHDR: Bool = false
        var isDolbyVision: Bool = false
        var colorPrimaries: CFString?
        var transferFunction: CFString?
        var ycbcrMatrix: CFString?
        var masteringDisplayColorVolume: CFData?
        var contentLightLevelInfo: CFData?
        var ambientViewingEnvironment: CFData?
    }

    private let bufferLock = NSLock()
    private let tokenLock = NSLock()
    private let audioClockLock = NSLock()
    private let passthroughCacheLock = NSLock()
    private var passthroughRequiredURLKeys: Set<String> = []
    private var colorFallbackMetadata = TrackColorFallbackMetadata()
    private var pendingUserSwitch: (target: OpticalFlowTargetFPS, spatial2x: Bool)?
    private var didInspectFirstDecodedColor: Bool = false
    private var frameQueue: [(pts: Double, buffer: CVPixelBuffer)] = []
    private var pendingFirstFrame: (pts: Double, buffer: CVPixelBuffer)?
    private var didAttachDisplayLayer: Bool = false
    private var isReaderEOF: Bool = false
    private var lastEnqueuedPTS: Double = 0
    private var maxQueuedFrames = 24
    private var prebufferFrameTarget = 6

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
    @MainActor private var lastDisplayTickHostTime: CFTimeInterval = 0
    private final class PlaybackActivityTokenHolder: @unchecked Sendable {
        var token: (any NSObjectProtocol)?
    }
    private let playbackActivityHolder = PlaybackActivityTokenHolder()

    @MainActor
    func attach(to container: SampleBufferDisplayContainerView) {
        self.displayContainer = container
        container.onProMotionTick = { [weak self] in
            self?.onDisplayTick()
        }
        container.applyVideoTransform(videoTransform)
        container.setAspectFill(isAspectFill)
        container.setEDREnabled(isEDREnabled)
        attach(to: container.displayLayer)
        syncDisplayLinkState()
    }

    @MainActor
    func setAspectFill(_ enabled: Bool) {
        isAspectFill = enabled
        displayContainer?.setAspectFill(enabled)
    }

    @MainActor
    func setEDREnabled(_ enabled: Bool) {
        isEDREnabled = enabled
        displayContainer?.setEDREnabled(enabled)
        isHDRActive = isHDRContent && enabled
        hdrLabel = PlaybackHUDMetrics.formatHDRTag(
            isHDRContent: isHDRContent,
            transferName: rawHDRTransferName,
            isHDRActive: isHDRActive,
            isDolbyVision: isDolbyVisionContent
        )
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
    func clearError() {
        errorMessage = nil
    }

    @MainActor
    func recordExternalError(_ message: String) {
        errorMessage = message
        appendLog("[error] \(message)")
    }

    @MainActor
    func load(
        url: URL,
        spatial2x: Bool,
        targetFPS: OpticalFlowTargetFPS = .x2,
        startAt: Double = 0,
        autoPlay: Bool = true,
        enableInterpolation: Bool = true
    ) {
        stopInternal()
        currentURL = url
        isInterpolationEnabled = enableInterpolation
        requestedTargetFPS = targetFPS
        effectiveTargetFPS = targetFPS
        let allowedSpatial = enableInterpolation && spatial2x && targetFPS.allowsSpatial2x
        enableSpatial2xUpscale = allowedSpatial
        errorMessage = nil
        interpolatedFrameCount = 0
        failedInterpolationCount = 0
        presentedFrameCount = 0
        skippedInterpolationCount = 0
        averageInterpolationMs = 0
        latestAVDeltaMs = nil
        activeBackendLabel = enableInterpolation ? "--" : "原帧率直通"
        lastInterpolationError = nil
        isLoadingPipeline = true
        pipelineStatusText = enableInterpolation ? "正在初始化 ANE 光流核..." : "正在初始化原生硬解直通..."
        updateLatestAudioTime(max(0, startAt))
        appendLog("[ane] 请求加载: \(url.lastPathComponent) (补帧=\(enableInterpolation), 目标=\(targetFPS.shortBadge), 请求空间2×=\(spatial2x), startAt=\(String(format: "%.2f", startAt))s, autoPlay=\(autoPlay))")
        if enableInterpolation && spatial2x && !targetFPS.allowsSpatial2x {
            appendLog("[ane] 目标档位 \(targetFPS.shortBadge) 需多相补帧，已自动禁用 ANE 2× 空间超分")
        }

        if enableInterpolation {
#if targetEnvironment(simulator)
            isHardwareSupported = false
            isLoadingPipeline = false
            pipelineStatusText = ""
            appendLog("[ane] Simulator 环境不支持 VideoToolbox ANE 硬件光流")
            errorMessage = "iOS 模拟器不支持 VideoToolbox ANE 硬件光流，可点击「以原帧率直通重试」观看。"
            return
#else
            let supported = VTLowLatencyFrameInterpolationConfiguration.isSupported
                || VTFrameRateConversionConfiguration.isSupported
            isHardwareSupported = supported
            guard supported else {
                isLoadingPipeline = false
                pipelineStatusText = ""
                appendLog("[ane] 当前设备不支持 VTLowLatencyFrameInterpolation 或 VTFrameRateConversion")
                errorMessage = "当前设备不支持 VideoToolbox ANE 光流，可点击「以原帧率直通重试」观看。"
                return
            }
#endif
        }

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        self.isPaused = !autoPlay

        let link = CADisplayLink(target: self, selector: #selector(onDisplayTick))
        let initialTargetRate = enableInterpolation
            ? targetFPS.effectiveTargetFPS(sourceFPS: 24.0)
            : 24.0
        let maxScreenFPS = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.maximumFramesPerSecond ?? 120
        let initialRange = OpticalFlowResolutionPlanner.recommendedDisplayFrameRateRange(
            targetFPS: initialTargetRate,
            isInterpolationEnabled: enableInterpolation,
            maxScreenFPS: maxScreenFPS,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        let initialCARange = CAFrameRateRange(
            minimum: initialRange.minimum,
            maximum: initialRange.maximum,
            preferred: initialRange.preferred
        )
        link.preferredFrameRateRange = initialCARange
        link.isPaused = !autoPlay
        link.add(to: .main, forMode: .common)
        self.displayLink = link
        displayContainer?.updateProMotionLink(
            isActive: autoPlay && enableInterpolation,
            range: initialCARange
        )

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
                guard let videoTrack = await Self.selectPrimaryVideoTrack(from: tracks) else {
                    self.isPaused = true
                    self.isLoadingPipeline = false
                    self.pipelineStatusText = ""
                    self.appendLog("[ane] 未发现视频轨道（仅支持 MP4/MOV/M4V/TS 等系统原生容器）")
                    self.errorMessage = "原生硬解引擎未能在该文件中找到可解码的视频轨道。"
                    return
                }

                let preferredTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
                let nominalRate = try await videoTrack.load(.nominalFrameRate)
                let naturalSize = try await videoTrack.load(.naturalSize)
                let formatDescriptions = (try? await videoTrack.load(.formatDescriptions)) ?? []
                guard self.isTokenValid(token) else { return }
                if let firstDesc = formatDescriptions.first {
                    self.appendLog("[ane] 轨道格式: \(HEVCFormatNormalizer.describeFormat(firstDesc))")
                }

                self.videoTransform = preferredTransform
                self.displayContainer?.applyVideoTransform(preferredTransform)
                self.displayContainer?.setAspectFill(self.isAspectFill)
                self.displayContainer?.setEDREnabled(self.isEDREnabled)

                let trackMetrics = Self.extractTrackMetrics(from: formatDescriptions.first, naturalSize: naturalSize)
                self.setColorFallbackMetadata(from: formatDescriptions.first, trackMetrics: trackMetrics)
                let displayDims = Self.displayDimensions(naturalSize: naturalSize, transform: preferredTransform)
                let is4K = SuperResolutionPolicy.isAlready4K(width: displayDims.width, height: displayDims.height)
                let effectiveSpatial2x = allowedSpatial && !is4K
                if allowedSpatial && is4K {
                    self.appendLog("[ane] 片源已达 4K（\(displayDims.width)×\(displayDims.height)），自动禁用 ANE 2× 空间超分，仅保留光流补帧")
                }

                let srcFps = nominalRate > 0 ? Double(nominalRate) : 24.0
                let resolvedTargetFPS = enableInterpolation
                    ? targetFPS.effectiveTargetFPS(sourceFPS: srcFps)
                    : srcFps
                self.sourceFPS = srcFps
                self.interpolatedFPS = resolvedTargetFPS
                self.videoWidth = displayDims.width
                self.videoHeight = displayDims.height
                self.videoCodec = trackMetrics.codec
                self.bitDepthLabel = trackMetrics.bitDepth
                self.isHDRContent = trackMetrics.isHDR
                self.isDolbyVisionContent = trackMetrics.isDolbyVision
                self.rawHDRTransferName = trackMetrics.transferName
                self.isHDRActive = trackMetrics.isHDR && self.isEDREnabled
                self.hdrLabel = PlaybackHUDMetrics.formatHDRTag(
                    isHDRContent: trackMetrics.isHDR,
                    transferName: trackMetrics.transferName,
                    isHDRActive: self.isHDRActive,
                    isDolbyVision: trackMetrics.isDolbyVision
                )
                self.enableSpatial2xUpscale = effectiveSpatial2x
                if enableInterpolation {
                    let queueLimits = OpticalFlowResolutionPlanner.recommendedQueueLimits(targetFPS: resolvedTargetFPS)
                    self.updateQueueLimits(maxQueued: queueLimits.maxQueued, prebuffer: queueLimits.prebuffer)
                } else {
                    self.activeBackendLabel = "原帧率直通"
                    self.updateQueueLimits(maxQueued: 24, prebuffer: 6)
                }
                self.syncDisplayLinkState()

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
                    let item: AVPlayerItem
                    if let sourceAudio = await Self.selectPlayableAudioTrack(from: audioTracks) {
                        do {
                            let audioComposition = AVMutableComposition()
                            guard let compTrack = audioComposition.addMutableTrack(
                                withMediaType: .audio,
                                preferredTrackID: kCMPersistentTrackID_Invalid
                            ) else {
                                throw NSError(domain: "GlassMPV.OpticalFlow", code: -101, userInfo: [
                                    NSLocalizedDescriptionKey: "无法创建纯音频合成轨道"
                                ])
                            }
                            let loadedRange = (try? await sourceAudio.load(.timeRange)) ?? CMTimeRange(start: .zero, duration: assetDuration)
                            let validRange: CMTimeRange
                            if loadedRange.duration.isValid && loadedRange.duration.seconds > 0 {
                                validRange = loadedRange
                            } else {
                                validRange = CMTimeRange(start: .zero, duration: assetDuration)
                            }
                            try compTrack.insertTimeRange(validRange, of: sourceAudio, at: .zero)
                            item = AVPlayerItem(asset: audioComposition)
                            self.appendLog("[ane] 已构建纯音轨 AVMutableComposition，避免音频播放器抢占硬解会话")
                        } catch {
                            self.appendLog("[ane][warn] 纯音轨合成失败，回退 URL 并禁用视频轨: \(Self.formatDetailedError(error))")
                            let fallbackItem = AVPlayerItem(url: url)
                            for pTrack in fallbackItem.tracks where pTrack.assetTrack?.mediaType == .video {
                                pTrack.isEnabled = false
                            }
                            item = fallbackItem
                        }
                    } else {
                        let fallbackItem = AVPlayerItem(url: url)
                        for pTrack in fallbackItem.tracks where pTrack.assetTrack?.mediaType == .video {
                            pTrack.isEnabled = false
                        }
                        item = fallbackItem
                    }
                    guard self.isTokenValid(token) else { return }
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

                let prefer10Bit = Self.shouldPrefer10Bit(from: trackMetrics)
                if enableInterpolation {
                    self.pipelineStatusText = "正在预热 ANE 光流缓冲..."
                    self.startPipeline(
                        url: url,
                        width: Int(abs(naturalSize.width)),
                        height: Int(abs(naturalSize.height)),
                        sourceFPS: srcFps,
                        startSeconds: clampedStart,
                        spatial2x: effectiveSpatial2x,
                        targetFPS: targetFPS,
                        prefer10Bit: prefer10Bit,
                        token: token
                    )
                } else {
                    self.pipelineStatusText = "正在预热原生硬解直通..."
                    self.startPassthroughPipeline(
                        url: url,
                        sourceFPS: srcFps,
                        startSeconds: clampedStart,
                        prefer10Bit: prefer10Bit,
                        token: token
                    )
                }
            } catch {
                self.isPaused = true
                self.isLoadingPipeline = false
                self.pipelineStatusText = ""
                let detailed = Self.formatDetailedError(error)
                self.appendLog("[ane][error] 加载轨道信息失败: \(detailed)")
                self.errorMessage = "媒体轨道加载失败（\(detailed)）"
            }
        }
    }

    @MainActor
    func togglePlayPause() {
        if usesSyntheticClock {
            if isPaused {
                isPaused = false
                syncDisplayLinkState()
                startActiveClockIfNeeded()
            } else {
                syntheticClock.pause()
                currentTime = syntheticClock.currentTime()
                isPaused = true
                syncDisplayLinkState()
            }
            return
        }

        guard audioPlayer != nil else { return }
        if isPaused {
            isPaused = false
            syncDisplayLinkState()
            startActiveClockIfNeeded()
        } else {
            audioPlayer?.pause()
            isPaused = true
            syncDisplayLinkState()
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
        syncDisplayLinkState()
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
        let interpEnabled = self.isInterpolationEnabled
        let targetFPS = self.requestedTargetFPS
        let spatial2x = interpEnabled && self.enableSpatial2xUpscale && targetFPS.allowsSpatial2x
        let knownSourceFPS = self.sourceFPS
        self.effectiveTargetFPS = targetFPS

        Task { @MainActor [weak self] in
            guard let self, self.isTokenValid(token) else { return }
            let asset = AVURLAsset(url: url)
            guard let tracks = try? await asset.loadTracks(withMediaType: .video),
                  let videoTrack = await Self.selectPrimaryVideoTrack(from: tracks) else { return }
            let nominalRate = (try? await videoTrack.load(.nominalFrameRate)) ?? 0
            let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
            let formatDescriptions = (try? await videoTrack.load(.formatDescriptions)) ?? []
            let trackMetrics = Self.extractTrackMetrics(from: formatDescriptions.first, naturalSize: naturalSize)
            let prefer10Bit = Self.shouldPrefer10Bit(from: trackMetrics)
            let resolvedSourceFPS = nominalRate > 0 ? Double(nominalRate) : (knownSourceFPS > 1.0 ? knownSourceFPS : 24.0)
            let resolvedTargetFPS = interpEnabled ? targetFPS.effectiveTargetFPS(sourceFPS: resolvedSourceFPS) : resolvedSourceFPS
            self.sourceFPS = resolvedSourceFPS
            self.interpolatedFPS = resolvedTargetFPS
            if interpEnabled {
                let queueLimits = OpticalFlowResolutionPlanner.recommendedQueueLimits(targetFPS: resolvedTargetFPS)
                self.updateQueueLimits(maxQueued: queueLimits.maxQueued, prebuffer: queueLimits.prebuffer)
            } else {
                self.activeBackendLabel = "原帧率直通"
                self.updateQueueLimits(maxQueued: 24, prebuffer: 6)
            }
            self.syncDisplayLinkState()
            guard self.isTokenValid(token) else { return }
            if interpEnabled {
                self.startPipeline(
                    url: url,
                    width: Int(abs(naturalSize.width)),
                    height: Int(abs(naturalSize.height)),
                    sourceFPS: resolvedSourceFPS,
                    startSeconds: clamped,
                    spatial2x: spatial2x,
                    targetFPS: targetFPS,
                    prefer10Bit: prefer10Bit,
                    token: token
                )
            } else {
                self.startPassthroughPipeline(
                    url: url,
                    sourceFPS: resolvedSourceFPS,
                    startSeconds: clamped,
                    prefer10Bit: prefer10Bit,
                    token: token
                )
            }
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
        let hadActiveSession = (
            currentURL != nil
            || displayLink != nil
            || audioPlayer != nil
            || isLoadingPipeline
            || isPipelineReadyToPlay
            || !isPaused
        )
        currentURL = nil
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
        activeBackendLabel = "--"
        effectiveTargetFPS = requestedTargetFPS
        updateQueueLimits(maxQueued: 24, prebuffer: 6)
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
        isHDRContent = false
        isDolbyVisionContent = false
        rawHDRTransferName = nil
        isHDRActive = false
        clearColorFallbackMetadata()
        droppedFrames = 0
        interpolatedFrameCount = 0
        failedInterpolationCount = 0
        presentedFrameCount = 0
        skippedInterpolationCount = 0
        averageInterpolationMs = 0
        latestAVDeltaMs = nil
        lastInterpolationError = nil
        isLoadingPipeline = false
        pipelineStatusText = ""
        isPipelineReadyToPlay = false
        isPaused = true
        lastDisplayTickHostTime = 0
        displayContainer?.updateProMotionLink(isActive: false, range: .default)
        updatePlaybackActivity(isActive: false)
        metalEnhancerStorage?.reset()
        isComparingOriginalQuality = false
        activeQualityPipelineLabel = "关闭"
        averageQualityEnhanceMs = 0
        UIApplication.shared.isIdleTimerDisabled = false
        if hadActiveSession {
            appendLog("[ane] 光流核已停止")
        }
    }

    @MainActor
    private func updatePlaybackActivity(isActive: Bool) {
        if isActive {
            if playbackActivityHolder.token == nil {
                playbackActivityHolder.token = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled],
                    reason: "GlassMPV Real-Time ANE Optical Flow"
                )
            }
        } else if let token = playbackActivityHolder.token {
            ProcessInfo.processInfo.endActivity(token)
            playbackActivityHolder.token = nil
        }
    }

    @MainActor
    private func startActiveClockIfNeeded() {
        syncDisplayLinkState()
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
    func syncDisplayLinkState() {
        let shouldBoostPlayback = (!isPaused && currentURL != nil && isInterpolationEnabled)
        UIApplication.shared.isIdleTimerDisabled = (!isPaused && currentURL != nil)
        updatePlaybackActivity(isActive: shouldBoostPlayback)
        let targetRate: Double
        if !isInterpolationEnabled {
            targetRate = sourceFPS > 1.0 ? sourceFPS : 24.0
        } else if interpolatedFPS > 0 {
            targetRate = interpolatedFPS
        } else {
            targetRate = effectiveTargetFPS.effectiveTargetFPS(sourceFPS: sourceFPS)
        }
        let maxScreenFPS = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.maximumFramesPerSecond ?? 120
        let range = OpticalFlowResolutionPlanner.recommendedDisplayFrameRateRange(
            targetFPS: targetRate,
            isInterpolationEnabled: isInterpolationEnabled,
            maxScreenFPS: maxScreenFPS,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        let caRange = CAFrameRateRange(
            minimum: range.minimum,
            maximum: range.maximum,
            preferred: range.preferred
        )
        if let displayLink {
            displayLink.isPaused = isPaused
            displayLink.preferredFrameRateRange = caRange
        }
        displayContainer?.updateProMotionLink(
            isActive: shouldBoostPlayback,
            range: caRange
        )
    }

    @MainActor
    func appendLog(_ line: String) {
        let stamp = Self.logTimeFormatter.string(from: Date())
        diagnosticLogs.append("[\(stamp)] \(line)")
        if diagnosticLogs.count > 500 {
            diagnosticLogs.removeFirst(diagnosticLogs.count - 500)
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
        pendingUserSwitch = nil
        didInspectFirstDecodedColor = false
        isReaderEOF = false
        lastEnqueuedPTS = 0
        bufferLock.unlock()
    }

    private struct SendablePixelBuffer: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    private func startPassthroughPipeline(
        url: URL,
        sourceFPS: Double,
        startSeconds: Double,
        prefer10Bit: Bool,
        token: UUID
    ) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runPassthroughTask(
                url: url,
                sourceFPS: sourceFPS,
                startSeconds: startSeconds,
                prefer10Bit: prefer10Bit,
                token: token
            )
        }
    }

    private func runPassthroughTask(
        url: URL,
        sourceFPS: Double,
        startSeconds: Double,
        prefer10Bit: Bool,
        token: UUID
    ) async {
        do {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = await Self.selectPrimaryVideoTrack(from: tracks) else {
                Task { @MainActor [weak self] in
                    self?.isLoadingPipeline = false
                    self?.pipelineStatusText = ""
                    self?.errorMessage = "未找到视频轨道。"
                }
                return
            }
            let trackFormatDescriptions = (try? await videoTrack.load(.formatDescriptions)) ?? []
            let fallbackTrackDesc = trackFormatDescriptions.first
            let preferredPixFmt: OSType = prefer10Bit
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

            var didStartAudioClock = false
            var didCachePendingFirstFrame = false

            func emitPassthroughFrame(_ buffer: CVPixelBuffer, ptsSeconds: Double) {
                inspectDecodedBufferColorOnceIfNeeded(buffer, token: token)
                if !didCachePendingFirstFrame {
                    didCachePendingFirstFrame = true
                    cachePendingFirstFrame(buffer, ptsSeconds: ptsSeconds)
                    let previewBox = SendablePixelBuffer(buffer: buffer)
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.isTokenValid(token),
                              self.isPaused,
                              self.presentedFrameCount == 0,
                              let layer = self.displayLayer else { return }
                        self.presentFrame(previewBox.buffer, ptsSeconds: ptsSeconds, on: layer)
                    }
                }
                enqueueDecodedFrame(pts: ptsSeconds, buffer: buffer)
                if !didStartAudioClock && queuedCount() >= readPrebufferFrameTarget() {
                    didStartAudioClock = true
                    Task { @MainActor [weak self] in
                        guard let self, self.isTokenValid(token) else { return }
                        self.isPipelineReadyToPlay = true
                        self.pipelineStatusText = ""
                        self.startActiveClockIfNeeded()
                    }
                }
            }

            var primaryError: Error?
            var openedReader: (reader: AVAssetReader, output: AVAssetReaderTrackOutput, tierLabel: String, pixelFormat: OSType)?
            let forcedPassthrough = isPassthroughForced(for: url)
            if forcedPassthrough {
                logAsync("[pass] 命中片源透传缓存，跳过常规 AVAssetReader 直走压缩透传硬解")
            } else {
                do {
                    openedReader = try openAssetReaderWithFallback(
                        asset: asset,
                        videoTrack: videoTrack,
                        startSeconds: startSeconds,
                        preferredPixelFormat: preferredPixFmt,
                        prefer10Bit: prefer10Bit
                    )
                } catch {
                    primaryError = error
                    markPassthroughRequired(for: url)
                }
            }

            var activeReader: AVAssetReader?
            var decodedAnyPrimaryFrame = false

            if let openedReader {
                let reader = openedReader.reader
                let trackOutput = openedReader.output
                activeReader = reader

                while reader.status == .reading {
                    if !isTokenValid(token) {
                        reader.cancelReading()
                        return
                    }
                    while queuedCount() >= readMaxQueuedFrames() && !hasPendingUserSwitch() {
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
                    decodedAnyPrimaryFrame = true
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    if pts.isValid, pts.seconds.isFinite {
                        emitPassthroughFrame(currentBuffer, ptsSeconds: pts.seconds)
                    }
                }

                if !decodedAnyPrimaryFrame && reader.status == .failed && isTokenValid(token) {
                    primaryError = reader.error ?? primaryError
                    markPassthroughRequired(for: url)
                }
            }

            let shouldUsePassthroughFallback = forcedPassthrough
                || (openedReader == nil)
                || (!decodedAnyPrimaryFrame && activeReader?.status == .failed && isTokenValid(token))

            if shouldUsePassthroughFallback {
                if !forcedPassthrough {
                    let reasonText = Self.formatDetailedError(primaryError)
                    logAsync("[pass][warn] 常规 AVAssetReader 失败，切换压缩透传 + VTDecompressionSession 硬解直通: \(reasonText)")
                }

                let passthrough = try openCompressedPassthroughReader(
                    asset: asset,
                    videoTrack: videoTrack,
                    startSeconds: startSeconds
                )
                let passthroughReader = passthrough.reader
                let passthroughOutput = passthrough.output
                activeReader = passthroughReader

                var holder: VTDecompressionSessionHolder?
                defer { holder?.invalidate() }
                var reorderBuffer = OpticalFlowPTSReorderBuffer<CVPixelBuffer>(maxDepth: 6)

                while passthroughReader.status == .reading {
                    if !isTokenValid(token) {
                        passthroughReader.cancelReading()
                        return
                    }
                    while queuedCount() >= readMaxQueuedFrames() && !hasPendingUserSwitch() {
                        if !isTokenValid(token) {
                            passthroughReader.cancelReading()
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(8))
                    }
                    guard let sample = passthroughOutput.copyNextSampleBuffer() else {
                        break
                    }
                    guard CMSampleBufferGetDataBuffer(sample) != nil else {
                        continue
                    }

                    if holder == nil {
                        guard let rawDesc = CMSampleBufferGetFormatDescription(sample) ?? fallbackTrackDesc else {
                            passthroughReader.cancelReading()
                            throw NSError(domain: "GlassMPV.Passthrough.Decompress", code: -202, userInfo: [
                                NSLocalizedDescriptionKey: "压缩透传流缺少视频格式描述，无法建立硬解直通"
                            ])
                        }
                        let leadingData = HEVCFormatNormalizer.copyLeadingData(from: sample)
                        guard let created = createDecompressionSessionWithFallback(
                            rawDesc: rawDesc,
                            fallbackSampleData: leadingData,
                            preferredPixelFormat: preferredPixFmt,
                            prefer10Bit: prefer10Bit
                        ) else {
                            passthroughReader.cancelReading()
                            throw NSError(domain: "GlassMPV.Passthrough.Decompress", code: -203, userInfo: [
                                NSLocalizedDescriptionKey: "VTDecompressionSession 硬解直通创建失败 (\(HEVCFormatNormalizer.describeFormat(rawDesc)))"
                            ])
                        }
                        holder = created
                    }

                    guard let activeHolder = holder else { continue }
                    let decodeResult = activeHolder.decode(sampleBuffer: sample)
                    for frame in decodeResult.drained.frames {
                        guard frame.pts.isValid, frame.pts.seconds.isFinite else { continue }
                        reorderBuffer.insert(pts: frame.pts.seconds, frame: frame.buffer)
                        while let ready = reorderBuffer.popNextIfReady() {
                            if startSeconds > 0.1 && ready.pts < startSeconds - 0.05 {
                                continue
                            }
                            emitPassthroughFrame(ready.frame, ptsSeconds: ready.pts)
                        }
                    }
                }

                if passthroughReader.status != .failed && isTokenValid(token) {
                    if let activeHolder = holder {
                        let tail = activeHolder.waitForAsyncFrames()
                        for frame in tail.frames {
                            guard frame.pts.isValid, frame.pts.seconds.isFinite else { continue }
                            reorderBuffer.insert(pts: frame.pts.seconds, frame: frame.buffer)
                        }
                    }
                    for ready in reorderBuffer.drainAll() {
                        if !isTokenValid(token) { return }
                        if startSeconds > 0.1 && ready.pts < startSeconds - 0.05 {
                            continue
                        }
                        emitPassthroughFrame(ready.frame, ptsSeconds: ready.pts)
                    }
                }
            }

            if let activeReader, activeReader.status == .failed && isTokenValid(token) {
                let errDesc = Self.formatDetailedError(activeReader.error)
                logAsync("[pass][error] 原帧率直通读取异常: \(errDesc)")
                if !didStartAudioClock {
                    Task { @MainActor [weak self] in
                        self?.isLoadingPipeline = false
                        self?.pipelineStatusText = ""
                        self?.errorMessage = "原帧率硬解直通失败：\(errDesc)"
                    }
                }
            } else if isTokenValid(token) {
                markReaderEOF()
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
            let desc = Self.formatDetailedError(error)
            logAsync("[pass][error] 原帧率硬解直通运行异常：\(desc)")
            Task { @MainActor [weak self] in
                self?.isLoadingPipeline = false
                self?.pipelineStatusText = ""
                self?.errorMessage = "原帧率硬解直通运行异常：\(desc)"
            }
        }
    }

    private func openAssetReaderWithFallback(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        startSeconds: Double,
        preferredPixelFormat: OSType,
        prefer10Bit: Bool,
        targetDimensions: (width: Int, height: Int)? = nil
    ) throws -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput, tierLabel: String, pixelFormat: OSType) {
        let tiers = Self.buildReaderSettingsTiers(
            preferredFormat: preferredPixelFormat,
            prefer10Bit: prefer10Bit,
            targetDimensions: targetDimensions
        )
        var failures: [String] = []
        for tier in tiers {
            let reader = try AVAssetReader(asset: asset)
            if startSeconds > 0 {
                reader.timeRange = CMTimeRange(
                    start: CMTime(seconds: startSeconds, preferredTimescale: 600),
                    duration: .positiveInfinity
                )
            }
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: tier.settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                let msg = "tier=\(tier.label): canAdd=false"
                failures.append(msg)
                logAsync("[ane][warn] AVAssetReader \(msg)")
                continue
            }
            reader.add(output)
            if reader.startReading() {
                logAsync("[ane] AVAssetReader 启动成功 (tier=\(tier.label), pixFmt=\(Self.fourCCString(tier.pixelFormat)))")
                return (reader: reader, output: output, tierLabel: tier.label, pixelFormat: tier.pixelFormat)
            } else {
                let errStr = Self.formatDetailedError(reader.error)
                let msg = "tier=\(tier.label): startReading=false (\(errStr))"
                failures.append(msg)
                logAsync("[ane][warn] AVAssetReader \(msg)")
                reader.cancelReading()
            }
        }
        let summary = failures.joined(separator: " | ")
        throw NSError(domain: "GlassMPV.OpticalFlow.Reader", code: -201, userInfo: [
            NSLocalizedDescriptionKey: "所有 AVAssetReader 解码档位均失败: \(summary)"
        ])
    }

    private func openCompressedPassthroughReader(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        startSeconds: Double
    ) throws -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        if startSeconds > 0 {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: startSeconds, preferredTimescale: 600),
                duration: .positiveInfinity
            )
        }
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw NSError(domain: "GlassMPV.OpticalFlow.Passthrough", code: -211, userInfo: [
                NSLocalizedDescriptionKey: "压缩透传 AVAssetReaderTrackOutput(outputSettings: nil) 无法挂载"
            ])
        }
        reader.add(output)
        guard reader.startReading() else {
            let errStr = Self.formatDetailedError(reader.error)
            reader.cancelReading()
            throw NSError(domain: "GlassMPV.OpticalFlow.Passthrough", code: -212, userInfo: [
                NSLocalizedDescriptionKey: "压缩透传 AVAssetReader.startReading 失败: \(errStr)"
            ])
        }
        logAsync("[ane] 压缩透传 AVAssetReader 启动成功 (outputSettings=nil, start=\(String(format: "%.2f", startSeconds))s)")
        return (reader: reader, output: output)
    }

    private func createDecompressionSessionWithFallback(
        rawDesc: CMVideoFormatDescription,
        fallbackSampleData: Data?,
        preferredPixelFormat: OSType,
        prefer10Bit: Bool,
        targetDimensions: (width: Int, height: Int)? = nil
    ) -> VTDecompressionSessionHolder? {
        let candidates = HEVCFormatNormalizer.makeNormalizedFormatDescriptionCandidates(
            from: rawDesc,
            fallbackSampleData: fallbackSampleData
        )
        let pixelFormats = OpticalFlowResolutionPlanner.nativeDecodePixelFormats(
            prefer10Bit: prefer10Bit,
            preferredPixelFormat: preferredPixelFormat
        )
        let dimensionOptions: [(dims: (width: Int, height: Int)?, scaled: Bool)]
        if let targetDimensions, targetDimensions.width >= 2, targetDimensions.height >= 2 {
            dimensionOptions = [(targetDimensions, true), (nil, false)]
        } else {
            dimensionOptions = [(nil, false)]
        }

        var failures: [String] = []
        for candidate in candidates {
            for dimOption in dimensionOptions {
                for fmt in pixelFormats {
                    var attrs: [String: Any] = [
                        kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: fmt),
                        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                        kCVPixelBufferMetalCompatibilityKey as String: true
                    ]
                    if let dims = dimOption.dims {
                        attrs[kCVPixelBufferWidthKey as String] = NSNumber(value: dims.width)
                        attrs[kCVPixelBufferHeightKey as String] = NSNumber(value: dims.height)
                    }
                    var session: VTDecompressionSession?
                    let status = VTDecompressionSessionCreate(
                        allocator: kCFAllocatorDefault,
                        formatDescription: candidate.description,
                        decoderSpecification: nil,
                        imageBufferAttributes: attrs as CFDictionary,
                        outputCallback: nil,
                        decompressionSessionOut: &session
                    )
                    if status == noErr, let session {
                        _ = VTSessionSetProperty(
                            session,
                            key: kVTDecompressionPropertyKey_RealTime,
                            value: kCFBooleanTrue
                        )
                        _ = VTSessionSetProperty(
                            session,
                            key: kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata,
                            value: kCFBooleanTrue
                        )
                        let scaleTag = dimOption.dims.map { ", hwScale=\($0.width)x\($0.height)" } ?? ""
                        logAsync("[ane] VTDecompressionSession 硬解兜底已启动 (strategy=\(candidate.strategy), pixFmt=\(Self.fourCCString(fmt))\(scaleTag))")
                        return VTDecompressionSessionHolder(
                            session: session,
                            formatDescription: candidate.description,
                            strategy: candidate.strategy,
                            isHardwareScaled: dimOption.scaled
                        )
                    }
                    let scaleTag = dimOption.dims.map { ":\($0.width)x\($0.height)" } ?? ""
                    failures.append("\(candidate.strategy)/\(Self.fourCCString(fmt))\(scaleTag)=\(status)")
                }
            }
        }
        logAsync("[ane][error] VTDecompressionSession 硬解兜底全部创建失败: \(failures.joined(separator: ", "))")
        return nil
    }

    private func startPipeline(
        url: URL,
        width: Int,
        height: Int,
        sourceFPS: Double,
        startSeconds: Double,
        spatial2x: Bool,
        targetFPS: OpticalFlowTargetFPS,
        prefer10Bit: Bool,
        token: UUID
    ) {
#if !targetEnvironment(simulator)
        let safeW = max(width, 2)
        let safeH = max(height, 2)
        Task.detached(priority: .high) { [weak self] in
            guard let self else { return }
            await self.runOpticalFlowTask(
                url: url,
                width: safeW,
                height: safeH,
                sourceFPS: sourceFPS,
                startSeconds: startSeconds,
                spatial2x: spatial2x,
                targetFPS: targetFPS,
                prefer10Bit: prefer10Bit,
                token: token
            )
        }
#endif
    }

#if !targetEnvironment(simulator)
    private enum ActiveOpticalFlowConfiguration {
        case lowLatency(VTLowLatencyFrameInterpolationConfiguration)
        case frameRateConversion(VTFrameRateConversionConfiguration)

        var sourcePixelBufferAttributes: [String: Any] {
            switch self {
            case .lowLatency(let cfg):
                return cfg.sourcePixelBufferAttributes
            case .frameRateConversion(let cfg):
                return cfg.sourcePixelBufferAttributes
            }
        }

        var destinationPixelBufferAttributes: [String: Any] {
            switch self {
            case .lowLatency(let cfg):
                return cfg.destinationPixelBufferAttributes
            case .frameRateConversion(let cfg):
                return cfg.destinationPixelBufferAttributes
            }
        }

        func startSession(on processor: VTFrameProcessor) throws {
            switch self {
            case .lowLatency(let cfg):
                try processor.startSession(configuration: cfg)
            case .frameRateConversion(let cfg):
                try processor.startSession(configuration: cfg)
            }
        }
    }

    private struct ActivatedOpticalFlowSession: @unchecked Sendable {
        let candidateIndex: Int
        let candidate: OpticalFlowCandidate
        let configuration: ActiveOpticalFlowConfiguration
        let processor: VTFrameProcessor
        let pixelFormat: OSType
        let sourceNormPool: CVPixelBufferPool?
        let sourceTransferSession: VTPixelTransferSession?
        let destPool: CVPixelBufferPool
        let transferSession: VTPixelTransferSession?
    }

    private final class OpticalFlowPipelineState: @unchecked Sendable {
        var configuration: ActiveOpticalFlowConfiguration
        var processor: VTFrameProcessor
        var candidates: [OpticalFlowCandidate]
        var candidateIndex: Int
        var activeCandidate: OpticalFlowCandidate
        var activeWidth: Int
        var activeHeight: Int
        var activeSpatial2x: Bool
        var pixelFormat: OSType
        let prefer10Bit: Bool
        var requestedSpatial2x: Bool
        var sourceWidth: Int
        var sourceHeight: Int
        var sourceFPS: Double
        var requestedTargetFPS: OpticalFlowTargetFPS
        var activeTargetFPS: OpticalFlowTargetFPS
        var phaseScheduler: OpticalFlowPhaseScheduler
        var budgetGuard: OpticalFlowBudgetGuard
        var forceNormalizeSource: Bool
        var sourceNormPool: CVPixelBufferPool?
        var sourceTransferSession: VTPixelTransferSession?
        var destPool: CVPixelBufferPool
        var transferSession: VTPixelTransferSession?
        var previousBuffer: CVPixelBuffer?
        var previousPTS: CMTime = .invalid
        var localSuccessCount: Int = 0
        var localBatchCount: Int = 0
        var localConsecutiveFailures: Int = 0
        var totalInterpolationMs: Double = 0
        var didCheckActualDimensions: Bool = false
        var didStartAudioClock: Bool = false
        var didLogCatchUp: Bool = false
        var didCachePendingFirstFrame: Bool = false
        var frcNeedsRandomSubmission: Bool = true
        var interpolationExhausted: Bool = false
        var didRetryWithNormalizationOnCurrentCandidate: Bool = false
        var awaitingClockCatchUpAfterSwitch: Bool = false
        var expectedDecodeDimensions: (width: Int, height: Int)? = nil
        var isCatchingUpToClock: Bool = false
        var lastPairReadyHostTime: CFTimeInterval = 0
        var lastObservedThermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
        var lastObservedLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled

        init(
            configuration: ActiveOpticalFlowConfiguration,
            processor: VTFrameProcessor,
            candidates: [OpticalFlowCandidate],
            candidateIndex: Int,
            activeCandidate: OpticalFlowCandidate,
            activeWidth: Int,
            activeHeight: Int,
            activeSpatial2x: Bool,
            pixelFormat: OSType,
            prefer10Bit: Bool,
            requestedSpatial2x: Bool,
            sourceWidth: Int,
            sourceHeight: Int,
            sourceFPS: Double,
            requestedTargetFPS: OpticalFlowTargetFPS,
            activeTargetFPS: OpticalFlowTargetFPS,
            forceNormalizeSource: Bool,
            sourceNormPool: CVPixelBufferPool?,
            sourceTransferSession: VTPixelTransferSession?,
            destPool: CVPixelBufferPool,
            transferSession: VTPixelTransferSession?
        ) {
            self.configuration = configuration
            self.processor = processor
            self.candidates = candidates
            self.candidateIndex = candidateIndex
            self.activeCandidate = activeCandidate
            self.activeWidth = activeWidth
            self.activeHeight = activeHeight
            self.activeSpatial2x = activeSpatial2x
            self.pixelFormat = pixelFormat
            self.prefer10Bit = prefer10Bit
            self.requestedSpatial2x = requestedSpatial2x
            self.sourceWidth = sourceWidth
            self.sourceHeight = sourceHeight
            self.sourceFPS = sourceFPS
            self.requestedTargetFPS = requestedTargetFPS
            self.activeTargetFPS = activeTargetFPS
            self.phaseScheduler = OpticalFlowPhaseScheduler(targetTier: activeTargetFPS, sourceFPS: sourceFPS)
            self.budgetGuard = OpticalFlowBudgetGuard()
            self.forceNormalizeSource = forceNormalizeSource
            self.sourceNormPool = sourceNormPool
            self.sourceTransferSession = sourceTransferSession
            self.destPool = destPool
            self.transferSession = transferSession
        }

        func cleanup() {
            processor.endSession()
            if let sourceTransferSession {
                VTPixelTransferSessionInvalidate(sourceTransferSession)
                self.sourceTransferSession = nil
            }
            if let transferSession {
                VTPixelTransferSessionInvalidate(transferSession)
                self.transferSession = nil
            }
        }
    }

    private func runOpticalFlowTask(
        url: URL,
        width: Int,
        height: Int,
        sourceFPS: Double,
        startSeconds: Double,
        spatial2x: Bool,
        targetFPS: OpticalFlowTargetFPS,
        prefer10Bit: Bool,
        token: UUID
    ) async {
        do {
            let safeSourceFPS = (sourceFPS.isFinite && sourceFPS > 1.0) ? sourceFPS : 24.0
            let initialThermal = ProcessInfo.processInfo.thermalState
            let initialLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            var startingTier = targetFPS
            if let cap = OpticalFlowResolutionPlanner.effectivePowerThermalCap(
                active: targetFPS,
                thermalState: initialThermal,
                isLowPowerMode: initialLowPower
            ) {
                startingTier = cap.tier
                logAsync("[ane][power] \(cap.reason)，初始目标帧率限档为 \(cap.tier.shortBadge)")
            }
            var resolvedTier = startingTier
            var candidates: [OpticalFlowCandidate] = []
            var activatedOpt: ActivatedOpticalFlowSession?
            var currentTier: OpticalFlowTargetFPS? = startingTier

            while let tier = currentTier {
                let tierSpatial2x = spatial2x && tier.allowsSpatial2x && !SuperResolutionPolicy.isAlready4K(width: width, height: height)
                let tierCandidates = buildCandidatePlanForDevice(
                    sourceWidth: width,
                    sourceHeight: height,
                    requestedSpatial2x: tierSpatial2x,
                    targetFPS: tier,
                    sourceFPS: safeSourceFPS
                )
                if let session = activateCandidate(
                    in: tierCandidates,
                    startingAt: 0,
                    prefer10Bit: prefer10Bit
                ) {
                    resolvedTier = tier
                    candidates = tierCandidates
                    activatedOpt = session
                    break
                }
                currentTier = tier.nextLowerTier
            }

            guard let activated = activatedOpt else {
                logAsync("[ane] 无法初始化 VideoToolbox 光流配置（源 \(width)×\(height), 目标 \(targetFPS.shortBadge)）")
                Task { @MainActor [weak self] in
                    self?.activeBackendLabel = "不可用"
                    self?.isLoadingPipeline = false
                    self?.pipelineStatusText = ""
                    self?.errorMessage = "无法初始化 VideoToolbox 光流配置（\(width)×\(height)）。"
                }
                return
            }

            let finalTier = resolvedTier
            let resolvedTargetFPS = finalTier.effectiveTargetFPS(sourceFPS: safeSourceFPS)
            let isHeavyFormat = OpticalFlowResolutionPlanner.isHeavyPixelFormat(activated.pixelFormat)
            let queueLimits = OpticalFlowResolutionPlanner.recommendedQueueLimits(
                targetFPS: resolvedTargetFPS,
                isHeavyPixelFormat: isHeavyFormat
            )
            updateQueueLimits(maxQueued: queueLimits.maxQueued, prebuffer: queueLimits.prebuffer)
            if finalTier != targetFPS {
                logAsync("[ane][fallback] 目标档位 \(targetFPS.shortBadge) 已调整至 \(finalTier.shortBadge)")
                Task { @MainActor [weak self] in
                    guard let self, self.isTokenValid(token) else { return }
                    self.effectiveTargetFPS = finalTier
                    self.interpolatedFPS = resolvedTargetFPS
                    self.syncDisplayLinkState()
                }
            }

            let targetDecodeDims = OpticalFlowResolutionPlanner.recommendedDecodeDimensions(
                sourceWidth: width,
                sourceHeight: height,
                forOpticalFlow: true
            )
            let resolvedPixFmtString = Self.fourCCString(activated.pixelFormat)
            let initialForceNorm = (width != activated.candidate.width || height != activated.candidate.height)
            let decodeHint = targetDecodeDims.map { "\($0.width)×\($0.height)" } ?? "源尺寸"
            logAsync("[ane] 光流会话启动: 源 \(width)×\(height) (解码目标 \(decodeHint)) -> 后端 \(activated.candidate.displayLabel), target=\(resolvedTier.shortBadge), pixFmt=\(resolvedPixFmtString), forceNorm=\(initialForceNorm), prefer10Bit=\(prefer10Bit)")

            Task { @MainActor [weak self] in
                guard let self, self.isTokenValid(token) else { return }
                self.activeBackendLabel = activated.candidate.displayLabel
                self.enableSpatial2xUpscale = activated.candidate.spatial2x
                if self.bitDepthLabel == "--" {
                    let parsed = PlaybackHUDMetrics.parseBitDepth(fromPixelFormat: resolvedPixFmtString)
                    if parsed != "--" {
                        self.bitDepthLabel = parsed
                    }
                }
            }

            let initialSpatial2x = spatial2x && resolvedTier.allowsSpatial2x && !SuperResolutionPolicy.isAlready4K(width: width, height: height)
            let state = OpticalFlowPipelineState(
                configuration: activated.configuration,
                processor: activated.processor,
                candidates: candidates,
                candidateIndex: activated.candidateIndex,
                activeCandidate: activated.candidate,
                activeWidth: activated.candidate.width,
                activeHeight: activated.candidate.height,
                activeSpatial2x: activated.candidate.spatial2x,
                pixelFormat: activated.pixelFormat,
                prefer10Bit: prefer10Bit,
                requestedSpatial2x: initialSpatial2x,
                sourceWidth: width,
                sourceHeight: height,
                sourceFPS: safeSourceFPS,
                requestedTargetFPS: targetFPS,
                activeTargetFPS: resolvedTier,
                forceNormalizeSource: initialForceNorm,
                sourceNormPool: activated.sourceNormPool,
                sourceTransferSession: activated.sourceTransferSession,
                destPool: activated.destPool,
                transferSession: activated.transferSession
            )
            state.expectedDecodeDimensions = targetDecodeDims
            defer { state.cleanup() }

            let decodePipe = OpticalFlowDecodedFramePipe(capacity: 8)
            let initialStatePixelFormat = state.pixelFormat
            let forcedPassthrough = isPassthroughForced(for: url)

            let producerTask = Task.detached(priority: .high) { [weak self] in
                guard let self else {
                    decodePipe.finishProducer(error: nil)
                    return
                }
                var activeReader: AVAssetReader?
                var holder: VTDecompressionSessionHolder?
                defer {
                    holder?.invalidate()
                    activeReader?.cancelReading()
                }
                do {
                    let asset = AVURLAsset(url: url)
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    guard let videoTrack = await Self.selectPrimaryVideoTrack(from: tracks) else {
                        decodePipe.finishProducer(error: NSError(domain: "GlassMPV.OpticalFlow", code: -102, userInfo: [
                            NSLocalizedDescriptionKey: "未找到视频轨道，请检查视频格式。"
                        ]))
                        return
                    }
                    let trackFormatDescriptions = (try? await videoTrack.load(.formatDescriptions)) ?? []
                    let fallbackTrackDesc = trackFormatDescriptions.first

                    var primaryError: Error?
                    var openedReader: (reader: AVAssetReader, output: AVAssetReaderTrackOutput, tierLabel: String, pixelFormat: OSType)?
                    if forcedPassthrough {
                        self.logAsync("[ane] 命中片源透传缓存，跳过常规 AVAssetReader 直走压缩透传硬解")
                    } else {
                        do {
                            openedReader = try self.openAssetReaderWithFallback(
                                asset: asset,
                                videoTrack: videoTrack,
                                startSeconds: startSeconds,
                                preferredPixelFormat: initialStatePixelFormat,
                                prefer10Bit: prefer10Bit,
                                targetDimensions: targetDecodeDims
                            )
                        } catch {
                            primaryError = error
                            self.markPassthroughRequired(for: url)
                        }
                    }

                    var decodedAnyPrimaryFrame = false
                    if let openedReader {
                        let reader = openedReader.reader
                        let trackOutput = openedReader.output
                        activeReader = reader

                        while reader.status == .reading {
                            if !self.isTokenValid(token) || Task.isCancelled {
                                reader.cancelReading()
                                decodePipe.discardAllAndClose()
                                return
                            }
                            guard let sample = trackOutput.copyNextSampleBuffer(),
                                  let currentBuffer = CMSampleBufferGetImageBuffer(sample) else {
                                break
                            }
                            decodedAnyPrimaryFrame = true
                            let currentPTS = CMSampleBufferGetPresentationTimeStamp(sample)
                            let sent = await decodePipe.send(
                                OpticalFlowSendableFrame(pts: currentPTS, buffer: currentBuffer)
                            )
                            if !sent {
                                reader.cancelReading()
                                return
                            }
                        }

                        if !decodedAnyPrimaryFrame && reader.status == .failed && self.isTokenValid(token) {
                            primaryError = reader.error ?? primaryError
                            self.markPassthroughRequired(for: url)
                        }
                    }

                    let shouldUsePassthroughFallback = forcedPassthrough
                        || (openedReader == nil)
                        || (!decodedAnyPrimaryFrame && activeReader?.status == .failed && self.isTokenValid(token))

                    if shouldUsePassthroughFallback {
                        if !forcedPassthrough {
                            let reasonText = Self.formatDetailedError(primaryError)
                            self.logAsync("[ane][warn] 常规 AVAssetReader 全档位失败，切换压缩透传 + VTDecompressionSession 硬解兜底: \(reasonText)")
                        }

                        let passthrough = try self.openCompressedPassthroughReader(
                            asset: asset,
                            videoTrack: videoTrack,
                            startSeconds: startSeconds
                        )
                        let passthroughReader = passthrough.reader
                        let passthroughOutput = passthrough.output
                        activeReader = passthroughReader

                        var reorderBuffer = OpticalFlowPTSReorderBuffer<CVPixelBuffer>(maxDepth: 6)
                        var decodedSuccessFrames = 0
                        var loggedDecodeFailure = false

                        while passthroughReader.status == .reading {
                            if !self.isTokenValid(token) || Task.isCancelled {
                                passthroughReader.cancelReading()
                                decodePipe.discardAllAndClose()
                                return
                            }
                            guard let sample = passthroughOutput.copyNextSampleBuffer() else {
                                break
                            }
                            guard CMSampleBufferGetDataBuffer(sample) != nil else {
                                continue
                            }

                            if holder == nil {
                                guard let rawDesc = CMSampleBufferGetFormatDescription(sample) ?? fallbackTrackDesc else {
                                    passthroughReader.cancelReading()
                                    throw NSError(domain: "GlassMPV.OpticalFlow.Decompress", code: -202, userInfo: [
                                        NSLocalizedDescriptionKey: "压缩透传流缺少视频格式描述，无法建立硬解兜底"
                                    ])
                                }
                                let leadingData = HEVCFormatNormalizer.copyLeadingData(from: sample)
                                guard let created = self.createDecompressionSessionWithFallback(
                                    rawDesc: rawDesc,
                                    fallbackSampleData: leadingData,
                                    preferredPixelFormat: initialStatePixelFormat,
                                    prefer10Bit: prefer10Bit,
                                    targetDimensions: targetDecodeDims
                                ) else {
                                    passthroughReader.cancelReading()
                                    throw NSError(domain: "GlassMPV.OpticalFlow.Decompress", code: -203, userInfo: [
                                        NSLocalizedDescriptionKey: "VTDecompressionSession 硬解兜底全部候选均失败 (\(HEVCFormatNormalizer.describeFormat(rawDesc)))"
                                    ])
                                }
                                holder = created
                            }

                            guard let activeHolder = holder else { continue }
                            var decodeResult = activeHolder.decode(sampleBuffer: sample)
                            if decodedSuccessFrames == 0 && decodeResult.decodeStatus != noErr && activeHolder.isHardwareScaled {
                                self.logAsync("[ane][warn] 硬件缩放硬解(\(activeHolder.strategy))首帧返回 \(decodeResult.decodeStatus)，自动回退源分辨率硬解")
                                let retryDesc = CMSampleBufferGetFormatDescription(sample) ?? activeHolder.formatDescription
                                let retryLeading = HEVCFormatNormalizer.copyLeadingData(from: sample)
                                activeHolder.invalidate()
                                holder = self.createDecompressionSessionWithFallback(
                                    rawDesc: retryDesc,
                                    fallbackSampleData: retryLeading,
                                    preferredPixelFormat: initialStatePixelFormat,
                                    prefer10Bit: prefer10Bit,
                                    targetDimensions: nil
                                )
                                if let retryHolder = holder {
                                    decodeResult = retryHolder.decode(sampleBuffer: sample)
                                }
                            }
                            if (decodeResult.decodeStatus != noErr || decodeResult.drained.lastStatus != noErr),
                               !loggedDecodeFailure,
                               decodedSuccessFrames == 0 {
                                loggedDecodeFailure = true
                                self.logAsync("[ane][warn] VTDecompressionSession 解码异常状态 decode=\(decodeResult.decodeStatus), callback=\(decodeResult.drained.lastStatus), strategy=\(holder?.strategy ?? activeHolder.strategy)")
                            }

                            for frame in decodeResult.drained.frames {
                                guard frame.pts.isValid, frame.pts.seconds.isFinite else { continue }
                                decodedSuccessFrames += 1
                                reorderBuffer.insert(pts: frame.pts.seconds, frame: frame.buffer)
                                while let ready = reorderBuffer.popNextIfReady() {
                                    if startSeconds > 0.1 && ready.pts < startSeconds - 0.05 {
                                        continue
                                    }
                                    let sent = await decodePipe.send(
                                        OpticalFlowSendableFrame(
                                            pts: CMTime(seconds: ready.pts, preferredTimescale: 600),
                                            buffer: ready.frame
                                        )
                                    )
                                    if !sent {
                                        passthroughReader.cancelReading()
                                        return
                                    }
                                }
                            }
                        }

                        if passthroughReader.status != .failed && self.isTokenValid(token) && !Task.isCancelled {
                            if let activeHolder = holder {
                                let tail = activeHolder.waitForAsyncFrames()
                                for frame in tail.frames {
                                    guard frame.pts.isValid, frame.pts.seconds.isFinite else { continue }
                                    decodedSuccessFrames += 1
                                    reorderBuffer.insert(pts: frame.pts.seconds, frame: frame.buffer)
                                }
                            }
                            for ready in reorderBuffer.drainAll() {
                                if !self.isTokenValid(token) || Task.isCancelled {
                                    return
                                }
                                if startSeconds > 0.1 && ready.pts < startSeconds - 0.05 {
                                    continue
                                }
                                let sent = await decodePipe.send(
                                    OpticalFlowSendableFrame(
                                        pts: CMTime(seconds: ready.pts, preferredTimescale: 600),
                                        buffer: ready.frame
                                    )
                                )
                                if !sent {
                                    return
                                }
                            }
                        }
                    }

                    if let activeReader, activeReader.status == .failed && self.isTokenValid(token) {
                        let readerErr = activeReader.error ?? NSError(domain: "GlassMPV.OpticalFlow.Reader", code: -204, userInfo: [
                            NSLocalizedDescriptionKey: "AVAssetReader 读取失败"
                        ])
                        decodePipe.finishProducer(error: readerErr)
                    } else {
                        decodePipe.finishProducer(error: nil)
                    }
                } catch {
                    decodePipe.finishProducer(error: error)
                }
            }
            defer {
                decodePipe.discardAllAndClose()
                producerTask.cancel()
            }

            var producerFailureError: Error?
            consumeLoop: while true {
                if !isTokenValid(token) {
                    break consumeLoop
                }
                var sleepAccumulatedMs: Double = 0
                while queuedCount() >= readMaxQueuedFrames() && !hasPendingUserSwitch() {
                    if !isTokenValid(token) {
                        break consumeLoop
                    }
                    let sleepStart = CACurrentMediaTime()
                    try? await Task.sleep(for: .milliseconds(8))
                    sleepAccumulatedMs += (CACurrentMediaTime() - sleepStart) * 1000.0
                }
                switch await decodePipe.receive() {
                case .frame(let decoded):
                    let nowHost = CACurrentMediaTime()
                    let pairActiveMs = state.lastPairReadyHostTime > 0
                        ? max(0, (nowHost - state.lastPairReadyHostTime) * 1000.0 - sleepAccumulatedMs)
                        : 0
                    try await processDecodedFrame(
                        SendablePixelBuffer(buffer: decoded.buffer),
                        currentPTS: decoded.pts,
                        state: state,
                        token: token,
                        pairActiveMs: pairActiveMs
                    )
                    state.lastPairReadyHostTime = CACurrentMediaTime()
                case .finished(let err):
                    producerFailureError = err
                    break consumeLoop
                }
            }

            guard isTokenValid(token) else { return }

            if let producerFailureError {
                let errDesc = Self.formatDetailedError(producerFailureError)
                logAsync("[ane][error] AVAssetReader 读取异常终止: \(errDesc)")
                if !state.didStartAudioClock {
                    Task { @MainActor [weak self] in
                        self?.isLoadingPipeline = false
                        self?.pipelineStatusText = ""
                        self?.errorMessage = "光流解码异常：\(errDesc)"
                    }
                }
            } else {
                markReaderEOF()

                if !state.didStartAudioClock && queuedCount() > 0 {
                    state.didStartAudioClock = true
                    Task { @MainActor [weak self] in
                        guard let self, self.isTokenValid(token) else { return }
                        self.isPipelineReadyToPlay = true
                        self.pipelineStatusText = ""
                        self.startActiveClockIfNeeded()
                    }
                } else if queuedCount() == 0 && !state.didStartAudioClock {
                    Task { @MainActor [weak self] in
                        self?.isLoadingPipeline = false
                        self?.pipelineStatusText = ""
                    }
                }
            }
        } catch {
            let desc = Self.formatDetailedError(error)
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
        let hostTick = CACurrentMediaTime()
        if hostTick - lastDisplayTickHostTime < 0.003 {
            return
        }
        lastDisplayTickHostTime = hostTick

        guard let layer = displayLayer else { return }
        if isInterpolationEnabled && !isPaused {
            displayContainer?.pulseProMotionCommit()
        }

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
        var presentedPTS: Double?
        let interpolationActive = isInterpolationEnabled
        bufferLock.lock()
        let paceResult = OpticalFlowFramePacer.dequeueNextFrame(
            from: &frameQueue,
            now: now,
            isInterpolationEnabled: interpolationActive
        )
        frameToPresent = paceResult.frame
        presentedPTS = paceResult.presentedPTS
        droppedInTick = paceResult.droppedCount
        let remainingQueueCount = frameQueue.count
        let eofReached = isReaderEOF
        let lastPTS = lastEnqueuedPTS
        bufferLock.unlock()

        if let presentedPTS {
            latestAVDeltaMs = (presentedPTS - now) * 1000.0
        }

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
        let displayBuffer: CVPixelBuffer
        if videoEnhancementPreset != .off {
            let enhancer = metalEnhancer
            displayBuffer = enhancer.process(
                buffer,
                preset: videoEnhancementPreset,
                strength: videoEnhancementStrength,
                isHDRContent: isHDRContent,
                isDolbyVision: isDolbyVisionContent,
                bypassForComparison: isComparingOriginalQuality
            )
            if activeQualityPipelineLabel != enhancer.activePipelineLabel {
                activeQualityPipelineLabel = enhancer.activePipelineLabel
            }
            if presentedFrameCount % 15 == 0 {
                averageQualityEnhanceMs = enhancer.averageProcessMs
            }
        } else {
            displayBuffer = buffer
            if activeQualityPipelineLabel != "关闭" {
                activeQualityPipelineLabel = "关闭"
                averageQualityEnhanceMs = 0
            }
        }
        guard let sampleBuffer = makeSampleBuffer(from: displayBuffer, ptsSeconds: ptsSeconds) else { return }
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

    private func updateQueueLimits(maxQueued: Int, prebuffer: Int) {
        bufferLock.lock()
        maxQueuedFrames = max(8, maxQueued)
        prebufferFrameTarget = max(2, min(prebuffer, maxQueuedFrames / 2))
        bufferLock.unlock()
    }

    private func readMaxQueuedFrames() -> Int {
        bufferLock.lock()
        let value = maxQueuedFrames
        bufferLock.unlock()
        return value
    }

    @MainActor
    func currentQueueDepthSnapshot() -> Int {
        queuedCount()
    }

    private func isPassthroughForced(for url: URL) -> Bool {
        let key = url.standardizedFileURL.path
        passthroughCacheLock.lock()
        let exists = passthroughRequiredURLKeys.contains(key)
        passthroughCacheLock.unlock()
        return exists
    }

    private func markPassthroughRequired(for url: URL) {
        let key = url.standardizedFileURL.path
        passthroughCacheLock.lock()
        if passthroughRequiredURLKeys.count >= 32 {
            passthroughRequiredURLKeys.removeAll()
        }
        passthroughRequiredURLKeys.insert(key)
        passthroughCacheLock.unlock()
    }

    private func enqueuePendingUserSwitch(target: OpticalFlowTargetFPS, spatial2x: Bool) {
        bufferLock.lock()
        pendingUserSwitch = (target: target, spatial2x: spatial2x)
        bufferLock.unlock()
    }

    private func takePendingUserSwitch() -> (target: OpticalFlowTargetFPS, spatial2x: Bool)? {
        bufferLock.lock()
        let pending = pendingUserSwitch
        pendingUserSwitch = nil
        bufferLock.unlock()
        return pending
    }

    private func hasPendingUserSwitch() -> Bool {
        bufferLock.lock()
        let hasPending = (pendingUserSwitch != nil)
        bufferLock.unlock()
        return hasPending
    }

    private func readIsReaderEOF() -> Bool {
        bufferLock.lock()
        let eof = isReaderEOF
        bufferLock.unlock()
        return eof
    }

    private func pruneExpiredFrames(before minPTS: Double) {
        bufferLock.lock()
        frameQueue.removeAll { $0.pts < minPTS }
        bufferLock.unlock()
    }

    private func setColorFallbackMetadata(
        from formatDescription: CMFormatDescription?,
        trackMetrics: (width: Int, height: Int, codec: String, bitDepth: String, hdrTag: String, isHDR: Bool, isDolbyVision: Bool, transferName: String?)
    ) {
        var meta = TrackColorFallbackMetadata()
        meta.isHDR = trackMetrics.isHDR
        meta.isDolbyVision = trackMetrics.isDolbyVision
        if let desc = formatDescription,
           let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any] {
            if let primaries = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String {
                meta.colorPrimaries = primaries as CFString
            }
            if let transfer = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String {
                meta.transferFunction = transfer as CFString
            }
            if let matrix = ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String {
                meta.ycbcrMatrix = matrix as CFString
            }
            if let mdcv = ext[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] as? Data {
                meta.masteringDisplayColorVolume = mdcv as CFData
            }
            if let clli = ext[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] as? Data {
                meta.contentLightLevelInfo = clli as CFData
            }
            if let ave = ext[kCMFormatDescriptionExtension_AmbientViewingEnvironment as String] as? Data {
                meta.ambientViewingEnvironment = ave as CFData
            }
        }
        bufferLock.lock()
        colorFallbackMetadata = meta
        bufferLock.unlock()
    }

    private func readColorFallbackMetadata() -> TrackColorFallbackMetadata {
        bufferLock.lock()
        let meta = colorFallbackMetadata
        bufferLock.unlock()
        return meta
    }

    private func clearColorFallbackMetadata() {
        bufferLock.lock()
        colorFallbackMetadata = TrackColorFallbackMetadata()
        didInspectFirstDecodedColor = false
        bufferLock.unlock()
    }

    private func inspectDecodedBufferColorOnceIfNeeded(_ buffer: CVPixelBuffer, token: UUID) {
        bufferLock.lock()
        let alreadyChecked = didInspectFirstDecodedColor
        if !alreadyChecked {
            didInspectFirstDecodedColor = true
        }
        bufferLock.unlock()
        guard !alreadyChecked else { return }

        let info = Self.inspectPixelBufferColorInfo(buffer)
        Task { @MainActor [weak self] in
            guard let self, self.isTokenValid(token) else { return }
            if self.bitDepthLabel == "--", let depth = info.bitDepth {
                self.bitDepthLabel = depth
            }
            if info.isHDR && !self.isHDRContent {
                self.isHDRContent = true
                if self.rawHDRTransferName == nil {
                    self.rawHDRTransferName = info.transferName
                }
                self.isHDRActive = self.isEDREnabled
                self.hdrLabel = PlaybackHUDMetrics.formatHDRTag(
                    isHDRContent: true,
                    transferName: self.rawHDRTransferName,
                    isHDRActive: self.isHDRActive,
                    isDolbyVision: self.isDolbyVisionContent
                )
            }
        }
    }

    nonisolated static func inspectPixelBufferColorInfo(
        _ buffer: CVPixelBuffer
    ) -> (isHDR: Bool, transferName: String?, bitDepth: String?) {
        let fmtStr = fourCCString(CVPixelBufferGetPixelFormatType(buffer))
        let parsedDepth = PlaybackHUDMetrics.parseBitDepth(fromPixelFormat: fmtStr)
        let transferRef = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil)
        let transferName = transferRef as? String
        let lower = (transferName ?? "").lowercased()
        let isHDR = lower.contains("2084") || lower.contains("pq") || lower.contains("hlg") || lower.contains("2100")
        return (isHDR, transferName, parsedDepth == "--" ? nil : parsedDepth)
    }

    private static func selectPrimaryVideoTrack(
        from tracks: [AVAssetTrack],
        isolation: isolated (any Actor)? = #isolation
    ) async -> AVAssetTrack? {
        guard tracks.count > 1 else { return tracks.first }
        var scored: [(track: AVAssetTrack, score: Double)] = []
        scored.reserveCapacity(tracks.count)
        for track in tracks {
            let isEnabled = (try? await track.load(.isEnabled)) ?? true
            let isPlayable = (try? await track.load(.isPlayable)) ?? true
            let rate = (try? await track.load(.nominalFrameRate)) ?? 0
            let size = (try? await track.load(.naturalSize)) ?? .zero
            let descs = (try? await track.load(.formatDescriptions)) ?? []
            var score = Double(abs(size.width * size.height))
            if !isEnabled { score *= 0.1 }
            if !isPlayable { score *= 0.25 }
            if rate > 1.0 { score += 1_000_000.0 }
            if let desc = descs.first {
                let sub = CMFormatDescriptionGetMediaSubType(desc)
                let fcc = fourCCString(sub).lowercased()
                if fcc == "jpeg" || fcc == "mjpa" || fcc == "png" {
                    score = -1.0
                } else if fcc == "dvh1" || fcc == "dvhe" {
                    score += 500_000.0
                }
            }
            scored.append((track: track, score: score))
        }
        return scored.max(by: { $0.score < $1.score })?.track ?? tracks.first
    }

    @MainActor
    private static func selectPlayableAudioTrack(from tracks: [AVAssetTrack]) async -> AVAssetTrack? {
        guard tracks.count > 1 else { return tracks.first }
        for track in tracks {
            let isPlayable = (try? await track.load(.isPlayable)) ?? true
            let isEnabled = (try? await track.load(.isEnabled)) ?? true
            if isPlayable && isEnabled {
                return track
            }
        }
        return tracks.first
    }

    @MainActor
    func updateTargetConfiguration(targetFPS: OpticalFlowTargetFPS, spatial2x: Bool) {
        requestedTargetFPS = targetFPS
        effectiveTargetFPS = targetFPS
        let is4K = SuperResolutionPolicy.isAlready4K(width: videoWidth, height: videoHeight)
        let allowedSpatial = isInterpolationEnabled && spatial2x && targetFPS.allowsSpatial2x && !is4K
        enableSpatial2xUpscale = allowedSpatial
        let safeSrc = sourceFPS > 1.0 ? sourceFPS : 24.0
        interpolatedFPS = isInterpolationEnabled
            ? targetFPS.effectiveTargetFPS(sourceFPS: safeSrc)
            : safeSrc
        syncDisplayLinkState()

#if !targetEnvironment(simulator)
        if isInterpolationEnabled,
           currentURL != nil,
           !isPaused,
           !isLoadingPipeline,
           errorMessage == nil,
           !readIsReaderEOF() {
            let resolvedTargetFPS = targetFPS.effectiveTargetFPS(sourceFPS: safeSrc)
            let newLimits = OpticalFlowResolutionPlanner.recommendedQueueLimits(targetFPS: resolvedTargetFPS)
            if newLimits.maxQueued > readMaxQueuedFrames() {
                updateQueueLimits(maxQueued: newLimits.maxQueued, prebuffer: newLimits.prebuffer)
            }
            enqueuePendingUserSwitch(target: targetFPS, spatial2x: allowedSpatial)
            appendLog("[ane][switch] 请求在线切换目标档位: \(targetFPS.shortBadge) (spatial2x=\(allowedSpatial))")
            return
        }
#endif

        if let url = currentURL {
            load(
                url: url,
                spatial2x: spatial2x,
                targetFPS: targetFPS,
                startAt: currentTime,
                autoPlay: !isPaused,
                enableInterpolation: isInterpolationEnabled
            )
        }
    }

    private func readPrebufferFrameTarget() -> Int {
        bufferLock.lock()
        let value = prebufferFrameTarget
        bufferLock.unlock()
        return value
    }

    private func enqueueDecodedFrame(pts: Double, buffer: CVPixelBuffer) {
        bufferLock.lock()
        frameQueue.append((pts: pts, buffer: buffer))
        if pts > lastEnqueuedPTS {
            lastEnqueuedPTS = pts
        }
        bufferLock.unlock()
    }

    private func markReaderEOF() {
        bufferLock.lock()
        isReaderEOF = true
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
    private static func queryDimensionBounds(
        for configType: any VTFrameProcessorConfiguration.Type
    ) -> OpticalFlowResolutionPlanner.DimensionBounds? {
        let minDims = configType.minimumDimensions
        let maxDims = configType.maximumDimensions
        guard minDims != nil || maxDims != nil else { return nil }
        return OpticalFlowResolutionPlanner.DimensionBounds(
            minWidth: Int(minDims?.width ?? 0),
            minHeight: Int(minDims?.height ?? 0),
            maxWidth: Int(maxDims?.width ?? 0),
            maxHeight: Int(maxDims?.height ?? 0)
        )
    }

    private static func formatDimensionBounds(_ bounds: OpticalFlowResolutionPlanner.DimensionBounds?) -> String {
        guard let bounds else { return "none" }
        return "\(bounds.minWidth)x\(bounds.minHeight)..\(bounds.maxWidth)x\(bounds.maxHeight)"
    }

    private func buildCandidatePlanForDevice(
        sourceWidth: Int,
        sourceHeight: Int,
        requestedSpatial2x: Bool,
        targetFPS: OpticalFlowTargetFPS,
        sourceFPS: Double
    ) -> [OpticalFlowCandidate] {
        let lowLatencySupported = VTLowLatencyFrameInterpolationConfiguration.isSupported
        let frcSupported = VTFrameRateConversionConfiguration.isSupported
        let llBounds = Self.queryDimensionBounds(for: VTLowLatencyFrameInterpolationConfiguration.self)
        let frcBounds = Self.queryDimensionBounds(for: VTFrameRateConversionConfiguration.self)
        let preferFRC = false
        let maxInterp = max(1, targetFPS.maxInterpolatedFramesPerPair(sourceFPS: sourceFPS))
        let allowSpatial = requestedSpatial2x && targetFPS.allowsSpatial2x
        let plan = OpticalFlowResolutionPlanner.buildCandidatePlan(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            requestedSpatial2x: allowSpatial,
            lowLatencySupported: lowLatencySupported,
            frcSupported: frcSupported,
            lowLatencyBounds: llBounds,
            frcBounds: frcBounds,
            preferFRC: preferFRC,
            maxInterpolatedFrames: maxInterp
        )
        let labels = plan.map(\.displayLabel).joined(separator: ", ")
        logAsync("[ane] 双后端探测: target=\(targetFPS.shortBadge)(preferFRC=\(preferFRC), maxInterp=\(maxInterp)), LowLatency=\(lowLatencySupported)(bounds=\(Self.formatDimensionBounds(llBounds))), FRC=\(frcSupported)(bounds=\(Self.formatDimensionBounds(frcBounds))), 候选=[\(labels)]")
        return plan
    }

    private func instantiateConfiguration(for candidate: OpticalFlowCandidate) -> ActiveOpticalFlowConfiguration? {
        switch candidate.backend {
        case .lowLatency:
            if candidate.spatial2x {
                guard let cfg = VTLowLatencyFrameInterpolationConfiguration(
                    frameWidth: candidate.width,
                    frameHeight: candidate.height,
                    spatialScaleFactor: 2
                ) else {
                    return nil
                }
                return .lowLatency(cfg)
            }
            let exponent = OpticalFlowResolutionPlanner.lowLatencyExponent(
                forInterpolatedFrames: candidate.maxInterpolatedFrames
            )
            guard let cfg = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: candidate.width,
                frameHeight: candidate.height,
                numberOfInterpolatedFrames: exponent
            ) else {
                return nil
            }
            return .lowLatency(cfg)
        case .frameRateConversion:
            guard let cfg = VTFrameRateConversionConfiguration(
                frameWidth: candidate.width,
                frameHeight: candidate.height,
                usePrecomputedFlow: false,
                qualityPrioritization: .normal,
                revision: VTFrameRateConversionConfiguration.defaultRevision
            ) else {
                return nil
            }
            return .frameRateConversion(cfg)
        }
    }

    private func activateCandidate(
        in candidates: [OpticalFlowCandidate],
        startingAt startIndex: Int,
        prefer10Bit: Bool
    ) -> ActivatedOpticalFlowSession? {
        guard startIndex < candidates.count else { return nil }
        for index in startIndex..<candidates.count {
            let candidate = candidates[index]
            guard let config = instantiateConfiguration(for: candidate) else {
                logAsync("[ane][warn] 候选 \(candidate.displayLabel) 配置构造返回 nil，跳过")
                continue
            }

            let processor = VTFrameProcessor()
            do {
                try config.startSession(on: processor)
            } catch {
                processor.endSession()
                logAsync("[ane][warn] 候选 \(candidate.displayLabel) startSession 失败: \(Self.formatDetailedError(error))")
                continue
            }

            let pixelFormat = resolveSourcePixelFormat(from: config, prefer10Bit: prefer10Bit)
            let isHeavy = OpticalFlowResolutionPlanner.isHeavyPixelFormat(pixelFormat)
            let hasSmaller720Candidate = candidates[(index + 1)...].contains {
                max($0.width, $0.height) <= 1280 && min($0.width, $0.height) <= 720
            }
            if candidate.backend == .frameRateConversion
                && candidate.maxInterpolatedFrames > 1
                && isHeavy
                && (max(candidate.width, candidate.height) > 1280 || min(candidate.width, candidate.height) > 720)
                && hasSmaller720Candidate {
                processor.endSession()
                logAsync("[ane][perf] FRC 多相插帧仅支持高带宽格式 \(Self.fourCCString(pixelFormat))，跳过 1080p 直接从 720p 候选起跑")
                continue
            }

            let sourceNormPool = try? makeSourceNormalizationPool(
                configuration: config,
                width: candidate.width,
                height: candidate.height,
                pixelFormat: pixelFormat,
                prefer10Bit: prefer10Bit
            )
            var sourceTransferSession: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &sourceTransferSession)

            let destPool: CVPixelBufferPool
            do {
                destPool = try makeDestinationPool(
                    configuration: config,
                    fallbackWidth: candidate.spatial2x ? candidate.width * 2 : candidate.width,
                    fallbackHeight: candidate.spatial2x ? candidate.height * 2 : candidate.height,
                    fallbackFormat: pixelFormat,
                    prefer10Bit: prefer10Bit
                )
            } catch {
                processor.endSession()
                if let sourceTransferSession {
                    VTPixelTransferSessionInvalidate(sourceTransferSession)
                }
                logAsync("[ane][warn] 候选 \(candidate.displayLabel) 目标池创建失败: \(Self.formatDetailedError(error))")
                continue
            }

            var transferSession: VTPixelTransferSession?
            if candidate.spatial2x {
                VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transferSession)
            }

            return ActivatedOpticalFlowSession(
                candidateIndex: index,
                candidate: candidate,
                configuration: config,
                processor: processor,
                pixelFormat: pixelFormat,
                sourceNormPool: sourceNormPool,
                sourceTransferSession: sourceTransferSession,
                destPool: destPool,
                transferSession: transferSession
            )
        }
        return nil
    }

    private func applyActivatedSession(
        _ activated: ActivatedOpticalFlowSession,
        to state: OpticalFlowPipelineState,
        token: UUID,
        reason: String
    ) {
        state.cleanup()
        state.configuration = activated.configuration
        state.processor = activated.processor
        state.candidateIndex = activated.candidateIndex
        state.activeCandidate = activated.candidate
        state.activeWidth = activated.candidate.width
        state.activeHeight = activated.candidate.height
        state.activeSpatial2x = activated.candidate.spatial2x
        state.pixelFormat = activated.pixelFormat
        state.sourceNormPool = activated.sourceNormPool
        state.sourceTransferSession = activated.sourceTransferSession
        state.destPool = activated.destPool
        state.transferSession = activated.transferSession
        state.previousBuffer = nil
        state.previousPTS = .invalid
        state.totalInterpolationMs = 0
        state.localBatchCount = 0
        state.localConsecutiveFailures = 0
        state.didRetryWithNormalizationOnCurrentCandidate = false
        state.frcNeedsRandomSubmission = true
        state.forceNormalizeSource = (state.sourceWidth != activated.candidate.width || state.sourceHeight != activated.candidate.height)

        Task { @MainActor [weak self] in
            guard let self, self.isTokenValid(token) else { return }
            self.activeBackendLabel = activated.candidate.displayLabel
            self.enableSpatial2xUpscale = activated.candidate.spatial2x
        }
        logAsync("[ane] 激活光流后端(\(reason)): \(activated.candidate.displayLabel), pixFmt=\(Self.fourCCString(activated.pixelFormat)), forceNorm=\(state.forceNormalizeSource)")
    }

    private func canDowngradeResolution(in state: OpticalFlowPipelineState) -> Bool {
        let currentArea = state.activeWidth * state.activeHeight
        let nextStart = state.candidateIndex + 1
        guard nextStart < state.candidates.count else { return false }
        return state.candidates[nextStart...].contains { ($0.width * $0.height) < currentArea }
    }

    private func downgradeResolutionIfPossible(
        state: OpticalFlowPipelineState,
        token: UUID,
        reason: String
    ) -> Bool {
        let currentArea = state.activeWidth * state.activeHeight
        let nextStart = state.candidateIndex + 1
        guard nextStart < state.candidates.count,
              let targetIdx = state.candidates[nextStart...].firstIndex(where: { ($0.width * $0.height) < currentArea }),
              let activated = activateCandidate(
                  in: state.candidates,
                  startingAt: targetIdx,
                  prefer10Bit: state.prefer10Bit
              ) else {
            return false
        }
        logAsync("[ane][budget] \(reason): \(state.activeCandidate.displayLabel) -> \(activated.candidate.displayLabel)")
        applyActivatedSession(activated, to: state, token: token, reason: reason)
        let resolvedTargetFPS = state.activeTargetFPS.effectiveTargetFPS(sourceFPS: state.sourceFPS)
        let queueLimits = OpticalFlowResolutionPlanner.recommendedQueueLimits(
            targetFPS: resolvedTargetFPS,
            isHeavyPixelFormat: OpticalFlowResolutionPlanner.isHeavyPixelFormat(activated.pixelFormat)
        )
        updateQueueLimits(maxQueued: queueLimits.maxQueued, prebuffer: queueLimits.prebuffer)
        state.phaseScheduler.reset()
        state.awaitingClockCatchUpAfterSwitch = true
        return true
    }

    private func canDowngradeTargetFPS(in state: OpticalFlowPipelineState) -> Bool {
        state.activeTargetFPS.nextLowerTier != nil
    }

    private func downgradeTargetFPSIfPossible(
        state: OpticalFlowPipelineState,
        token: UUID,
        reason: String
    ) -> Bool {
        var nextTierOpt = state.activeTargetFPS.nextLowerTier
        while let tier = nextTierOpt {
            if downgradeTargetFPS(to: tier, state: state, token: token, reason: reason) {
                return true
            }
            nextTierOpt = tier.nextLowerTier
        }
        return false
    }

    private func downgradeTargetFPS(
        to targetTier: OpticalFlowTargetFPS,
        state: OpticalFlowPipelineState,
        token: UUID,
        reason: String
    ) -> Bool {
        var candidateTierOpt: OpticalFlowTargetFPS? = targetTier
        while let tier = candidateTierOpt {
            let tierCandidates = buildCandidatePlanForDevice(
                sourceWidth: state.sourceWidth,
                sourceHeight: state.sourceHeight,
                requestedSpatial2x: false,
                targetFPS: tier,
                sourceFPS: state.sourceFPS
            )
            if let activated = activateCandidate(
                in: tierCandidates,
                startingAt: 0,
                prefer10Bit: state.prefer10Bit
            ) {
                let previousTier = state.activeTargetFPS
                let resolvedTargetFPS = tier.effectiveTargetFPS(sourceFPS: state.sourceFPS)
                let queueLimits = OpticalFlowResolutionPlanner.recommendedQueueLimits(
                    targetFPS: resolvedTargetFPS,
                    isHeavyPixelFormat: OpticalFlowResolutionPlanner.isHeavyPixelFormat(activated.pixelFormat)
                )
                updateQueueLimits(maxQueued: queueLimits.maxQueued, prebuffer: queueLimits.prebuffer)
                state.candidates = tierCandidates
                state.activeTargetFPS = tier
                state.phaseScheduler = OpticalFlowPhaseScheduler(targetTier: tier, sourceFPS: state.sourceFPS)
                state.awaitingClockCatchUpAfterSwitch = true
                applyActivatedSession(activated, to: state, token: token, reason: reason)
                Task { @MainActor [weak self] in
                    guard let self, self.isTokenValid(token) else { return }
                    self.effectiveTargetFPS = tier
                    self.interpolatedFPS = resolvedTargetFPS
                    self.syncDisplayLinkState()
                }
                logAsync("[ane][budget] \(reason): 目标帧率 \(previousTier.shortBadge) -> \(tier.shortBadge) (\(activated.candidate.displayLabel))")
                return true
            }
            candidateTierOpt = tier.nextLowerTier
        }
        return false
    }

    private func recordInterpolationFailure(
        _ reason: String,
        consecutiveFailures: Int,
        totalSuccesses: Int,
        suppressErrorBanner: Bool = false
    ) {
        let shouldSurfaceError = !suppressErrorBanner && (totalSuccesses == 0 && consecutiveFailures >= 5)
        if consecutiveFailures == 1 || consecutiveFailures == 5 || (consecutiveFailures > 5 && consecutiveFailures % 50 == 0) {
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
        from configuration: ActiveOpticalFlowConfiguration,
        prefer10Bit: Bool
    ) -> OSType {
        let raw = configuration.sourcePixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String]
        if let num = raw as? NSNumber {
            return num.uint32Value
        }
        if let arr = raw as? [NSNumber] {
            let supported = arr.map(\.uint32Value)
            return OpticalFlowResolutionPlanner.selectOptimalPixelFormat(from: supported, prefer10Bit: prefer10Bit)
        }
        return prefer10Bit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    private func applyUserSwitchInPlace(
        target: OpticalFlowTargetFPS,
        requestedSpatial2x: Bool,
        state: OpticalFlowPipelineState,
        token: UUID
    ) {
        let is4K = SuperResolutionPolicy.isAlready4K(width: state.sourceWidth, height: state.sourceHeight)
        var effectiveRequestedTarget = target
        let currentThermal = ProcessInfo.processInfo.thermalState
        let currentLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        state.lastObservedThermalState = currentThermal
        state.lastObservedLowPowerMode = currentLowPower
        if let cap = OpticalFlowResolutionPlanner.effectivePowerThermalCap(
            active: target,
            thermalState: currentThermal,
            isLowPowerMode: currentLowPower
        ) {
            effectiveRequestedTarget = cap.tier
            logAsync("[ane][power] \(cap.reason)，切档目标从 \(target.shortBadge) 限档为 \(cap.tier.shortBadge)")
        }
        let allowedSpatial = requestedSpatial2x && effectiveRequestedTarget.allowsSpatial2x && !is4K
        state.requestedTargetFPS = target
        state.requestedSpatial2x = allowedSpatial
        state.interpolationExhausted = false
        state.budgetGuard.reset()
        state.localConsecutiveFailures = 0
        state.didLogCatchUp = false

        var candidateTierOpt: OpticalFlowTargetFPS? = effectiveRequestedTarget
        while let tier = candidateTierOpt {
            let tierSpatial2x = allowedSpatial && tier.allowsSpatial2x
            let tierCandidates = buildCandidatePlanForDevice(
                sourceWidth: state.sourceWidth,
                sourceHeight: state.sourceHeight,
                requestedSpatial2x: tierSpatial2x,
                targetFPS: tier,
                sourceFPS: state.sourceFPS
            )
            if let activated = activateCandidate(
                in: tierCandidates,
                startingAt: 0,
                prefer10Bit: state.prefer10Bit
            ) {
                let resolvedTargetFPS = tier.effectiveTargetFPS(sourceFPS: state.sourceFPS)
                let queueLimits = OpticalFlowResolutionPlanner.recommendedQueueLimits(
                    targetFPS: resolvedTargetFPS,
                    isHeavyPixelFormat: OpticalFlowResolutionPlanner.isHeavyPixelFormat(activated.pixelFormat)
                )
                updateQueueLimits(maxQueued: queueLimits.maxQueued, prebuffer: queueLimits.prebuffer)
                state.candidates = tierCandidates
                state.activeTargetFPS = tier
                state.phaseScheduler = OpticalFlowPhaseScheduler(targetTier: tier, sourceFPS: state.sourceFPS)
                state.awaitingClockCatchUpAfterSwitch = true
                pruneExpiredFrames(before: readLatestAudioTime() - 0.02)
                applyActivatedSession(activated, to: state, token: token, reason: "在线档位切换")
                Task { @MainActor [weak self] in
                    guard let self, self.isTokenValid(token) else { return }
                    self.effectiveTargetFPS = tier
                    self.interpolatedFPS = resolvedTargetFPS
                    self.enableSpatial2xUpscale = activated.candidate.spatial2x
                    self.syncDisplayLinkState()
                }
                logAsync("[ane][switch] 在线切换光流档位 -> \(tier.shortBadge) (\(activated.candidate.displayLabel))")
                return
            }
            candidateTierOpt = tier.nextLowerTier
        }
    }

    private func processDecodedFrame(
        _ frameBox: SendablePixelBuffer,
        currentPTS: CMTime,
        state: OpticalFlowPipelineState,
        token: UUID,
        pairActiveMs: Double = 0
    ) async throws {
        guard isTokenValid(token) else { return }
        let currentBuffer = frameBox.buffer
        inspectDecodedBufferColorOnceIfNeeded(currentBuffer, token: token)

        if let pendingSwitch = takePendingUserSwitch() {
            applyUserSwitchInPlace(
                target: pendingSwitch.target,
                requestedSpatial2x: pendingSwitch.spatial2x,
                state: state,
                token: token
            )
        }

        if !state.didCheckActualDimensions {
            state.didCheckActualDimensions = true
            let actualW = CVPixelBufferGetWidth(currentBuffer)
            let actualH = CVPixelBufferGetHeight(currentBuffer)
            let actualFmt = CVPixelBufferGetPixelFormatType(currentBuffer)
            state.forceNormalizeSource = state.forceNormalizeSource
                || (actualW != state.activeWidth || actualH != state.activeHeight)
                || (actualFmt != state.pixelFormat)
            let matchesExpectedScaled = state.expectedDecodeDimensions.map {
                $0.width == actualW && $0.height == actualH
            } ?? false
            if !matchesExpectedScaled,
               actualW >= 2,
               actualH >= 2,
               (actualW != state.sourceWidth || actualH != state.sourceHeight) {
                logAsync("[ane] 实际解码缓冲尺寸 \(actualW)×\(actualH) 与轨道声明 \(state.sourceWidth)×\(state.sourceHeight) 不一致，重新规划光流候选")
                state.sourceWidth = actualW
                state.sourceHeight = actualH
                let rebuiltSpatial2x = state.requestedSpatial2x
                    && state.activeTargetFPS.allowsSpatial2x
                    && !SuperResolutionPolicy.isAlready4K(width: actualW, height: actualH)
                let newPlan = buildCandidatePlanForDevice(
                    sourceWidth: actualW,
                    sourceHeight: actualH,
                    requestedSpatial2x: rebuiltSpatial2x,
                    targetFPS: state.activeTargetFPS,
                    sourceFPS: state.sourceFPS
                )
                if let firstNew = newPlan.first, firstNew != state.activeCandidate {
                    if let rebuilt = activateCandidate(
                        in: newPlan,
                        startingAt: 0,
                        prefer10Bit: state.prefer10Bit
                    ) {
                        state.candidates = newPlan
                        applyActivatedSession(rebuilt, to: state, token: token, reason: "实测尺寸重规划")
                        state.phaseScheduler.reset()
                    }
                } else {
                    state.forceNormalizeSource = state.forceNormalizeSource || (actualW != state.activeWidth || actualH != state.activeHeight)
                }
            }
        }

        let currentThermal = ProcessInfo.processInfo.thermalState
        let currentLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if currentThermal != state.lastObservedThermalState || currentLowPower != state.lastObservedLowPowerMode {
            state.lastObservedThermalState = currentThermal
            state.lastObservedLowPowerMode = currentLowPower
            if let cap = OpticalFlowResolutionPlanner.effectivePowerThermalCap(
                active: state.activeTargetFPS,
                thermalState: currentThermal,
                isLowPowerMode: currentLowPower
            ) {
                logAsync("[ane][power] \(cap.reason)，主动将目标帧率限档至 \(cap.tier.shortBadge)")
                _ = downgradeTargetFPS(
                    to: cap.tier,
                    state: state,
                    token: token,
                    reason: cap.reason
                )
            }
            if currentThermal == .critical && canDowngradeResolution(in: state) {
                _ = downgradeResolutionIfPossible(
                    state: state,
                    token: token,
                    reason: "严重过热降分辨率"
                )
            }
        }

        let preNormalizeCandidate = state.activeCandidate
        let preNormalizePixelFormat = state.pixelFormat
        let workingBuffer = normalizeSourceBufferIfNeeded(
            currentBuffer,
            targetWidth: state.activeWidth,
            targetHeight: state.activeHeight,
            targetPixelFormat: state.pixelFormat,
            forceNormalize: state.forceNormalizeSource,
            transferSession: state.sourceTransferSession,
            pool: state.sourceNormPool
        )

        var shouldEmitOriginalFrame = true
        let latestAudioNow = readLatestAudioTime()
        if !state.isCatchingUpToClock
            && state.didStartAudioClock
            && !state.awaitingClockCatchUpAfterSwitch
            && (currentPTS.seconds < latestAudioNow - 0.045) {
            state.isCatchingUpToClock = true
        } else if state.isCatchingUpToClock && currentPTS.seconds >= latestAudioNow + 0.085 {
            state.isCatchingUpToClock = false
        }
        let behindAudioClock = state.isCatchingUpToClock
        if behindAudioClock {
            state.frcNeedsRandomSubmission = true
            state.phaseScheduler.reset()
            if !state.didLogCatchUp {
                state.didLogCatchUp = true
                logAsync("[ane][perf] 光流处理落后时钟，临时跳过部分帧插帧以保持音画同步")
            }
            Task { @MainActor [weak self] in
                self?.skippedInterpolationCount += 1
            }
            if !state.awaitingClockCatchUpAfterSwitch,
               !state.interpolationExhausted,
               state.previousPTS.isValid,
               currentPTS > state.previousPTS {
                let deltaMs = max(4.0, (currentPTS.seconds - state.previousPTS.seconds) * 1000.0)
                let action = state.budgetGuard.recordPair(
                    processMs: 0,
                    sourceIntervalMs: deltaMs,
                    skippedForCatchUp: true,
                    canDowngradeResolution: canDowngradeResolution(in: state),
                    canDowngradeTargetFPS: canDowngradeTargetFPS(in: state)
                )
                switch action {
                case .keep:
                    break
                case .downgradeResolution:
                    _ = downgradeResolutionIfPossible(state: state, token: token, reason: "追帧跳过降分辨率")
                case .downgradeTargetFPS:
                    _ = downgradeTargetFPSIfPossible(state: state, token: token, reason: "追帧跳过降目标帧率")
                }
            }
        } else {
            state.awaitingClockCatchUpAfterSwitch = false
            if !state.interpolationExhausted,
               let prevBuf = state.previousBuffer,
               state.previousPTS.isValid,
               currentPTS > state.previousPTS,
               Self.isValidInterpolationDelta(currentPTS.seconds - state.previousPTS.seconds) {
            let deltaSeconds = currentPTS.seconds - state.previousPTS.seconds
            let step = state.phaseScheduler.planStep(
                previousPTS: state.previousPTS.seconds,
                currentPTS: currentPTS.seconds,
                maxAllowedSlots: state.activeCandidate.maxInterpolatedFrames
            )
            if step.interpolatedSlots.isEmpty {
                shouldEmitOriginalFrame = step.shouldEmitOriginalFrame
            } else if let prevFrame = VTFrameProcessorFrame(buffer: prevBuf, presentationTimeStamp: state.previousPTS),
                      let currFrame = VTFrameProcessorFrame(buffer: workingBuffer, presentationTimeStamp: currentPTS) {
                var phases: [Float] = []
                var destBuffers: [CVPixelBuffer] = []
                var destFrames: [VTFrameProcessorFrame] = []
                var allocErrorMessage: String?

                phases.reserveCapacity(step.interpolatedSlots.count)
                destBuffers.reserveCapacity(step.interpolatedSlots.count)
                destFrames.reserveCapacity(step.interpolatedSlots.count)

                for slot in step.interpolatedSlots {
                    var destBufOpt: CVPixelBuffer?
                    let poolStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, state.destPool, &destBufOpt)
                    guard poolStatus == kCVReturnSuccess, let destBuf = destBufOpt else {
                        allocErrorMessage = "CVPixelBufferPoolCreatePixelBuffer 失败 (\(poolStatus))"
                        break
                    }
                    let slotPTS = CMTime(seconds: slot.pts, preferredTimescale: 600)
                    guard let destFrame = VTFrameProcessorFrame(buffer: destBuf, presentationTimeStamp: slotPTS) else {
                        allocErrorMessage = "VTFrameProcessorFrame(destFrame) 初始化返回 nil"
                        break
                    }
                    phases.append(slot.phase)
                    destBuffers.append(destBuf)
                    destFrames.append(destFrame)
                }

                if let allocErrorMessage {
                    state.localConsecutiveFailures += 1
                    state.frcNeedsRandomSubmission = true
                    state.phaseScheduler.reset()
                    recordInterpolationFailure(
                        allocErrorMessage,
                        consecutiveFailures: state.localConsecutiveFailures,
                        totalSuccesses: state.localSuccessCount
                    )
                } else {
                    do {
                        let processStart = CACurrentMediaTime()
                        switch state.configuration {
                        case .lowLatency:
                            guard let params = VTLowLatencyFrameInterpolationParameters(
                                sourceFrame: currFrame,
                                previousFrame: prevFrame,
                                interpolationPhase: phases,
                                destinationFrames: destFrames
                            ) else {
                                throw NSError(domain: "GlassMPV.OpticalFlow", code: -301, userInfo: [
                                    NSLocalizedDescriptionKey: "VTLowLatencyFrameInterpolationParameters 初始化返回 nil"
                                ])
                            }
                            _ = try await state.processor.process(parameters: params)
                        case .frameRateConversion:
                            let submissionMode: VTFrameRateConversionParameters.SubmissionMode = state.frcNeedsRandomSubmission ? .random : .sequential
                            guard let params = VTFrameRateConversionParameters(
                                sourceFrame: prevFrame,
                                nextFrame: currFrame,
                                opticalFlow: nil,
                                interpolationPhase: phases,
                                submissionMode: submissionMode,
                                destinationFrames: destFrames
                            ) else {
                                throw NSError(domain: "GlassMPV.OpticalFlow", code: -302, userInfo: [
                                    NSLocalizedDescriptionKey: "VTFrameRateConversionParameters 初始化返回 nil"
                                ])
                            }
                            _ = try await state.processor.process(parameters: params)
                            state.frcNeedsRandomSubmission = false
                        }

                        let elapsedMs = (CACurrentMediaTime() - processStart) * 1000.0
                        state.totalInterpolationMs += elapsedMs
                        for (slot, destBuf) in zip(step.interpolatedSlots, destBuffers) {
                            CVBufferPropagateAttachments(workingBuffer, destBuf)
                            enqueueDecodedFrame(pts: slot.pts, buffer: destBuf)
                        }
                        let generatedCount = step.interpolatedSlots.count
                        state.localBatchCount += 1
                        state.localSuccessCount += generatedCount
                        state.localConsecutiveFailures = 0
                        let avgMs = state.totalInterpolationMs / Double(max(1, state.localBatchCount))
                        if state.localBatchCount == 1 {
                            logAsync("[ane] 首帧光流补帧成功（\(state.activeCandidate.displayLabel), target=\(state.activeTargetFPS.shortBadge), 生成 \(generatedCount) 帧, 耗时 \(String(format: "%.1f", elapsedMs))ms）")
                        }
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.interpolatedFrameCount += generatedCount
                            self.averageInterpolationMs = avgMs
                        }
                        shouldEmitOriginalFrame = step.shouldEmitOriginalFrame

                        let pairCycleMs = max(elapsedMs, pairActiveMs)
                        let budgetAction = state.budgetGuard.recordPair(
                            processMs: pairCycleMs,
                            sourceIntervalMs: deltaSeconds * 1000.0,
                            skippedForCatchUp: false,
                            canDowngradeResolution: canDowngradeResolution(in: state),
                            canDowngradeTargetFPS: canDowngradeTargetFPS(in: state)
                        )
                        switch budgetAction {
                        case .keep:
                            break
                        case .downgradeResolution:
                            _ = downgradeResolutionIfPossible(state: state, token: token, reason: "算力预算超限降分辨率")
                        case .downgradeTargetFPS:
                            _ = downgradeTargetFPSIfPossible(state: state, token: token, reason: "算力预算超限降目标帧率")
                        }
                    } catch {
                        state.phaseScheduler.reset()
                        let detailed = Self.formatDetailedError(error)
                        if state.localSuccessCount == 0 {
                            if !state.forceNormalizeSource && !state.didRetryWithNormalizationOnCurrentCandidate && state.sourceNormPool != nil {
                                state.forceNormalizeSource = true
                                state.didRetryWithNormalizationOnCurrentCandidate = true
                                state.frcNeedsRandomSubmission = true
                                state.localConsecutiveFailures += 1
                                logAsync("[ane][warn] 候选 \(state.activeCandidate.displayLabel) 首帧异常，自动启用源帧标准化池重试: \(detailed)")
                                recordInterpolationFailure(
                                    "process 异常(标准化重试): \(detailed)",
                                    consecutiveFailures: state.localConsecutiveFailures,
                                    totalSuccesses: state.localSuccessCount,
                                    suppressErrorBanner: true
                                )
                            } else if let nextActivated = activateCandidate(
                                in: state.candidates,
                                startingAt: state.candidateIndex + 1,
                                prefer10Bit: state.prefer10Bit
                            ) {
                                logAsync("[ane][fallback] 候选 \(state.activeCandidate.displayLabel) 运行期失败（\(detailed)），自动切换至 \(nextActivated.candidate.displayLabel)")
                                applyActivatedSession(nextActivated, to: state, token: token, reason: "运行期自愈")
                                recordInterpolationFailure(
                                    "切换候选自愈(\(nextActivated.candidate.displayLabel)): \(detailed)",
                                    consecutiveFailures: 1,
                                    totalSuccesses: state.localSuccessCount,
                                    suppressErrorBanner: true
                                )
                            } else if downgradeTargetFPSIfPossible(
                                state: state,
                                token: token,
                                reason: "首帧全候选失败降档"
                            ) {
                                recordInterpolationFailure(
                                    "降档目标帧率自愈(\(state.activeTargetFPS.shortBadge)): \(detailed)",
                                    consecutiveFailures: 1,
                                    totalSuccesses: state.localSuccessCount,
                                    suppressErrorBanner: true
                                )
                            } else {
                                state.interpolationExhausted = true
                                state.localConsecutiveFailures += 1
                                logAsync("[ane][error] 全部 \(state.candidates.count) 个光流候选及降档均失败，已熔断降级为原帧硬解直通: \(detailed)")
                                Task { @MainActor [weak self] in
                                    guard let self, self.isTokenValid(token) else { return }
                                    self.activeBackendLabel = "已降级直通"
                                    self.failedInterpolationCount += 1
                                    self.lastInterpolationError = detailed
                                    self.isLoadingPipeline = false
                                    self.pipelineStatusText = ""
                                    if self.errorMessage == nil {
                                        self.errorMessage = "ANE 光流全档位不可用（\(detailed)），可点击「以原帧率直通重试」。"
                                    }
                                }
                            }
                        } else {
                            state.localConsecutiveFailures += 1
                            state.frcNeedsRandomSubmission = true
                            recordInterpolationFailure(
                                "process 异常: \(detailed)",
                                consecutiveFailures: state.localConsecutiveFailures,
                                totalSuccesses: state.localSuccessCount
                            )
                        }
                    }
                }
            } else {
                state.localConsecutiveFailures += 1
                state.frcNeedsRandomSubmission = true
                state.phaseScheduler.reset()
                recordInterpolationFailure(
                    "VTFrameProcessorFrame(prev/curr) 初始化返回 nil",
                    consecutiveFailures: state.localConsecutiveFailures,
                    totalSuccesses: state.localSuccessCount
                )
            }
            }
        }

        let candidateChangedMidFrame = (state.activeCandidate != preNormalizeCandidate)
            || (state.pixelFormat != preNormalizePixelFormat)
        let workingMatchesActive = (CVPixelBufferGetWidth(workingBuffer) == state.activeWidth)
            && (CVPixelBufferGetHeight(workingBuffer) == state.activeHeight)
            && (CVPixelBufferGetPixelFormatType(workingBuffer) == state.pixelFormat)
            && (CVPixelBufferGetIOSurface(workingBuffer) != nil)
        let finalSourceBuffer: CVPixelBuffer
        if candidateChangedMidFrame || !workingMatchesActive {
            let sourceToAlign = candidateChangedMidFrame ? currentBuffer : workingBuffer
            finalSourceBuffer = normalizeSourceBufferIfNeeded(
                sourceToAlign,
                targetWidth: state.activeWidth,
                targetHeight: state.activeHeight,
                targetPixelFormat: state.pixelFormat,
                forceNormalize: true,
                transferSession: state.sourceTransferSession,
                pool: state.sourceNormPool
            )
        } else {
            finalSourceBuffer = workingBuffer
        }
        let outputBuffer = scaleIfNeeded(
            finalSourceBuffer,
            spatial2x: state.activeSpatial2x,
            transferSession: state.transferSession,
            pool: state.destPool
        )
        var cachedFirstFrame = false
        if !state.didCachePendingFirstFrame {
            state.didCachePendingFirstFrame = true
            cachedFirstFrame = true
            cachePendingFirstFrame(outputBuffer, ptsSeconds: currentPTS.seconds)
            let previewPTS = currentPTS.seconds
            let previewBox = SendablePixelBuffer(buffer: outputBuffer)
            Task { @MainActor [weak self] in
                guard let self,
                      self.isTokenValid(token),
                      self.isPaused,
                      self.presentedFrameCount == 0,
                      let layer = self.displayLayer else { return }
                self.presentFrame(previewBox.buffer, ptsSeconds: previewPTS, on: layer)
            }
        }
        if shouldEmitOriginalFrame || cachedFirstFrame {
            enqueueDecodedFrame(pts: currentPTS.seconds, buffer: outputBuffer)
        }
        if !state.didStartAudioClock && queuedCount() >= readPrebufferFrameTarget() {
            state.didStartAudioClock = true
            Task { @MainActor [weak self] in
                guard let self, self.isTokenValid(token) else { return }
                self.isPipelineReadyToPlay = true
                self.pipelineStatusText = ""
                self.startActiveClockIfNeeded()
            }
        }
        state.previousBuffer = finalSourceBuffer
        state.previousPTS = currentPTS
    }

    private func makeSourceNormalizationPool(
        configuration: ActiveOpticalFlowConfiguration,
        width: Int,
        height: Int,
        pixelFormat: OSType,
        prefer10Bit: Bool
    ) throws -> CVPixelBufferPool {
        var attrs: [String: Any] = [:]
        for (k, v) in configuration.sourcePixelBufferAttributes {
            attrs[k] = v
        }
        attrs[kCVPixelBufferWidthKey as String] = width
        attrs[kCVPixelBufferHeightKey as String] = height
        if let rawFmt = attrs[kCVPixelBufferPixelFormatTypeKey as String],
           let arr = rawFmt as? [NSNumber] {
            let targetNum = NSNumber(value: pixelFormat)
            if arr.contains(targetNum) {
                attrs[kCVPixelBufferPixelFormatTypeKey as String] = targetNum
            } else {
                let best = OpticalFlowResolutionPlanner.selectOptimalPixelFormat(
                    from: arr.map(\.uint32Value),
                    prefer10Bit: prefer10Bit
                )
                attrs[kCVPixelBufferPixelFormatTypeKey as String] = NSNumber(value: best)
            }
        } else {
            attrs[kCVPixelBufferPixelFormatTypeKey as String] = pixelFormat
        }
        if attrs[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
            attrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
        }
        if attrs[kCVPixelBufferMetalCompatibilityKey as String] == nil {
            attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
        }

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw NSError(domain: "GlassMPV.OpticalFlow", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "无法创建源帧标准化 CVPixelBufferPool (\(status))"
            ])
        }
        return pool
    }

    private func normalizeSourceBufferIfNeeded(
        _ buffer: CVPixelBuffer,
        targetWidth: Int,
        targetHeight: Int,
        targetPixelFormat: OSType,
        forceNormalize: Bool,
        transferSession: VTPixelTransferSession?,
        pool: CVPixelBufferPool?
    ) -> CVPixelBuffer {
        let currentW = CVPixelBufferGetWidth(buffer)
        let currentH = CVPixelBufferGetHeight(buffer)
        let currentFmt = CVPixelBufferGetPixelFormatType(buffer)
        let hasIOSurface = CVPixelBufferGetIOSurface(buffer) != nil
        if !forceNormalize
            && currentW == targetWidth
            && currentH == targetHeight
            && currentFmt == targetPixelFormat
            && hasIOSurface {
            return buffer
        }
        guard let transferSession, let pool else {
            return buffer
        }
        var normalizedOpt: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &normalizedOpt) == kCVReturnSuccess,
              let normalized = normalizedOpt else {
            return buffer
        }
        let status = VTPixelTransferSessionTransferImage(transferSession, from: buffer, to: normalized)
        if status == noErr {
            CVBufferPropagateAttachments(buffer, normalized)
            return normalized
        }
        return buffer
    }

    private func makeDestinationPool(
        configuration: ActiveOpticalFlowConfiguration,
        fallbackWidth: Int,
        fallbackHeight: Int,
        fallbackFormat: OSType,
        prefer10Bit: Bool
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
                } else {
                    let best = OpticalFlowResolutionPlanner.selectOptimalPixelFormat(
                        from: arr.map(\.uint32Value),
                        prefer10Bit: prefer10Bit
                    )
                    attrs[kCVPixelBufferPixelFormatTypeKey as String] = NSNumber(value: best)
                }
            }
        } else {
            attrs[kCVPixelBufferPixelFormatTypeKey as String] = fallbackFormat
        }
        if attrs[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
            attrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
        }
        if attrs[kCVPixelBufferMetalCompatibilityKey as String] == nil {
            attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
        }

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

    private func backfillHDRColorAttachmentsIfNeeded(on pixelBuffer: CVPixelBuffer) {
        let meta = readColorFallbackMetadata()
        guard meta.isHDR || meta.isDolbyVision else { return }
        if CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil) == nil {
            let primaries = meta.colorPrimaries ?? kCVImageBufferColorPrimaries_ITU_R_2020
            let transfer = meta.transferFunction ?? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            let matrix = meta.ycbcrMatrix ?? kCVImageBufferYCbCrMatrix_ITU_R_2020
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        }
        if let mdcv = meta.masteringDisplayColorVolume,
           CVBufferCopyAttachment(pixelBuffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) == nil {
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferMasteringDisplayColorVolumeKey, mdcv, .shouldPropagate)
        }
        if let clli = meta.contentLightLevelInfo,
           CVBufferCopyAttachment(pixelBuffer, kCVImageBufferContentLightLevelInfoKey, nil) == nil {
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferContentLightLevelInfoKey, clli, .shouldPropagate)
        }
    }

    func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, ptsSeconds: Double) -> CMSampleBuffer? {
        backfillHDRColorAttachmentsIfNeeded(on: pixelBuffer)
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

    private static func shouldPrefer10Bit(
        from metrics: (width: Int, height: Int, codec: String, bitDepth: String, hdrTag: String, isHDR: Bool, isDolbyVision: Bool, transferName: String?)
    ) -> Bool {
        metrics.bitDepth == "10-bit" || metrics.isHDR || metrics.isDolbyVision || metrics.hdrTag != "SDR"
    }

    private static func extractTrackMetrics(
        from formatDescription: CMFormatDescription?,
        naturalSize: CGSize
    ) -> (width: Int, height: Int, codec: String, bitDepth: String, hdrTag: String, isHDR: Bool, isDolbyVision: Bool, transferName: String?) {
        let width = Int(abs(naturalSize.width))
        let height = Int(abs(naturalSize.height))
        guard let desc = formatDescription else {
            return (width, height, "", "--", "SDR", false, false, nil)
        }

        let subType = CMFormatDescriptionGetMediaSubType(desc)
        let codec = fourCCString(subType)
        let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any]
        let atoms = extensions?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any]
        let isDolbyVision = HEVCFormatNormalizer.isDolbyVision(subType: subType, atoms: atoms)
        let transfer = extensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let transferLower = (transfer ?? "").lowercased()
        let isHDR = isDolbyVision || transferLower.contains("2084") || transferLower.contains("pq") || transferLower.contains("hlg")
        let hdrTag = PlaybackHUDMetrics.formatHDRTag(
            isHDRContent: isHDR,
            transferName: transfer,
            isHDRActive: false,
            isDolbyVision: isDolbyVision
        )

        let bitDepth: String
        if let bpc = extensions?[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int, bpc > 0 {
            bitDepth = "\(bpc)-bit"
        } else if isHDR || isDolbyVision {
            bitDepth = "10-bit"
        } else {
            bitDepth = "--"
        }

        return (width, height, codec, bitDepth, hdrTag, isHDR, isDolbyVision, transfer)
    }

    nonisolated static func formatDetailedError(_ error: Error?) -> String {
        guard let error else { return "未知错误" }
        let nsErr = error as NSError
        var parts = ["\(nsErr.domain)(\(nsErr.code)): \(nsErr.localizedDescription)"]
        if let reason = nsErr.localizedFailureReason,
           !reason.isEmpty,
           !nsErr.localizedDescription.contains(reason) {
            parts.append("reason: \(reason)")
        }
        if let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("[underlying: \(underlying.domain)(\(underlying.code)): \(underlying.localizedDescription)]")
        }
        return parts.joined(separator: " ")
    }

    nonisolated static func buildReaderSettingsTiers(
        preferredFormat: OSType,
        prefer10Bit: Bool,
        targetDimensions: (width: Int, height: Int)? = nil
    ) -> [(label: String, pixelFormat: OSType, settings: [String: Any])] {
        var tiers: [(label: String, pixelFormat: OSType, settings: [String: Any])] = []
        let ioMetalBase: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        func appendTier(
            label: String,
            format: OSType,
            includeIOMetal: Bool,
            dimensions: (width: Int, height: Int)? = nil
        ) {
            var settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format
            ]
            if let dimensions, dimensions.width >= 2, dimensions.height >= 2 {
                settings[kCVPixelBufferWidthKey as String] = dimensions.width
                settings[kCVPixelBufferHeightKey as String] = dimensions.height
            }
            if includeIOMetal {
                for (k, v) in ioMetalBase {
                    settings[k] = v
                }
                if prefer10Bit && (format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || format == kCVPixelFormatType_32BGRA) {
                    settings[AVVideoAllowWideColorKey] = true
                }
            }
            tiers.append((label: label, pixelFormat: format, settings: settings))
        }

        let format10Bit = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let format8Bit = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let initialFormat = OpticalFlowResolutionPlanner.isHeavyPixelFormat(preferredFormat)
            ? (prefer10Bit ? format10Bit : format8Bit)
            : preferredFormat

        if let targetDimensions, targetDimensions.width >= 2, targetDimensions.height >= 2 {
            appendTier(
                label: "scaled-preferred(\(fourCCString(initialFormat)))",
                format: initialFormat,
                includeIOMetal: true,
                dimensions: targetDimensions
            )
            if initialFormat != format8Bit {
                appendTier(
                    label: "scaled-420v",
                    format: format8Bit,
                    includeIOMetal: true,
                    dimensions: targetDimensions
                )
            }
        }

        appendTier(label: "preferred(\(fourCCString(initialFormat)))", format: initialFormat, includeIOMetal: true)

        if initialFormat != format8Bit {
            appendTier(label: "fallback-420v", format: format8Bit, includeIOMetal: true)
        } else if prefer10Bit {
            appendTier(label: "fallback-p010", format: format10Bit, includeIOMetal: true)
        }

        let formatBGRA = kCVPixelFormatType_32BGRA
        if initialFormat != formatBGRA {
            appendTier(label: "fallback-BGRA", format: formatBGRA, includeIOMetal: true)
        }

        appendTier(label: "minimal-420v", format: format8Bit, includeIOMetal: false)
        appendTier(label: "minimal-BGRA", format: formatBGRA, includeIOMetal: false)
        return tiers
    }

    nonisolated private static func fourCCString(_ code: FourCharCode) -> String {
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
