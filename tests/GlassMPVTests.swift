import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import GlassMPV

final class GlassMPVTests: XCTestCase {
    func testSampleMP4Generation() async throws {
        let url = try await TestVideoGenerator.generateSampleMP4(
            durationSeconds: 3.0,
            width: 640,
            height: 360,
            fps: 30
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "应生成本地 MP4 文件")

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(fileSize, 10_000, "生成的测试视频文件过小: \(fileSize)")

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThanOrEqual(duration.seconds, 2.5)

        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let naturalSize = try await tracks[0].load(.naturalSize)
        XCTAssertEqual(Int(naturalSize.width), 640)
        XCTAssertEqual(Int(naturalSize.height), 360)
    }

    func testLocalMediaImporterSanitizationAndCopy() async throws {
        let sanitized = LocalMediaImporter.sanitizeFilenameComponent("测试 视频#1:2?3/4")
        XCTAssertFalse(sanitized.isEmpty)
        XCTAssertFalse(sanitized.contains("/"))
        XCTAssertFalse(sanitized.contains(":"))
        XCTAssertFalse(sanitized.contains("#"))
        XCTAssertFalse(sanitized.contains("?"))

        let sampleURL = try await TestVideoGenerator.generateSampleMP4(
            durationSeconds: 1.0,
            width: 320,
            height: 180,
            fps: 30
        )
        let cachesDir = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        )
        try FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
        let sourceURL = cachesDir.appendingPathComponent("测试 视频#1[120Hz].mp4")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            try FileManager.default.removeItem(at: sourceURL)
        }
        try FileManager.default.copyItem(at: sampleURL, to: sourceURL)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
        }

        let importedURL = try await LocalMediaImporter.preparePlayableLocalURL(
            from: sourceURL,
            isSecurityScoped: false
        )
        defer {
            try? FileManager.default.removeItem(at: importedURL)
        }

        let importsRoot = LocalMediaImporter.importsDirectory.standardizedFileURL.path
        XCTAssertTrue(
            importedURL.standardizedFileURL.path.hasPrefix(importsRoot),
            "导入文件应落在沙盒导入目录: \(importedURL.path)"
        )
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: importedURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: importedURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 10_000)
    }

    @MainActor
    func testOpticalFlowSampleBufferDisplayImmediately() throws {
        var pixelBufferOpt: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &pixelBufferOpt
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(pixelBufferOpt)

        let controller = OpticalFlowPlayerController()
        let sampleBuffer = try XCTUnwrap(controller.makeSampleBuffer(from: pixelBuffer, ptsSeconds: 0.5))
        let attachments = try XCTUnwrap(
            CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        )
        XCTAssertGreaterThan(CFArrayGetCount(attachments), 0)

        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
        let valPtr = try XCTUnwrap(CFDictionaryGetValue(dict, key))
        XCTAssertTrue(CFBooleanGetValue(unsafeBitCast(valPtr, to: CFBoolean.self)))
    }

    @MainActor
    func testOpticalFlowAttachConfiguresTimebaseAndSampleBuffer() throws {
        let container = SampleBufferDisplayContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        XCTAssertNil(container.displayLayer.controlTimebase)

        let controller = OpticalFlowPlayerController()
        controller.attach(to: container.displayLayer)
        let timebase = try XCTUnwrap(container.displayLayer.controlTimebase, "attach 后应绑定 controlTimebase 以防止高起点 seek 黑屏")
        XCTAssertGreaterThan(CMTimebaseGetRate(timebase), 0)

        var pixelBufferOpt: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &pixelBufferOpt
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(pixelBufferOpt)

        let sampleBuffer = try XCTUnwrap(controller.makeSampleBuffer(from: pixelBuffer, ptsSeconds: 120.0))
        XCTAssertTrue(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).isValid)
        let attachments = try XCTUnwrap(
            CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        )
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
        let valPtr = try XCTUnwrap(CFDictionaryGetValue(dict, key))
        XCTAssertTrue(CFBooleanGetValue(unsafeBitCast(valPtr, to: CFBoolean.self)))
    }

    func testPlaybackHUDMetricsFormattingAndParsing() {
        XCTAssertEqual(PlaybackHUDMetrics.formatCodecName("hvc1"), "HEVC")
        XCTAssertEqual(PlaybackHUDMetrics.formatCodecName("avc1"), "H.264")
        XCTAssertEqual(PlaybackHUDMetrics.formatCodecName("av01"), "AV1")
        XCTAssertEqual(PlaybackHUDMetrics.formatCodecName(""), "--")

        XCTAssertEqual(PlaybackHUDMetrics.parseBitDepth(fromPixelFormat: "nv12"), "8-bit")
        XCTAssertEqual(PlaybackHUDMetrics.parseBitDepth(fromPixelFormat: "yuv420p"), "8-bit")
        XCTAssertEqual(PlaybackHUDMetrics.parseBitDepth(fromPixelFormat: "p010le"), "10-bit")
        XCTAssertEqual(PlaybackHUDMetrics.parseBitDepth(fromPixelFormat: "x420"), "10-bit")
        XCTAssertEqual(PlaybackHUDMetrics.parseBitDepth(fromPixelFormat: "yuv420p12le"), "12-bit")
        XCTAssertEqual(PlaybackHUDMetrics.parseBitDepth(fromPixelFormat: "p016"), "16-bit")
        XCTAssertEqual(PlaybackHUDMetrics.parseBitDepth(fromPixelFormat: ""), "--")

        XCTAssertEqual(PlaybackHUDMetrics.formatHDRTag(isHDRContent: true, transferName: "pq", isHDRActive: false), "HDR10")
        XCTAssertEqual(PlaybackHUDMetrics.formatHDRTag(isHDRContent: true, transferName: "pq", isHDRActive: true), "HDR10✓")
        XCTAssertEqual(PlaybackHUDMetrics.formatHDRTag(isHDRContent: true, transferName: "hlg", isHDRActive: false), "HLG")
        XCTAssertEqual(PlaybackHUDMetrics.formatHDRTag(isHDRContent: false, transferName: "bt.709", isHDRActive: false), "SDR")

        XCTAssertEqual(PlaybackHUDMetrics.formatDecoderBadge(hardwareDecoder: "videotoolbox"), "硬解 VT")
        XCTAssertEqual(PlaybackHUDMetrics.formatDecoderBadge(hardwareDecoder: "software"), "软解")

        XCTAssertEqual(ThermalLevel(state: .nominal).rawValue, "正常")
        XCTAssertEqual(ThermalLevel(state: .fair).rawValue, "温热")
        XCTAssertEqual(ThermalLevel(state: .serious).rawValue, "过热")
        XCTAssertEqual(ThermalLevel(state: .critical).rawValue, "严重过热")

        let metrics = PlaybackHUDMetrics(
            engineBadge: "ANE",
            interpolationBadge: "光流96fps",
            codec: "hevc",
            width: 1920,
            height: 1080,
            sourceFPS: 23.976,
            outputFPS: 96.0,
            bitDepth: "10-bit",
            hdrTag: "HDR10",
            isHDRActive: false,
            decoderBadge: "VT+LowLatency 986×720 [×4]",
            droppedFrames: 0,
            thermalLevel: .nominal
        )
        XCTAssertEqual(metrics.videoStreamSummary, "HEVC · 1920×1080 · 10-bit HDR10")
        XCTAssertEqual(metrics.fpsSummary, "23.98 → 96.0 fps")
        XCTAssertEqual(metrics.pipelineSummary, "VT+LowLatency 986×720 [×4] · 光流96fps")
    }

    @MainActor
    func testNativeDocumentPickerConfigurationAndPhotoPermission() throws {
        let picker = NativeDocumentPickerPresenter.makePicker()
        XCTAssertFalse(picker.allowsMultipleSelection)
        XCTAssertEqual(picker.modalPresentationStyle, .formSheet)
        XCTAssertTrue(NativeDocumentPickerPresenter.supportedContentTypes.contains(.movie))
        XCTAssertTrue(NativeDocumentPickerPresenter.supportedContentTypes.contains(.item))

        let photoUsage = Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") as? String
        XCTAssertNotNil(photoUsage)
        XCTAssertFalse((photoUsage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testSuperResolutionPolicy4KGating() {
        XCTAssertTrue(SuperResolutionPolicy.isAlready4K(width: 3840, height: 2160))
        XCTAssertTrue(SuperResolutionPolicy.isAlready4K(width: 2160, height: 3840))
        XCTAssertTrue(SuperResolutionPolicy.isAlready4K(width: 4096, height: 2160))
        XCTAssertTrue(SuperResolutionPolicy.isAlready4K(width: 2960, height: 2160))
        XCTAssertFalse(SuperResolutionPolicy.isAlready4K(width: 1920, height: 1080))
        XCTAssertFalse(SuperResolutionPolicy.isAlready4K(width: 2560, height: 1440))
        XCTAssertFalse(SuperResolutionPolicy.isAlready4K(width: 0, height: 0))

        XCTAssertNotNil(SuperResolutionPolicy.disabledReason(width: 3840, height: 2160))
        XCTAssertNil(SuperResolutionPolicy.disabledReason(width: 1920, height: 1080))
    }

    func testDiagnosticLogExporterBuildAndWrite() throws {
        let report = DiagnosticLogExporter.buildReport(
            version: "v2026.11.27",
            engineName: "ANE 光流核",
            playbackState: "播放中",
            resolution: "1920×1080",
            fpsSummary: "24.0 → 96.0 fps",
            decoderSummary: "HEVC / VT+LowLatency",
            is4KGated: false,
            telemetrySummary: ["ANE Clock: 合成单调时钟"],
            selfCheck: "self-check-ok",
            opticalLogs: ["[ane] idle"]
        )
        XCTAssertTrue(report.contains("GlassMPV v2026.11.27"))
        XCTAssertTrue(report.contains("4K Super-Res Gated: NO"))
        XCTAssertTrue(report.contains("--- Interpolation Telemetry ---"))
        XCTAssertTrue(report.contains("ANE Clock: 合成单调时钟"))
        XCTAssertTrue(report.contains("--- Self Check ---"))
        XCTAssertTrue(report.contains("self-check-ok"))
        XCTAssertFalse(report.contains("--- MPV Logs"))
        XCTAssertTrue(report.contains("--- Optical Flow Logs (1) ---"))
        XCTAssertTrue(report.contains("[ane] idle"))

        let fileURL = try DiagnosticLogExporter.writeLogFile(content: report)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }
        XCTAssertEqual(fileURL.pathExtension.lowercased(), "txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let readBack = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(readBack, report)
    }

    @MainActor
    func testOrientationControllerStateTransitions() {
        let controller = OrientationController.shared
        defer {
            controller.returnToHomeOrientation()
        }

        controller.enterVideoLandscape()
        XCTAssertEqual(controller.supportedMask, .landscape)
        XCTAssertTrue(controller.isLandscapeLocked)

        controller.toggleVideoOrientation()
        XCTAssertEqual(controller.supportedMask, .portrait)
        XCTAssertFalse(controller.isLandscapeLocked)

        controller.toggleVideoOrientation()
        XCTAssertEqual(controller.supportedMask, .landscape)
        XCTAssertTrue(controller.isLandscapeLocked)

        controller.returnToHomeOrientation()
        XCTAssertEqual(controller.supportedMask, .allButUpsideDown)
        XCTAssertFalse(controller.isLandscapeLocked)
    }

    func testOpticalFlowSyntheticClockTransitions() {
        var clock = OpticalFlowSyntheticClock()
        clock.reset(to: 1.5, now: 100.0)
        XCTAssertFalse(clock.isRunning)
        XCTAssertEqual(clock.currentTime(now: 105.0), 1.5, accuracy: 1e-6)

        clock.start(rate: 1.0, now: 105.0)
        XCTAssertTrue(clock.isRunning)
        XCTAssertEqual(clock.currentTime(now: 107.0), 3.5, accuracy: 1e-6)

        clock.setRate(2.0, now: 107.0)
        XCTAssertTrue(clock.isRunning)
        XCTAssertEqual(clock.currentTime(now: 108.5), 6.5, accuracy: 1e-6)

        clock.pause(now: 108.5)
        XCTAssertFalse(clock.isRunning)
        XCTAssertEqual(clock.currentTime(now: 120.0), 6.5, accuracy: 1e-6)

        clock.seek(to: 2.0, now: 120.0)
        XCTAssertFalse(clock.isRunning)
        XCTAssertEqual(clock.currentTime(now: 125.0), 2.0, accuracy: 1e-6)

        clock.start(rate: 1.5, now: 125.0)
        XCTAssertEqual(clock.currentTime(now: 127.0), 5.0, accuracy: 1e-6)
    }

    @MainActor
    func testOpticalFlowPendingFirstFrameDeliveredOnAttach() throws {
        var pixelBufferOpt: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &pixelBufferOpt
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(pixelBufferOpt)

        let controller = OpticalFlowPlayerController()
        controller.isLoadingPipeline = true
        controller.cachePendingFirstFrame(pixelBuffer, ptsSeconds: 0.25)

        let container = SampleBufferDisplayContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        controller.attach(to: container)

        XCTAssertNotNil(container.displayLayer.controlTimebase)
        XCTAssertEqual(controller.presentedFrameCount, 1)
        XCTAssertFalse(controller.isLoadingPipeline)
    }

    @MainActor
    func testSampleBufferDisplayContainerRotationLayout() {
        let container = SampleBufferDisplayContainerView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        XCTAssertTrue(container.displayLayer.superlayer === container.layer)
        XCTAssertEqual(container.displayLayer.bounds.size.width, 400, accuracy: 0.5)
        XCTAssertEqual(container.displayLayer.bounds.size.height, 200, accuracy: 0.5)

        let quarterTurn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        XCTAssertTrue(SampleBufferDisplayContainerView.isQuarterTurnTransform(quarterTurn))
        container.applyVideoTransform(quarterTurn)

        XCTAssertEqual(container.displayLayer.bounds.size.width, 200, accuracy: 0.5)
        XCTAssertEqual(container.displayLayer.bounds.size.height, 400, accuracy: 0.5)
        XCTAssertEqual(container.displayLayer.position.x, 200, accuracy: 0.5)
        XCTAssertEqual(container.displayLayer.position.y, 100, accuracy: 0.5)
        let applied = container.displayLayer.affineTransform()
        XCTAssertEqual(applied.tx, 0, accuracy: 1e-4)
        XCTAssertEqual(applied.ty, 0, accuracy: 1e-4)
        XCTAssertEqual(applied.b, 1, accuracy: 1e-4)

        XCTAssertTrue(OpticalFlowPlayerController.isValidInterpolationDelta(1.0 / 24.0))
        XCTAssertFalse(OpticalFlowPlayerController.isValidInterpolationDelta(0.001))
        XCTAssertFalse(OpticalFlowPlayerController.isValidInterpolationDelta(1.5))
    }

    func testInterpolationVerdictANE() {
        let offVerdict = InterpolationVerdict.evaluateANE(
            isEnabled: false,
            interpolatedCount: 0,
            failedCount: 0,
            presentedCount: 24,
            actualOutputFPS: 24.0,
            sourceFPS: 24.0,
            errorMessage: nil
        )
        XCTAssertEqual(offVerdict, .off)
        XCTAssertFalse(offVerdict.isEffective)
        XCTAssertEqual(offVerdict.shortLabel, "未开启")

        let aneActive = InterpolationVerdict.evaluateANE(
            interpolatedCount: 12,
            failedCount: 0,
            presentedCount: 24,
            actualOutputFPS: 48.0,
            sourceFPS: 24.0,
            errorMessage: nil
        )
        XCTAssertTrue(aneActive.isEffective)
        XCTAssertEqual(aneActive.shortLabel, "ANE光流生效")

        let aneFailedErr = InterpolationVerdict.evaluateANE(
            interpolatedCount: 0,
            failedCount: 0,
            presentedCount: 0,
            actualOutputFPS: 0,
            sourceFPS: 24.0,
            errorMessage: "reader failed"
        )
        XCTAssertFalse(aneFailedErr.isEffective)
        XCTAssertEqual(aneFailedErr.shortLabel, "ANE光流失败")

        let aneFailedCount = InterpolationVerdict.evaluateANE(
            interpolatedCount: 0,
            failedCount: 3,
            presentedCount: 10,
            actualOutputFPS: 24.0,
            sourceFPS: 24.0,
            errorMessage: nil
        )
        XCTAssertFalse(aneFailedCount.isEffective)
        XCTAssertEqual(aneFailedCount.shortLabel, "ANE光流失败")

        let anePending = InterpolationVerdict.evaluateANE(
            interpolatedCount: 0,
            failedCount: 0,
            presentedCount: 5,
            actualOutputFPS: 24.0,
            sourceFPS: 24.0,
            errorMessage: nil
        )
        XCTAssertFalse(anePending.isEffective)
        XCTAssertEqual(anePending.shortLabel, "ANE预热中")
    }

    func testRuntimeTelemetrySampleFormattingAndReportInclusion() {
        let passSample = RuntimeTelemetrySample(
            playbackState: "播放中",
            mediaTime: 12.5,
            width: 1920,
            height: 1080,
            sourceFPS: 24.0,
            outputFPS: 24.0,
            droppedFrames: 0,
            aneInterpolated: 0,
            aneSkipped: 0,
            aneFailed: 0,
            anePresented: 300,
            aneAvgMs: 0,
            aneTargetFPS: "原帧率",
            aneBackend: "原帧率直通",
            verdictLabel: "未开启",
            thermalLevel: .nominal
        )
        let aneSample = RuntimeTelemetrySample(
            playbackState: "播放中",
            mediaTime: 14.0,
            width: 1920,
            height: 1080,
            sourceFPS: 24.0,
            outputFPS: 95.8,
            droppedFrames: 0,
            aneInterpolated: 72,
            aneSkipped: 0,
            aneFailed: 0,
            anePresented: 96,
            aneAvgMs: 12.4,
            aneTargetFPS: "96fps",
            aneBackend: "LowLatency 986×720 [×4]",
            verdictLabel: "ANE光流生效",
            thermalLevel: .fair
        )

        let passLine = passSample.formatLogLine(timeString: "14:32:42.000")
        XCTAssertTrue(passLine.contains("[14:32:42.000] [PASS]"))
        XCTAssertTrue(passLine.contains("backend=原帧率直通"))
        XCTAssertTrue(passLine.contains("verdict=未开启"))

        let aneLine = aneSample.formatLogLine(timeString: "14:32:44.000")
        XCTAssertTrue(aneLine.contains("[14:32:44.000] [ANE]"))
        XCTAssertTrue(aneLine.contains("ane(interp=72,skip=0,fail=0,pres=96,avg=12.4ms)"))
        XCTAssertTrue(aneLine.contains("verdict=ANE光流生效"))

        let report = DiagnosticLogExporter.buildReport(
            version: "v2026.11.27",
            engineName: "ANE 光流核",
            playbackState: "播放中",
            resolution: "1920×1080",
            fpsSummary: "24.0 → 96.0 fps",
            decoderSummary: "HEVC / VT+LowLatency",
            is4KGated: false,
            telemetrySummary: ["Interpolation Verdict: ANE光流生效"],
            runtimeTimeline: [passLine, aneLine],
            selfCheck: "ok",
            opticalLogs: []
        )
        XCTAssertTrue(report.contains("--- Runtime Telemetry Timeline (2) ---"))
        XCTAssertTrue(report.contains(passLine))
        XCTAssertTrue(report.contains(aneLine))
    }

    func testOpticalFlowReaderSettingsTiersAndDetailedError() {
        let tiers = OpticalFlowPlayerController.buildReaderSettingsTiers(
            preferredFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            prefer10Bit: true
        )
        XCTAssertEqual(tiers.count, 5)

        let forbiddenKeys = [
            kCVPixelBufferPlaneAlignmentKey as String,
            kCVPixelBufferBytesPerRowAlignmentKey as String,
            kCVPixelBufferExtendedPixelsBottomKey as String,
            kCVPixelBufferExtendedPixelsRightKey as String
        ]
        for (index, tier) in tiers.enumerated() {
            for forbidden in forbiddenKeys {
                XCTAssertNil(tier.settings[forbidden], "档位 \(tier.label) 不应包含非法 Reader 键 \(forbidden)")
            }
            XCTAssertNotNil(tier.settings[kCVPixelBufferPixelFormatTypeKey as String])
            if index < 3 {
                XCTAssertNotNil(tier.settings[kCVPixelBufferIOSurfacePropertiesKey as String])
            } else {
                XCTAssertTrue(tier.label.hasPrefix("minimal-"))
                XCTAssertNil(tier.settings[kCVPixelBufferIOSurfacePropertiesKey as String])
            }
        }

        let underlying = NSError(domain: NSOSStatusErrorDomain, code: -12909, userInfo: [
            NSLocalizedDescriptionKey: "VTDecompression failed"
        ])
        let outer = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
            NSLocalizedDescriptionKey: "Operation Stopped",
            NSLocalizedFailureReasonErrorKey: "Unsupported pixel attributes",
            NSUnderlyingErrorKey: underlying
        ])
        let formatted = OpticalFlowPlayerController.formatDetailedError(outer)
        XCTAssertTrue(formatted.contains("AVFoundationErrorDomain(-11800)"))
        XCTAssertTrue(formatted.contains("Operation Stopped"))
        XCTAssertTrue(formatted.contains("Unsupported pixel attributes"))
        XCTAssertTrue(formatted.contains("-12909"))
    }

    func testOpticalFlowPTSReorderBufferAndHEVCFormatNormalizer() throws {
        var reorderBuffer = OpticalFlowPTSReorderBuffer<Double>(maxDepth: 3)
        let inputs: [Double] = [0.0, 0.16, 0.08, 0.04, 0.12, 0.24, 0.20]
        var reordered: [Double] = []
        for pts in inputs {
            reorderBuffer.insert(pts: pts, frame: pts)
            while let ready = reorderBuffer.popNextIfReady() {
                reordered.append(ready.pts)
            }
        }
        reordered.append(contentsOf: reorderBuffer.drainAll().map(\.pts))
        XCTAssertEqual(reorderBuffer.count, 0)
        XCTAssertEqual(reordered, [0.0, 0.04, 0.08, 0.12, 0.16, 0.20, 0.24])

        for tag in ["hev1", "hvc1", "avc3"] {
            let code = HEVCFormatNormalizer.fourCCCode(tag)
            XCTAssertEqual(HEVCFormatNormalizer.fourCCString(code), tag)
        }

        let vps = Data([0x40, 0x01, 0x0C, 0x01])
        let sps = Data([0x42, 0x01, 0x01, 0x01, 0x60])
        let pps = Data([0x44, 0x01, 0xC1, 0x73])
        let idrSlice = Data([0x26, 0x01, 0xAF, 0x00])

        var hvcc = Data(repeating: 0, count: 23)
        hvcc[0] = 1
        hvcc[21] = 0x03
        hvcc[22] = 3
        for (nalType, payload) in [(UInt8(32), vps), (UInt8(33), sps), (UInt8(34), pps)] {
            hvcc.append(0x80 | nalType)
            hvcc.append(0x00)
            hvcc.append(0x01)
            hvcc.append(UInt8((payload.count >> 8) & 0xFF))
            hvcc.append(UInt8(payload.count & 0xFF))
            hvcc.append(payload)
        }

        let parsedHVCC = try XCTUnwrap(HEVCFormatNormalizer.parseHEVCParameterSets(fromHVCC: hvcc))
        XCTAssertEqual(parsedHVCC.nalLengthSize, 4)
        XCTAssertEqual(parsedHVCC.parameterSets.count, 3)
        XCTAssertEqual(parsedHVCC.parameterSets, [vps, sps, pps])

        var lengthPrefixed = Data()
        for nalu in [vps, sps, pps, idrSlice, vps] {
            var bigLen = UInt32(nalu.count).bigEndian
            withUnsafeBytes(of: &bigLen) { lengthPrefixed.append(contentsOf: $0) }
            lengthPrefixed.append(nalu)
        }
        let extracted = HEVCFormatNormalizer.extractHEVCParameterSets(fromLengthPrefixed: lengthPrefixed, nalLengthSize: 4)
        XCTAssertEqual(extracted, [vps, sps, pps])
    }

    func testOpticalFlowResolutionPlannerAndCandidateFallback() throws {
        XCTAssertEqual(OpticalFlowResolutionPlanner.alignEven(63), 64)
        XCTAssertEqual(OpticalFlowResolutionPlanner.alignEven(1481), 1480)

        let fitted2960 = OpticalFlowResolutionPlanner.fitProportionally(
            width: 2960,
            height: 2160,
            maxLongSide: 1920,
            maxShortSide: 1080
        )
        XCTAssertEqual(fitted2960.width, 1480)
        XCTAssertEqual(fitted2960.height, 1080)

        let fitted4K = OpticalFlowResolutionPlanner.fitProportionally(
            width: 3840,
            height: 2160,
            maxLongSide: 1920,
            maxShortSide: 1080
        )
        XCTAssertEqual(fitted4K.width, 1920)
        XCTAssertEqual(fitted4K.height, 1080)

        let fittedPortrait = OpticalFlowResolutionPlanner.fitProportionally(
            width: 2160,
            height: 3840,
            maxLongSide: 1920,
            maxShortSide: 1080
        )
        XCTAssertEqual(fittedPortrait.width, 1080)
        XCTAssertEqual(fittedPortrait.height, 1920)

        let bounds = OpticalFlowResolutionPlanner.DimensionBounds(
            minWidth: 512,
            minHeight: 512,
            maxWidth: 1920,
            maxHeight: 1080
        )
        let clampedLarge = try XCTUnwrap(OpticalFlowResolutionPlanner.clampToBounds(width: 2960, height: 2160, bounds: bounds))
        XCTAssertEqual(clampedLarge.width, 1480)
        XCTAssertEqual(clampedLarge.height, 1080)
        XCTAssertNil(OpticalFlowResolutionPlanner.clampToBounds(width: 480, height: 360, bounds: bounds))

        // 2x 模式：LowLatency 全分辨率档位严格排在 FRC 之前
        let plan4K = OpticalFlowResolutionPlanner.buildCandidatePlan(
            sourceWidth: 2960,
            sourceHeight: 2160,
            requestedSpatial2x: true,
            lowLatencySupported: true,
            frcSupported: true
        )
        XCTAssertFalse(plan4K.contains(where: { $0.spatial2x }), "4K 片源应禁止 spatial2x")
        XCTAssertEqual(Array(plan4K.prefix(3)), [
            OpticalFlowCandidate(backend: .lowLatency, width: 1480, height: 1080, spatial2x: false),
            OpticalFlowCandidate(backend: .lowLatency, width: 986, height: 720, spatial2x: false),
            OpticalFlowCandidate(backend: .lowLatency, width: 740, height: 540, spatial2x: false)
        ])
        XCTAssertEqual(plan4K.dropFirst(3).first, OpticalFlowCandidate(backend: .frameRateConversion, width: 1480, height: 1080, spatial2x: false))
        XCTAssertEqual(Set(plan4K).count, plan4K.count)

        // 120fps (maxInterpolatedFrames=4)：跳过 1080p，直接 720p -> 540p -> 480p 且全为 LowLatency 在前
        let plan120 = OpticalFlowResolutionPlanner.buildCandidatePlan(
            sourceWidth: 2960,
            sourceHeight: 2160,
            requestedSpatial2x: false,
            lowLatencySupported: true,
            frcSupported: true,
            maxInterpolatedFrames: 4
        )
        XCTAssertEqual(Array(plan120.prefix(3)), [
            OpticalFlowCandidate(backend: .lowLatency, width: 986, height: 720, spatial2x: false, maxInterpolatedFrames: 4),
            OpticalFlowCandidate(backend: .lowLatency, width: 740, height: 540, spatial2x: false, maxInterpolatedFrames: 4),
            OpticalFlowCandidate(backend: .lowLatency, width: 656, height: 480, spatial2x: false, maxInterpolatedFrames: 4)
        ])

        // 96fps (maxInterpolatedFrames=3)：跳过 1080p，直接从 720p -> 540p 起跑
        let plan96 = OpticalFlowResolutionPlanner.buildCandidatePlan(
            sourceWidth: 2960,
            sourceHeight: 2160,
            requestedSpatial2x: false,
            lowLatencySupported: true,
            frcSupported: true,
            maxInterpolatedFrames: 3
        )
        XCTAssertEqual(Array(plan96.prefix(2)), [
            OpticalFlowCandidate(backend: .lowLatency, width: 986, height: 720, spatial2x: false, maxInterpolatedFrames: 3),
            OpticalFlowCandidate(backend: .lowLatency, width: 740, height: 540, spatial2x: false, maxInterpolatedFrames: 3)
        ])

        let plan1080Spatial = OpticalFlowResolutionPlanner.buildCandidatePlan(
            sourceWidth: 1920,
            sourceHeight: 1080,
            requestedSpatial2x: true,
            lowLatencySupported: true,
            frcSupported: true
        )
        XCTAssertEqual(plan1080Spatial.first, OpticalFlowCandidate(backend: .lowLatency, width: 1920, height: 1080, spatial2x: true))
        XCTAssertTrue(plan1080Spatial.contains(OpticalFlowCandidate(backend: .lowLatency, width: 1920, height: 1080, spatial2x: false)))

        let planFRCOnly = OpticalFlowResolutionPlanner.buildCandidatePlan(
            sourceWidth: 1920,
            sourceHeight: 1080,
            requestedSpatial2x: true,
            lowLatencySupported: false,
            frcSupported: true
        )
        XCTAssertTrue(planFRCOnly.allSatisfy { $0.backend == .frameRateConversion && !$0.spatial2x })
        XCTAssertEqual(planFRCOnly.count, 3)

        let planBounded = OpticalFlowResolutionPlanner.buildCandidatePlan(
            sourceWidth: 1920,
            sourceHeight: 1080,
            requestedSpatial2x: false,
            lowLatencySupported: true,
            frcSupported: true,
            lowLatencyBounds: OpticalFlowResolutionPlanner.DimensionBounds(minWidth: 0, minHeight: 0, maxWidth: 1280, maxHeight: 720),
            frcBounds: OpticalFlowResolutionPlanner.DimensionBounds(minWidth: 0, minHeight: 0, maxWidth: 1920, maxHeight: 1080)
        )
        XCTAssertFalse(planBounded.contains(OpticalFlowCandidate(backend: .lowLatency, width: 1920, height: 1080, spatial2x: false)))
        XCTAssertTrue(planBounded.contains(OpticalFlowCandidate(backend: .lowLatency, width: 1280, height: 720, spatial2x: false)))
        XCTAssertTrue(planBounded.contains(OpticalFlowCandidate(backend: .frameRateConversion, width: 1920, height: 1080, spatial2x: false)))

        let planEmpty = OpticalFlowResolutionPlanner.buildCandidatePlan(
            sourceWidth: 1920,
            sourceHeight: 1080,
            requestedSpatial2x: true,
            lowLatencySupported: false,
            frcSupported: false
        )
        XCTAssertTrue(planEmpty.isEmpty)
    }

    func testOpticalFlowPhaseSchedulerAndMultiTierTargets() throws {
        XCTAssertTrue(OpticalFlowTargetFPS.x2.allowsSpatial2x)
        XCTAssertFalse(OpticalFlowTargetFPS.fps60.allowsSpatial2x)
        XCTAssertFalse(OpticalFlowTargetFPS.fps72.allowsSpatial2x)
        XCTAssertFalse(OpticalFlowTargetFPS.fps96.allowsSpatial2x)
        XCTAssertFalse(OpticalFlowTargetFPS.fps120.allowsSpatial2x)

        XCTAssertEqual(OpticalFlowTargetFPS.fps120.nextLowerTier, .fps96)
        XCTAssertEqual(OpticalFlowTargetFPS.fps96.nextLowerTier, .fps72)
        XCTAssertEqual(OpticalFlowTargetFPS.fps72.nextLowerTier, .fps60)
        XCTAssertEqual(OpticalFlowTargetFPS.fps60.nextLowerTier, .x2)
        XCTAssertNil(OpticalFlowTargetFPS.x2.nextLowerTier)

        XCTAssertEqual(OpticalFlowTargetFPS.x2.effectiveTargetFPS(sourceFPS: 23.976), 47.952, accuracy: 0.01)
        XCTAssertEqual(OpticalFlowTargetFPS.fps60.effectiveTargetFPS(sourceFPS: 24.0), 60.0, accuracy: 0.01)
        XCTAssertEqual(OpticalFlowTargetFPS.fps60.effectiveTargetFPS(sourceFPS: 60.0), 60.0, accuracy: 0.01)

        XCTAssertEqual(OpticalFlowTargetFPS.x2.maxInterpolatedFramesPerPair(sourceFPS: 24.0), 1)
        XCTAssertEqual(OpticalFlowTargetFPS.fps60.maxInterpolatedFramesPerPair(sourceFPS: 24.0), 3)
        XCTAssertEqual(OpticalFlowTargetFPS.fps72.maxInterpolatedFramesPerPair(sourceFPS: 24.0), 2)
        XCTAssertEqual(OpticalFlowTargetFPS.fps96.maxInterpolatedFramesPerPair(sourceFPS: 24.0), 3)
        XCTAssertEqual(OpticalFlowTargetFPS.fps120.maxInterpolatedFramesPerPair(sourceFPS: 24.0), 4)
        XCTAssertEqual(OpticalFlowTargetFPS.fps60.maxInterpolatedFramesPerPair(sourceFPS: 60.0), 0)

        let limits48 = OpticalFlowResolutionPlanner.recommendedQueueLimits(targetFPS: 48.0)
        let limits120 = OpticalFlowResolutionPlanner.recommendedQueueLimits(targetFPS: 120.0)
        XCTAssertEqual(limits48.maxQueued, 24)
        XCTAssertEqual(limits48.prebuffer, 7)
        XCTAssertEqual(limits120.maxQueued, 60)
        XCTAssertEqual(limits120.prebuffer, 18)

        let frcPlan = OpticalFlowResolutionPlanner.buildCandidatePlan(
            sourceWidth: 1920,
            sourceHeight: 1080,
            requestedSpatial2x: true,
            lowLatencySupported: true,
            frcSupported: true,
            preferFRC: true,
            maxInterpolatedFrames: 4
        )
        XCTAssertEqual(frcPlan.first?.backend, .frameRateConversion)
        XCTAssertEqual(frcPlan.first?.maxInterpolatedFrames, 4)
        XCTAssertFalse(frcPlan.contains(where: { $0.spatial2x }))
        XCTAssertTrue(frcPlan.first?.displayLabel.contains("[×5]") == true)

        var sched72 = OpticalFlowPhaseScheduler(targetTier: .fps72, sourceFPS: 24.0)
        let step72 = sched72.planStep(previousPTS: 0.0, currentPTS: 1.0 / 24.0, maxAllowedSlots: 4)
        XCTAssertTrue(step72.shouldEmitOriginalFrame)
        XCTAssertEqual(step72.interpolatedSlots.count, 2)
        XCTAssertEqual(Double(step72.interpolatedSlots[0].phase), 1.0 / 3.0, accuracy: 0.005)
        XCTAssertEqual(Double(step72.interpolatedSlots[1].phase), 2.0 / 3.0, accuracy: 0.005)

        var sched120 = OpticalFlowPhaseScheduler(targetTier: .fps120, sourceFPS: 24.0)
        let step120 = sched120.planStep(previousPTS: 0.0, currentPTS: 1.0 / 24.0, maxAllowedSlots: 4)
        XCTAssertEqual(step120.interpolatedSlots.count, 4)
        XCTAssertEqual(Double(step120.interpolatedSlots[0].phase), 0.2, accuracy: 0.005)
        XCTAssertEqual(Double(step120.interpolatedSlots[3].phase), 0.8, accuracy: 0.005)

        var sched60 = OpticalFlowPhaseScheduler(targetTier: .fps60, sourceFPS: 24.0)
        var generatedPTS: [Double] = [0.0]
        for idx in 1...24 {
            let prev = Double(idx - 1) / 24.0
            let curr = Double(idx) / 24.0
            let step = sched60.planStep(previousPTS: prev, currentPTS: curr, maxAllowedSlots: 3)
            var lastPhase: Float = 0
            for slot in step.interpolatedSlots {
                XCTAssertGreaterThan(slot.phase, 0)
                XCTAssertLessThan(slot.phase, 1)
                XCTAssertGreaterThan(slot.phase, lastPhase)
                lastPhase = slot.phase
                generatedPTS.append(slot.pts)
            }
            if step.shouldEmitOriginalFrame {
                generatedPTS.append(curr)
            }
        }
        XCTAssertTrue((58...62).contains(generatedPTS.count), "24p->60fps 1秒总输出帧应约60帧，实际=\(generatedPTS.count)")
        for i in 1..<generatedPTS.count {
            XCTAssertGreaterThan(generatedPTS[i], generatedPTS[i - 1], "重采样 PTS 必须严格单调递增")
        }

        var guardState = OpticalFlowBudgetGuard(
            windowSize: 2,
            overloadRatioThreshold: 0.85,
            consecutiveOverloadWindowsRequired: 2,
            maxConsecutiveCatchUpSkips: 2,
            cooldownPairs: 2
        )
        XCTAssertEqual(guardState.recordPair(processMs: 38, sourceIntervalMs: 41.6, skippedForCatchUp: false, canDowngradeResolution: true, canDowngradeTargetFPS: true), .keep)
        XCTAssertEqual(guardState.recordPair(processMs: 38, sourceIntervalMs: 41.6, skippedForCatchUp: false, canDowngradeResolution: true, canDowngradeTargetFPS: true), .keep)
        XCTAssertEqual(guardState.recordPair(processMs: 39, sourceIntervalMs: 41.6, skippedForCatchUp: false, canDowngradeResolution: true, canDowngradeTargetFPS: true), .keep)
        XCTAssertEqual(guardState.recordPair(processMs: 39, sourceIntervalMs: 41.6, skippedForCatchUp: false, canDowngradeResolution: true, canDowngradeTargetFPS: true), .downgradeResolution)
        XCTAssertEqual(guardState.recordPair(processMs: 50, sourceIntervalMs: 41.6, skippedForCatchUp: true, canDowngradeResolution: false, canDowngradeTargetFPS: true), .keep)
        XCTAssertEqual(guardState.recordPair(processMs: 50, sourceIntervalMs: 41.6, skippedForCatchUp: true, canDowngradeResolution: false, canDowngradeTargetFPS: true), .keep)
        XCTAssertEqual(guardState.recordPair(processMs: 0, sourceIntervalMs: 41.6, skippedForCatchUp: true, canDowngradeResolution: false, canDowngradeTargetFPS: true), .keep)
        XCTAssertEqual(guardState.recordPair(processMs: 0, sourceIntervalMs: 41.6, skippedForCatchUp: true, canDowngradeResolution: false, canDowngradeTargetFPS: true), .downgradeTargetFPS)

        let verdict = InterpolationVerdict.evaluateANE(
            interpolatedCount: 120,
            failedCount: 0,
            presentedCount: 180,
            actualOutputFPS: 118.5,
            sourceFPS: 24.0,
            errorMessage: nil,
            targetLabel: "120fps→96fps"
        )
        XCTAssertTrue(verdict.detailText.contains("目标 120fps→96fps"))

        let sample = RuntimeTelemetrySample(
            playbackState: "播放中",
            mediaTime: 3.5,
            width: 1480,
            height: 1080,
            sourceFPS: 24.0,
            outputFPS: 95.8,
            droppedFrames: 0,
            aneInterpolated: 150,
            aneSkipped: 1,
            aneFailed: 0,
            anePresented: 200,
            aneAvgMs: 14.2,
            aneTargetFPS: "96fps",
            verdictLabel: "ANE光流生效",
            thermalLevel: .nominal
        )
        XCTAssertTrue(sample.formatLogLine().contains("target=96fps"))
    }

    func testOpticalFlowExponentPixelFormatAndThermalPolicy() {
        XCTAssertEqual(OpticalFlowResolutionPlanner.lowLatencyExponent(forInterpolatedFrames: 1), 1)
        XCTAssertEqual(OpticalFlowResolutionPlanner.lowLatencyExponent(forInterpolatedFrames: 2), 2)
        XCTAssertEqual(OpticalFlowResolutionPlanner.lowLatencyExponent(forInterpolatedFrames: 3), 2)
        XCTAssertEqual(OpticalFlowResolutionPlanner.lowLatencyExponent(forInterpolatedFrames: 4), 3)
        XCTAssertEqual(OpticalFlowResolutionPlanner.lowLatencyExponent(forInterpolatedFrames: 7), 3)

        let mixed10Supported: [OSType] = [
            kCVPixelFormatType_64RGBAHalf,
            kCVPixelFormatType_128RGBAFloat,
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let chosen10 = OpticalFlowResolutionPlanner.selectOptimalPixelFormat(from: mixed10Supported, prefer10Bit: true)
        XCTAssertEqual(chosen10, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        let chosen8 = OpticalFlowResolutionPlanner.selectOptimalPixelFormat(from: mixed10Supported, prefer10Bit: false)
        XCTAssertEqual(chosen8, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        let heavyOnly: [OSType] = [kCVPixelFormatType_128RGBAFloat, kCVPixelFormatType_64RGBAHalf]
        XCTAssertEqual(
            OpticalFlowResolutionPlanner.selectOptimalPixelFormat(from: heavyOnly, prefer10Bit: false),
            kCVPixelFormatType_64RGBAHalf
        )

        let decodeFormats = OpticalFlowResolutionPlanner.nativeDecodePixelFormats(
            prefer10Bit: false,
            preferredPixelFormat: kCVPixelFormatType_64RGBAHalf
        )
        XCTAssertFalse(decodeFormats.contains(kCVPixelFormatType_64RGBAHalf))
        XCTAssertFalse(decodeFormats.contains(kCVPixelFormatType_128RGBAFloat))
        XCTAssertEqual(decodeFormats.first, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        let heavyLimits = OpticalFlowResolutionPlanner.recommendedQueueLimits(targetFPS: 120.0, isHeavyPixelFormat: true)
        XCTAssertLessThanOrEqual(heavyLimits.maxQueued, 30)
        XCTAssertLessThanOrEqual(heavyLimits.prebuffer, 10)

        let range48 = OpticalFlowResolutionPlanner.recommendedDisplayFrameRateRange(targetFPS: 48.0)
        XCTAssertEqual(range48.maximum, 60)
        XCTAssertEqual(range48.preferred, 48)
        let range120 = OpticalFlowResolutionPlanner.recommendedDisplayFrameRateRange(targetFPS: 120.0)
        XCTAssertEqual(range120.maximum, 120)
        XCTAssertEqual(range120.preferred, 120)

        XCTAssertNil(OpticalFlowResolutionPlanner.thermalMaxTargetTier(for: .nominal))
        XCTAssertNil(OpticalFlowResolutionPlanner.thermalMaxTargetTier(for: .fair))
        XCTAssertEqual(OpticalFlowResolutionPlanner.thermalMaxTargetTier(for: .serious), .fps60)
        XCTAssertEqual(OpticalFlowResolutionPlanner.thermalMaxTargetTier(for: .critical), .x2)
        XCTAssertEqual(OpticalFlowResolutionPlanner.exceedsThermalCap(active: .fps120, thermalState: .serious), .fps60)
        XCTAssertNil(OpticalFlowResolutionPlanner.exceedsThermalCap(active: .fps60, thermalState: .serious))
        XCTAssertEqual(OpticalFlowResolutionPlanner.exceedsThermalCap(active: .fps60, thermalState: .critical), .x2)
    }

    @MainActor
    func testCoordinatorIdempotencyAndPassthroughMode() async throws {
        let coordinator = PlayerCoordinator()
        defer { coordinator.closeToHome() }

        XCTAssertEqual(coordinator.interpolationMode, .vtOpticalFlow)
        XCTAssertEqual(coordinator.opticalFlowTargetFPS, .x2)

        // 幂等防护：重复设置相同的 2× 不应触发冗余审计日志
        coordinator.setOpticalFlowTargetFPS(.x2)
        XCTAssertEqual(coordinator.uiAuditLogs.count, 0)

        // 若自动降档至 96fps，即使 requested 仍为 120fps，再次点选 120fps 应放行重试
        coordinator.setOpticalFlowTargetFPS(.fps120)
        XCTAssertEqual(coordinator.uiAuditLogs.count, 1)
        coordinator.opticalFlowController.effectiveTargetFPS = .fps96
        coordinator.setOpticalFlowTargetFPS(.fps120)
        XCTAssertEqual(coordinator.uiAuditLogs.count, 2)

        // 切换至原帧率直通并验证跨平台直通播放可在模拟器完成
        let displayContainer = SampleBufferDisplayContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        coordinator.opticalFlowController.attach(to: displayContainer)
        defer { _ = displayContainer }

        coordinator.setInterpolation(.off)
        XCTAssertEqual(coordinator.interpolationMode, .off)
        XCTAssertEqual(coordinator.hudMetrics.engineBadge, "PASS")

        let sampleURL = try await TestVideoGenerator.generateSampleMP4(
            durationSeconds: 1.5,
            width: 320,
            height: 180,
            fps: 24
        )
        coordinator.open(url: sampleURL, isSecurityScoped: false)

        let deadline = Date().addingTimeInterval(15.0)
        while Date() < deadline {
            if coordinator.opticalFlowController.errorMessage != nil {
                break
            }
            if coordinator.opticalFlowController.presentedFrameCount > 0 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(coordinator.opticalFlowController.errorMessage)
        XCTAssertGreaterThan(coordinator.opticalFlowController.presentedFrameCount, 0)
        XCTAssertEqual(coordinator.opticalFlowController.activeBackendLabel, "原帧率直通")
        XCTAssertFalse(coordinator.opticalFlowController.isInterpolationEnabled)
    }

    @MainActor
    func testDiagnosticLogUpgradeSessionSummaryAndMemorySampler() {
        let memMB = DeviceDiagnosticsSampler.currentMemoryFootprintMB()
        XCTAssertGreaterThan(memMB, 0)
        let deviceLine = DeviceDiagnosticsSampler.deviceSummaryLine(maxScreenFPS: 120)
        XCTAssertTrue(deviceLine.contains("ScreenMax=120Hz"))
        XCTAssertTrue(deviceLine.contains("AppMem="))

        let sample = RuntimeTelemetrySample(
            playbackState: "播放中",
            mediaTime: 8.5,
            width: 1480,
            height: 1080,
            sourceFPS: 24.0,
            outputFPS: 96.0,
            droppedFrames: 0,
            aneInterpolated: 60,
            aneSkipped: 0,
            aneFailed: 0,
            anePresented: 90,
            aneAvgMs: 12.4,
            aneTargetFPS: "96fps",
            aneBackend: "LowLatency 986×720 [×4]",
            aneQueueDepth: 14,
            avDeltaMs: 18.2,
            memoryFootprintMB: memMB,
            verdictLabel: "ANE光流生效",
            thermalLevel: .nominal
        )
        let line = sample.formatLogLine()
        let timeRegex = try? NSRegularExpression(pattern: #"^\[\d{2}:\d{2}:\d{2}\.\d{3}\]"#)
        let fullRange = NSRange(location: 0, length: line.utf16.count)
        XCTAssertNotNil(timeRegex?.firstMatch(in: line, range: fullRange), "日志时间戳应精确至毫秒 HH:mm:ss.SSS: \(line)")
        XCTAssertTrue(line.contains("backend=LowLatency 986×720 [×4]"))
        XCTAssertTrue(line.contains("q=14"))
        XCTAssertTrue(line.contains("avDelta=+18.2ms"))
        XCTAssertTrue(line.contains("mem="))

        let report = DiagnosticLogExporter.buildReport(
            version: "v2026.11.27",
            deviceInfo: deviceLine,
            engineName: "ANE 光流核",
            playbackState: "播放中",
            resolution: "2960×2160",
            fpsSummary: "24.0 → 96.0 fps",
            decoderSummary: "HEVC / VT+LowLatency",
            is4KGated: true,
            telemetrySummary: ["Snapshot Source: last-session"],
            runtimeTimeline: [line],
            uiAuditLogs: ["[09:20:01.123] [ui-switch] setOpticalFlowTargetFPS 2× -> 120fps"],
            selfCheck: "ok",
            opticalLogs: []
        )
        XCTAssertTrue(report.contains("Device: \(deviceLine)"))
        XCTAssertTrue(report.contains("--- UI Switch Audit (1) ---"))

        let coordinator = PlayerCoordinator()
        coordinator.currentURL = URL(fileURLWithPath: "/tmp/sample.mp4")
        coordinator.opticalFlowController.videoWidth = 1920
        coordinator.opticalFlowController.videoHeight = 1080
        coordinator.opticalFlowController.videoCodec = "hevc"
        coordinator.captureRuntimeTelemetrySample()
        coordinator.closeToHome()
        XCTAssertNil(coordinator.currentURL)
        XCTAssertEqual(coordinator.lastSessionSummary?.resolution, "1920×1080")
        XCTAssertEqual(coordinator.lastSessionSummary?.mediaFilename, "sample.mp4")
    }
}
