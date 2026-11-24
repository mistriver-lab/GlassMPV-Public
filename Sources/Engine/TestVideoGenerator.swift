import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// 内置测试视频生成器（用于端内一键自测与 CI 模拟器 XCTest 真实解码验证）
enum TestVideoGenerator: Sendable {
    enum GeneratorError: LocalizedError {
        case cannotCreateWriter(String)
        case cannotCreatePixelBuffer
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotCreateWriter(let msg):
                return "无法创建测试视频写入器：\(msg)"
            case .cannotCreatePixelBuffer:
                return "无法分配 CVPixelBuffer 像素缓冲"
            case .encodingFailed(let msg):
                return "测试视频编码失败：\(msg)"
            }
        }
    }

    static func generateSampleMP4(
        durationSeconds: Double = 3.0,
        width: Int = 640,
        height: Int = 360,
        fps: Int32 = 30
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try generateSync(
                durationSeconds: durationSeconds,
                width: width,
                height: height,
                fps: fps
            )
        }.value
    }

    private static func generateSync(
        durationSeconds: Double,
        width: Int,
        height: Int,
        fps: Int32
    ) throws -> URL {
        let safeWidth = max(width, 64)
        let safeHeight = max(height, 64)
        let safeFPS = max(fps, 1)
        let totalFrames = max(Int((durationSeconds * Double(safeFPS)).rounded()), 1)

        let targetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassmpv_selftest_\(safeWidth)x\(safeHeight)_\(Int(durationSeconds))s.mp4")

        if let attrs = try? FileManager.default.attributesOfItem(atPath: targetURL.path),
           let fileSize = attrs[.size] as? NSNumber,
           fileSize.intValue > 10_000 {
            return targetURL
        }

        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassmpv_staging_\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: stagingURL)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: stagingURL, fileType: .mp4)
        } catch {
            throw GeneratorError.cannotCreateWriter(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: safeWidth,
            AVVideoHeightKey: safeHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 1_500_000,
                AVVideoExpectedSourceFrameRateKey: Int(safeFPS),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let pixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: safeWidth,
            kCVPixelBufferHeightKey as String: safeHeight,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelAttributes
        )

        guard writer.canAdd(input) else {
            throw GeneratorError.cannotCreateWriter("AVAssetWriter 拒绝添加视频输入轨")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw GeneratorError.encodingFailed(writer.error?.localizedDescription ?? "startWriting 失败")
        }
        writer.startSession(atSourceTime: .zero)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        for frameIndex in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed || writer.status == .cancelled {
                    throw GeneratorError.encodingFailed(writer.error?.localizedDescription ?? "写入中断")
                }
                Thread.sleep(forTimeInterval: 0.005)
            }

            guard let pool = adaptor.pixelBufferPool else {
                throw GeneratorError.cannotCreatePixelBuffer
            }
            var pixelBufferOut: CVPixelBuffer?
            let poolStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBufferOut)
            guard poolStatus == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
                throw GeneratorError.cannotCreatePixelBuffer
            }

            renderTestPatternFrame(
                into: pixelBuffer,
                width: safeWidth,
                height: safeHeight,
                frameIndex: frameIndex,
                totalFrames: totalFrames,
                colorSpace: colorSpace,
                bitmapInfo: bitmapInfo
            )

            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: safeFPS)
            if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
                throw GeneratorError.encodingFailed(writer.error?.localizedDescription ?? "append 帧失败")
            }
        }

        input.markAsFinished()
        let finishSemaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            finishSemaphore.signal()
        }
        finishSemaphore.wait()

        guard writer.status == .completed else {
            throw GeneratorError.encodingFailed(writer.error?.localizedDescription ?? "finishWriting 状态异常(\(writer.status.rawValue))")
        }

        if FileManager.default.fileExists(atPath: targetURL.path) {
            try? FileManager.default.removeItem(at: targetURL)
        }
        do {
            try FileManager.default.moveItem(at: stagingURL, to: targetURL)
        } catch {
            if FileManager.default.fileExists(atPath: targetURL.path) {
                return targetURL
            }
            throw error
        }

        return targetURL
    }

    private static func renderTestPatternFrame(
        into pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        frameIndex: Int,
        totalFrames: Int,
        colorSpace: CGColorSpace,
        bitmapInfo: UInt32
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let ctx = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return
        }

        let w = CGFloat(width)
        let h = CGFloat(height)

        // 1. SMPTE 风格 7 段高饱和彩条背景
        let smpteColors: [(CGFloat, CGFloat, CGFloat)] = [
            (0.85, 0.85, 0.85), // 白
            (0.92, 0.82, 0.14), // 黄
            (0.10, 0.85, 0.88), // 青
            (0.14, 0.80, 0.25), // 绿
            (0.82, 0.20, 0.82), // 品红
            (0.88, 0.18, 0.20), // 红
            (0.12, 0.35, 0.90)  // 蓝
        ]
        let barWidth = w / CGFloat(smpteColors.count)
        for (idx, rgb) in smpteColors.enumerated() {
            ctx.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1.0)
            ctx.fill(CGRect(x: CGFloat(idx) * barWidth, y: h * 0.22, width: barWidth + 1.0, height: h * 0.78))
        }

        // 2. 下半部分深色参考区（高对比度便于检验超分锐度与防锯齿）
        ctx.setFillColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.22))

        // 3. 往返平滑移动的高对比度白色方块（肉眼验证流畅度/补帧）
        let progress = totalFrames > 1 ? CGFloat(frameIndex) / CGFloat(totalFrames - 1) : 0
        let boxSize = min(w, h) * 0.16
        let travel = w - boxSize - 32
        let boxX = 16 + travel * progress
        let boxY = h * 0.52 - boxSize * 0.5

        ctx.setFillColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 0.85)
        ctx.fill(CGRect(x: boxX - 4, y: boxY - 4, width: boxSize + 8, height: boxSize + 8))
        ctx.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: boxX, y: boxY, width: boxSize, height: boxSize))

        // 4. 斜线网格条（验证 Anime4K 边缘线条与抗锯齿）
        ctx.setStrokeColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 0.9)
        ctx.setLineWidth(3.0)
        ctx.move(to: CGPoint(x: boxX + 6, y: boxY + 6))
        ctx.addLine(to: CGPoint(x: boxX + boxSize - 6, y: boxY + boxSize - 6))
        ctx.move(to: CGPoint(x: boxX + boxSize - 6, y: boxY + 6))
        ctx.addLine(to: CGPoint(x: boxX + 6, y: boxY + boxSize - 6))
        ctx.strokePath()

        // 5. 底部进度条
        let barHeight: CGFloat = 10
        let barMargin: CGFloat = 20
        let fullTrackWidth = w - barMargin * 2
        ctx.setFillColor(red: 0.25, green: 0.27, blue: 0.32, alpha: 1.0)
        ctx.fill(CGRect(x: barMargin, y: h * 0.09, width: fullTrackWidth, height: barHeight))
        ctx.setFillColor(red: 0.15, green: 0.85, blue: 0.95, alpha: 1.0)
        ctx.fill(CGRect(x: barMargin, y: h * 0.09, width: fullTrackWidth * progress, height: barHeight))
    }
}
