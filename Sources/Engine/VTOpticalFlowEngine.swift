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

/// 将 hev1 / avc3 等非苹果默认描述重写为 VideoToolbox 可直接硬解的 hvc1 / avc1 FormatDescription
enum HEVCFormatNormalizer {
    private static let safeColorExtensionKeys: [String] = [
        kCMFormatDescriptionExtension_ColorPrimaries as String,
        kCMFormatDescriptionExtension_TransferFunction as String,
        kCMFormatDescriptionExtension_YCbCrMatrix as String,
        kCMFormatDescriptionExtension_FullRangeVideo as String,
        kCMFormatDescriptionExtension_PixelAspectRatio as String,
        kCMFormatDescriptionExtension_CleanAperture as String,
        kCMFormatDescriptionExtension_BitsPerComponent as String
    ]

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
        return "fourCC=\(fourCCString(subType)), dims=\(dims.width)x\(dims.height), atoms=[\(atomKeys)], hvcC=\(hvccLen)B"
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
                candidates.append((strategy: "hvcC-to-hvc1", description: hvc1Desc))
            }

            if let parsed = parsedHVCC,
               let paramDesc = createHEVCDescription(
                   parameterSets: parsed.parameterSets,
                   nalLengthSize: parsed.nalLengthSize,
                   extensions: safeColorExtensions
               ) {
                candidates.append((strategy: "hvcc-param-sets", description: paramDesc))
            }
        }

        let isHEVC = (subType == fourCCCode("hev1") || subType == fourCCCode("hvc1") || atoms?["hvcC"] != nil)
        if isHEVC, let sampleData = fallbackSampleData, !sampleData.isEmpty {
            let nalLen = Int(parsedHVCC?.nalLengthSize ?? 4)
            let inbandSets = extractHEVCParameterSets(fromLengthPrefixed: sampleData, nalLengthSize: nalLen)
            if inbandSets.count >= 2,
               let inbandDesc = createHEVCDescription(
                   parameterSets: inbandSets,
                   nalLengthSize: Int32(nalLen),
                   extensions: safeColorExtensions
               ) {
                candidates.append((strategy: "inband-param-sets", description: inbandDesc))
            }
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
enum OpticalFlowBackendKind: String, Equatable, Sendable {
    case lowLatency = "LowLatency"
    case frameRateConversion = "FRC"
}

/// 单个分辨率 + 后端组合候选
struct OpticalFlowCandidate: Equatable, Sendable {
    let backend: OpticalFlowBackendKind
    let width: Int
    let height: Int
    let spatial2x: Bool

    var displayLabel: String {
        if spatial2x {
            return "\(backend.rawValue) \(width)×\(height)+2×"
        }
        return "\(backend.rawValue) \(width)×\(height)"
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

    static func buildCandidatePlan(
        sourceWidth: Int,
        sourceHeight: Int,
        requestedSpatial2x: Bool,
        lowLatencySupported: Bool,
        frcSupported: Bool,
        lowLatencyBounds: DimensionBounds? = nil,
        frcBounds: DimensionBounds? = nil
    ) -> [OpticalFlowCandidate] {
        guard lowLatencySupported || frcSupported else { return [] }
        let safeW = max(2, sourceWidth)
        let safeH = max(2, sourceHeight)

        let caps: [(Int, Int)] = [
            (1920, 1080),
            (1280, 720),
            (960, 540)
        ]
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
                    spatial2x: true
                )
            )
        }

        for tier in tiers {
            if lowLatencySupported,
               let bounded = clampToBounds(width: tier.width, height: tier.height, bounds: lowLatencyBounds) {
                appendCandidate(
                    OpticalFlowCandidate(
                        backend: .lowLatency,
                        width: bounded.width,
                        height: bounded.height,
                        spatial2x: false
                    )
                )
            }
            if frcSupported,
               let bounded = clampToBounds(width: tier.width, height: tier.height, bounds: frcBounds) {
                appendCandidate(
                    OpticalFlowCandidate(
                        backend: .frameRateConversion,
                        width: bounded.width,
                        height: bounded.height,
                        spatial2x: false
                    )
                )
            }
        }

        return plan
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
    let collector = VTDecodedFrameCollector()

    init(session: VTDecompressionSession, formatDescription: CMVideoFormatDescription, strategy: String) {
        self.session = session
        self.formatDescription = formatDescription
        self.strategy = strategy
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
        activeBackendLabel = "--"
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
            || VTFrameRateConversionConfiguration.isSupported
        isHardwareSupported = supported
        guard supported else {
            isLoadingPipeline = false
            pipelineStatusText = ""
            appendLog("[ane] 当前设备不支持 VTLowLatencyFrameInterpolation 或 VTFrameRateConversion")
            errorMessage = "当前设备不支持 VideoToolbox ANE 光流，请切换回「MPV 超分核」。"
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
                if let firstDesc = formatDescriptions.first {
                    self.appendLog("[ane] 轨道格式: \(HEVCFormatNormalizer.describeFormat(firstDesc))")
                }

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
                    let item: AVPlayerItem
                    if let sourceAudio = audioTracks.first {
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
                let detailed = Self.formatDetailedError(error)
                self.appendLog("[ane][error] 加载轨道信息失败: \(detailed)")
                self.errorMessage = "光流核加载失败（\(detailed)），建议切换回「MPV 超分核」。"
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
        if hadActiveSession {
            appendLog("[ane] 光流核已停止")
        }
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
        if diagnosticLogs.count > 200 {
            diagnosticLogs.removeFirst(diagnosticLogs.count - 200)
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
    private struct SendablePixelBuffer: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

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
        let requestedSpatial2x: Bool
        var sourceWidth: Int
        var sourceHeight: Int
        var forceNormalizeSource: Bool
        var sourceNormPool: CVPixelBufferPool?
        var sourceTransferSession: VTPixelTransferSession?
        var destPool: CVPixelBufferPool
        var transferSession: VTPixelTransferSession?
        var previousBuffer: CVPixelBuffer?
        var previousPTS: CMTime = .invalid
        var localSuccessCount: Int = 0
        var localConsecutiveFailures: Int = 0
        var totalInterpolationMs: Double = 0
        var didCheckActualDimensions: Bool = false
        var didStartAudioClock: Bool = false
        var didLogCatchUp: Bool = false
        var didCachePendingFirstFrame: Bool = false
        var frcNeedsRandomSubmission: Bool = true
        var interpolationExhausted: Bool = false
        var didRetryWithNormalizationOnCurrentCandidate: Bool = false

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
            let trackFormatDescriptions = (try? await videoTrack.load(.formatDescriptions)) ?? []
            let fallbackTrackDesc = trackFormatDescriptions.first

            let initialSpatial2x = spatial2x && !SuperResolutionPolicy.isAlready4K(width: width, height: height)
            let candidates = buildCandidatePlanForDevice(
                sourceWidth: width,
                sourceHeight: height,
                requestedSpatial2x: initialSpatial2x
            )

            guard let activated = activateCandidate(
                in: candidates,
                startingAt: 0,
                prefer10Bit: prefer10Bit
            ) else {
                logAsync("[ane] 无法初始化 VideoToolbox 光流配置（源 \(width)×\(height), 候选数 \(candidates.count)）")
                Task { @MainActor [weak self] in
                    self?.activeBackendLabel = "不可用"
                    self?.isLoadingPipeline = false
                    self?.pipelineStatusText = ""
                    self?.errorMessage = "无法初始化 VideoToolbox 光流配置（\(width)×\(height)）。"
                }
                return
            }

            let resolvedPixFmtString = Self.fourCCString(activated.pixelFormat)
            let initialForceNorm = (width != activated.candidate.width || height != activated.candidate.height)
            logAsync("[ane] 光流会话启动: 源 \(width)×\(height) -> 后端 \(activated.candidate.displayLabel), pixFmt=\(resolvedPixFmtString), forceNorm=\(initialForceNorm), prefer10Bit=\(prefer10Bit)")

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
                forceNormalizeSource: initialForceNorm,
                sourceNormPool: activated.sourceNormPool,
                sourceTransferSession: activated.sourceTransferSession,
                destPool: activated.destPool,
                transferSession: activated.transferSession
            )
            defer { state.cleanup() }

            var primaryError: Error?
            var openedReader: (reader: AVAssetReader, output: AVAssetReaderTrackOutput, tierLabel: String, pixelFormat: OSType)?
            do {
                openedReader = try openAssetReaderWithFallback(
                    asset: asset,
                    videoTrack: videoTrack,
                    startSeconds: startSeconds,
                    preferredPixelFormat: state.pixelFormat,
                    prefer10Bit: prefer10Bit
                )
            } catch {
                primaryError = error
            }

            var activeReader: AVAssetReader?
            var decodedAnyPrimaryFrame = false

            if let openedReader {
                let reader = openedReader.reader
                let trackOutput = openedReader.output
                activeReader = reader
                state.forceNormalizeSource = state.forceNormalizeSource || (openedReader.pixelFormat != state.pixelFormat)

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
                    decodedAnyPrimaryFrame = true
                    let currentPTS = CMSampleBufferGetPresentationTimeStamp(sample)
                    try await processDecodedFrame(
                        SendablePixelBuffer(buffer: currentBuffer),
                        currentPTS: currentPTS,
                        state: state,
                        token: token
                    )
                }

                if !decodedAnyPrimaryFrame && reader.status == .failed && isTokenValid(token) {
                    primaryError = reader.error ?? primaryError
                }
            }

            let shouldUsePassthroughFallback = (openedReader == nil)
                || (!decodedAnyPrimaryFrame && activeReader?.status == .failed && isTokenValid(token))

            if shouldUsePassthroughFallback {
                let reasonText = Self.formatDetailedError(primaryError)
                logAsync("[ane][warn] 常规 AVAssetReader 全档位失败，切换压缩透传 + VTDecompressionSession 硬解兜底: \(reasonText)")

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
                var decodedSuccessFrames = 0
                var loggedDecodeFailure = false

                while passthroughReader.status == .reading {
                    if !isTokenValid(token) {
                        passthroughReader.cancelReading()
                        return
                    }

                    while queuedCount() >= maxQueuedFrames {
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
                            throw NSError(domain: "GlassMPV.OpticalFlow.Decompress", code: -202, userInfo: [
                                NSLocalizedDescriptionKey: "压缩透传流缺少视频格式描述，无法建立硬解兜底"
                            ])
                        }
                        let leadingData = HEVCFormatNormalizer.copyLeadingData(from: sample)
                        guard let created = createDecompressionSessionWithFallback(
                            rawDesc: rawDesc,
                            fallbackSampleData: leadingData,
                            preferredPixelFormat: state.pixelFormat,
                            prefer10Bit: prefer10Bit
                        ) else {
                            passthroughReader.cancelReading()
                            throw NSError(domain: "GlassMPV.OpticalFlow.Decompress", code: -203, userInfo: [
                                NSLocalizedDescriptionKey: "VTDecompressionSession 硬解兜底全部候选均失败 (\(HEVCFormatNormalizer.describeFormat(rawDesc)))"
                            ])
                        }
                        holder = created
                    }

                    guard let activeHolder = holder else { continue }
                    let decodeResult = activeHolder.decode(sampleBuffer: sample)
                    if (decodeResult.decodeStatus != noErr || decodeResult.drained.lastStatus != noErr),
                       !loggedDecodeFailure,
                       decodedSuccessFrames == 0 {
                        loggedDecodeFailure = true
                        logAsync("[ane][warn] VTDecompressionSession 解码异常状态 decode=\(decodeResult.decodeStatus), callback=\(decodeResult.drained.lastStatus), strategy=\(activeHolder.strategy)")
                    }

                    for frame in decodeResult.drained.frames {
                        guard frame.pts.isValid, frame.pts.seconds.isFinite else { continue }
                        decodedSuccessFrames += 1
                        reorderBuffer.insert(pts: frame.pts.seconds, frame: frame.buffer)
                        while let ready = reorderBuffer.popNextIfReady() {
                            if startSeconds > 0.1 && ready.pts < startSeconds - 0.05 {
                                continue
                            }
                            try await processDecodedFrame(
                                SendablePixelBuffer(buffer: ready.frame),
                                currentPTS: CMTime(seconds: ready.pts, preferredTimescale: 600),
                                state: state,
                                token: token
                            )
                        }
                    }
                }

                if passthroughReader.status != .failed && isTokenValid(token) {
                    if let activeHolder = holder {
                        let tail = activeHolder.waitForAsyncFrames()
                        for frame in tail.frames {
                            guard frame.pts.isValid, frame.pts.seconds.isFinite else { continue }
                            decodedSuccessFrames += 1
                            reorderBuffer.insert(pts: frame.pts.seconds, frame: frame.buffer)
                        }
                    }
                    for ready in reorderBuffer.drainAll() {
                        if !isTokenValid(token) {
                            return
                        }
                        if startSeconds > 0.1 && ready.pts < startSeconds - 0.05 {
                            continue
                        }
                        try await processDecodedFrame(
                            SendablePixelBuffer(buffer: ready.frame),
                            currentPTS: CMTime(seconds: ready.pts, preferredTimescale: 600),
                            state: state,
                            token: token
                        )
                    }
                }
            }

            if let activeReader, activeReader.status == .failed && isTokenValid(token) {
                let errDesc = Self.formatDetailedError(activeReader.error)
                logAsync("[ane][error] AVAssetReader 读取异常终止: \(errDesc)")
                if !state.didStartAudioClock {
                    Task { @MainActor [weak self] in
                        self?.isLoadingPipeline = false
                        self?.pipelineStatusText = ""
                        self?.errorMessage = "光流解码异常：\(errDesc)"
                    }
                }
            } else if isTokenValid(token) {
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
        requestedSpatial2x: Bool
    ) -> [OpticalFlowCandidate] {
        let lowLatencySupported = VTLowLatencyFrameInterpolationConfiguration.isSupported
        let frcSupported = VTFrameRateConversionConfiguration.isSupported
        let llBounds = Self.queryDimensionBounds(for: VTLowLatencyFrameInterpolationConfiguration.self)
        let frcBounds = Self.queryDimensionBounds(for: VTFrameRateConversionConfiguration.self)
        let plan = OpticalFlowResolutionPlanner.buildCandidatePlan(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            requestedSpatial2x: requestedSpatial2x,
            lowLatencySupported: lowLatencySupported,
            frcSupported: frcSupported,
            lowLatencyBounds: llBounds,
            frcBounds: frcBounds
        )
        let labels = plan.map(\.displayLabel).joined(separator: ", ")
        logAsync("[ane] 双后端探测: LowLatency=\(lowLatencySupported)(bounds=\(Self.formatDimensionBounds(llBounds))), FRC=\(frcSupported)(bounds=\(Self.formatDimensionBounds(frcBounds))), 候选=[\(labels)]")
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
            guard let cfg = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: candidate.width,
                frameHeight: candidate.height,
                numberOfInterpolatedFrames: 1
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
            let sourceNormPool = try? makeSourceNormalizationPool(
                configuration: config,
                width: candidate.width,
                height: candidate.height,
                pixelFormat: pixelFormat
            )
            var sourceTransferSession: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &sourceTransferSession)

            let destPool: CVPixelBufferPool
            do {
                destPool = try makeDestinationPool(
                    configuration: config,
                    fallbackWidth: candidate.spatial2x ? candidate.width * 2 : candidate.width,
                    fallbackHeight: candidate.spatial2x ? candidate.height * 2 : candidate.height,
                    fallbackFormat: pixelFormat
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

    private func openAssetReaderWithFallback(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        startSeconds: Double,
        preferredPixelFormat: OSType,
        prefer10Bit: Bool
    ) throws -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput, tierLabel: String, pixelFormat: OSType) {
        let tiers = Self.buildReaderSettingsTiers(preferredFormat: preferredPixelFormat, prefer10Bit: prefer10Bit)
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
        prefer10Bit: Bool
    ) -> VTDecompressionSessionHolder? {
        let candidates = HEVCFormatNormalizer.makeNormalizedFormatDescriptionCandidates(
            from: rawDesc,
            fallbackSampleData: fallbackSampleData
        )
        var pixelFormats: [OSType] = [preferredPixelFormat]
        let format10Bit = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let format8Bit = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let formatBGRA = kCVPixelFormatType_32BGRA
        if prefer10Bit && !pixelFormats.contains(format10Bit) {
            pixelFormats.append(format10Bit)
        }
        for candidateFmt in [format8Bit, formatBGRA] where !pixelFormats.contains(candidateFmt) {
            pixelFormats.append(candidateFmt)
        }

        var failures: [String] = []
        for candidate in candidates {
            for fmt in pixelFormats {
                let attrs: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: fmt),
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ]
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
                    logAsync("[ane] VTDecompressionSession 硬解兜底已启动 (strategy=\(candidate.strategy), pixFmt=\(Self.fourCCString(fmt)))")
                    return VTDecompressionSessionHolder(
                        session: session,
                        formatDescription: candidate.description,
                        strategy: candidate.strategy
                    )
                }
                failures.append("\(candidate.strategy)/\(Self.fourCCString(fmt))=\(status)")
            }
        }
        logAsync("[ane][error] VTDecompressionSession 硬解兜底全部创建失败: \(failures.joined(separator: ", "))")
        return nil
    }

    private func processDecodedFrame(
        _ frameBox: SendablePixelBuffer,
        currentPTS: CMTime,
        state: OpticalFlowPipelineState,
        token: UUID
    ) async throws {
        guard isTokenValid(token) else { return }
        let currentBuffer = frameBox.buffer

        if !state.didCheckActualDimensions {
            state.didCheckActualDimensions = true
            let actualW = CVPixelBufferGetWidth(currentBuffer)
            let actualH = CVPixelBufferGetHeight(currentBuffer)
            if actualW >= 2, actualH >= 2, (actualW != state.sourceWidth || actualH != state.sourceHeight) {
                logAsync("[ane] 实际解码缓冲尺寸 \(actualW)×\(actualH) 与轨道声明 \(state.sourceWidth)×\(state.sourceHeight) 不一致，重新规划光流候选")
                state.sourceWidth = actualW
                state.sourceHeight = actualH
                let rebuiltSpatial2x = state.requestedSpatial2x && !SuperResolutionPolicy.isAlready4K(width: actualW, height: actualH)
                let newPlan = buildCandidatePlanForDevice(
                    sourceWidth: actualW,
                    sourceHeight: actualH,
                    requestedSpatial2x: rebuiltSpatial2x
                )
                if let firstNew = newPlan.first, firstNew != state.activeCandidate {
                    if let rebuilt = activateCandidate(
                        in: newPlan,
                        startingAt: 0,
                        prefer10Bit: state.prefer10Bit
                    ) {
                        state.candidates = newPlan
                        applyActivatedSession(rebuilt, to: state, token: token, reason: "实测尺寸重规划")
                    }
                } else {
                    state.forceNormalizeSource = state.forceNormalizeSource || (actualW != state.activeWidth || actualH != state.activeHeight)
                }
            }
        }

        let workingBuffer = normalizeSourceBufferIfNeeded(
            currentBuffer,
            targetWidth: state.activeWidth,
            targetHeight: state.activeHeight,
            targetPixelFormat: state.pixelFormat,
            forceNormalize: state.forceNormalizeSource,
            transferSession: state.sourceTransferSession,
            pool: state.sourceNormPool
        )

        let behindAudioClock = state.didStartAudioClock && (currentPTS.seconds < readLatestAudioTime() - 0.18)
        if behindAudioClock {
            state.frcNeedsRandomSubmission = true
            if !state.didLogCatchUp {
                state.didLogCatchUp = true
                logAsync("[ane][perf] 光流处理落后时钟，临时跳过部分帧插帧以保持音画同步")
            }
            Task { @MainActor [weak self] in
                self?.skippedInterpolationCount += 1
            }
        } else if !state.interpolationExhausted,
                  let prevBuf = state.previousBuffer,
                  state.previousPTS.isValid,
                  currentPTS > state.previousPTS,
                  Self.isValidInterpolationDelta(currentPTS.seconds - state.previousPTS.seconds) {
            if let prevFrame = VTFrameProcessorFrame(buffer: prevBuf, presentationTimeStamp: state.previousPTS),
               let currFrame = VTFrameProcessorFrame(buffer: workingBuffer, presentationTimeStamp: currentPTS) {
                var destBufOpt: CVPixelBuffer?
                let poolStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, state.destPool, &destBufOpt)

                if poolStatus == kCVReturnSuccess, let destBuf = destBufOpt {
                    let midSeconds = (state.previousPTS.seconds + currentPTS.seconds) * 0.5
                    let midPTS = CMTime(seconds: midSeconds, preferredTimescale: 600)
                    if let destFrame = VTFrameProcessorFrame(buffer: destBuf, presentationTimeStamp: midPTS) {
                        do {
                            let processStart = CACurrentMediaTime()
                            switch state.configuration {
                            case .lowLatency:
                                guard let params = VTLowLatencyFrameInterpolationParameters(
                                    sourceFrame: currFrame,
                                    previousFrame: prevFrame,
                                    interpolationPhase: [0.5],
                                    destinationFrames: [destFrame]
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
                                    interpolationPhase: [0.5],
                                    submissionMode: submissionMode,
                                    destinationFrames: [destFrame]
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
                            CVBufferPropagateAttachments(workingBuffer, destBuf)
                            enqueueDecodedFrame(pts: midSeconds, buffer: destBuf)
                            state.localSuccessCount += 1
                            state.localConsecutiveFailures = 0
                            let avgMs = state.totalInterpolationMs / Double(state.localSuccessCount)
                            if state.localSuccessCount == 1 {
                                logAsync("[ane] 首帧光流补帧成功（\(state.activeCandidate.displayLabel), 耗时 \(String(format: "%.1f", elapsedMs))ms）")
                            }
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.interpolatedFrameCount += 1
                                self.averageInterpolationMs = avgMs
                            }
                        } catch {
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
                                } else {
                                    state.interpolationExhausted = true
                                    state.localConsecutiveFailures += 1
                                    logAsync("[ane][error] 全部 \(state.candidates.count) 个光流候选均失败，已熔断降级为原帧硬解直通: \(detailed)")
                                    Task { @MainActor [weak self] in
                                        guard let self, self.isTokenValid(token) else { return }
                                        self.activeBackendLabel = "已降级直通"
                                        self.failedInterpolationCount += 1
                                        self.lastInterpolationError = detailed
                                        self.isLoadingPipeline = false
                                        self.pipelineStatusText = ""
                                        if self.errorMessage == nil {
                                            self.errorMessage = "ANE 光流全档位不可用（\(detailed)），可一键切回 MPV 超分核。"
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
                    } else {
                        state.localConsecutiveFailures += 1
                        state.frcNeedsRandomSubmission = true
                        recordInterpolationFailure(
                            "VTFrameProcessorFrame(destFrame) 初始化返回 nil",
                            consecutiveFailures: state.localConsecutiveFailures,
                            totalSuccesses: state.localSuccessCount
                        )
                    }
                } else {
                    state.localConsecutiveFailures += 1
                    state.frcNeedsRandomSubmission = true
                    recordInterpolationFailure(
                        "CVPixelBufferPoolCreatePixelBuffer 失败 (\(poolStatus))",
                        consecutiveFailures: state.localConsecutiveFailures,
                        totalSuccesses: state.localSuccessCount
                    )
                }
            } else {
                state.localConsecutiveFailures += 1
                state.frcNeedsRandomSubmission = true
                recordInterpolationFailure(
                    "VTFrameProcessorFrame(prev/curr) 初始化返回 nil",
                    consecutiveFailures: state.localConsecutiveFailures,
                    totalSuccesses: state.localSuccessCount
                )
            }
        }

        let needsAlignToActiveCandidate = state.forceNormalizeSource
            || CVPixelBufferGetWidth(workingBuffer) != state.activeWidth
            || CVPixelBufferGetHeight(workingBuffer) != state.activeHeight
            || CVPixelBufferGetPixelFormatType(workingBuffer) != state.pixelFormat
        let finalSourceBuffer = needsAlignToActiveCandidate
            ? normalizeSourceBufferIfNeeded(
                currentBuffer,
                targetWidth: state.activeWidth,
                targetHeight: state.activeHeight,
                targetPixelFormat: state.pixelFormat,
                forceNormalize: true,
                transferSession: state.sourceTransferSession,
                pool: state.sourceNormPool
            )
            : workingBuffer
        let outputBuffer = scaleIfNeeded(
            finalSourceBuffer,
            spatial2x: state.activeSpatial2x,
            transferSession: state.transferSession,
            pool: state.destPool
        )
        if !state.didCachePendingFirstFrame {
            state.didCachePendingFirstFrame = true
            cachePendingFirstFrame(outputBuffer, ptsSeconds: currentPTS.seconds)
        }
        enqueueDecodedFrame(pts: currentPTS.seconds, buffer: outputBuffer)
        if !state.didStartAudioClock && queuedCount() >= prebufferFrameTarget {
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
        pixelFormat: OSType
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
            } else if let first = arr.first {
                attrs[kCVPixelBufferPixelFormatTypeKey as String] = first
            } else {
                attrs[kCVPixelBufferPixelFormatTypeKey as String] = pixelFormat
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
        prefer10Bit: Bool
    ) -> [(label: String, pixelFormat: OSType, settings: [String: Any])] {
        var tiers: [(label: String, pixelFormat: OSType, settings: [String: Any])] = []
        let ioMetalBase: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        func appendTier(label: String, format: OSType, includeIOMetal: Bool) {
            var settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format
            ]
            if includeIOMetal {
                for (k, v) in ioMetalBase {
                    settings[k] = v
                }
            }
            tiers.append((label: label, pixelFormat: format, settings: settings))
        }

        appendTier(label: "preferred(\(fourCCString(preferredFormat)))", format: preferredFormat, includeIOMetal: true)

        let format8Bit = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if preferredFormat != format8Bit {
            appendTier(label: "fallback-420v", format: format8Bit, includeIOMetal: true)
        } else if prefer10Bit {
            let format10Bit = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            appendTier(label: "fallback-p010", format: format10Bit, includeIOMetal: true)
        }

        let formatBGRA = kCVPixelFormatType_32BGRA
        if preferredFormat != formatBGRA {
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
