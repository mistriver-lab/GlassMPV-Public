import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import Network
import QuartzCore
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
        XCTAssertEqual(PlaybackHUDMetrics.formatHDRTag(isHDRContent: true, transferName: nil, isHDRActive: false, isDolbyVision: true), "杜比视界")
        XCTAssertEqual(PlaybackHUDMetrics.formatHDRTag(isHDRContent: true, transferName: nil, isHDRActive: true, isDolbyVision: true), "杜比视界✓")
        XCTAssertEqual(PlaybackHUDMetrics.formatCodecName("dvh1"), "HEVC (DV)")
        XCTAssertEqual(PlaybackHUDMetrics.formatCodecName("dav1"), "AV1 (DV)")

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
            version: "v0.1.0-beta.1",
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
        XCTAssertTrue(report.contains("GlassMPV v0.1.0-beta.1"))
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
            version: "v0.1.0-beta.1",
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
        XCTAssertFalse(OpticalFlowTargetFPS.fps96.allowsSpatial2x)
        XCTAssertFalse(OpticalFlowTargetFPS.fps120.allowsSpatial2x)
        XCTAssertEqual(OpticalFlowTargetFPS.allCases, [.x2, .fps60, .fps96, .fps120])

        XCTAssertEqual(OpticalFlowTargetFPS.fps120.nextLowerTier, .fps96)
        XCTAssertEqual(OpticalFlowTargetFPS.fps96.nextLowerTier, .fps60)
        XCTAssertEqual(OpticalFlowTargetFPS.fps60.nextLowerTier, .x2)
        XCTAssertNil(OpticalFlowTargetFPS.x2.nextLowerTier)

        let planMaxInterp2 = OpticalFlowResolutionPlanner.buildCandidatePlan(
            sourceWidth: 2960,
            sourceHeight: 2160,
            requestedSpatial2x: false,
            lowLatencySupported: true,
            frcSupported: true,
            maxInterpolatedFrames: 2
        )
        XCTAssertEqual(planMaxInterp2.first, OpticalFlowCandidate(backend: .lowLatency, width: 986, height: 720, spatial2x: false, maxInterpolatedFrames: 2))

        let presets24 = OpticalFlowTargetFPS.smartPresets(forSourceFPS: 23.976)
        XCTAssertEqual(presets24.map(\.target), [nil, .x2, .fps60, .fps96, .fps120])
        XCTAssertEqual(presets24.map(\.primaryTitle), ["原画", "48 fps", "60 fps", "96 fps", "120 fps"])

        let presets30 = OpticalFlowTargetFPS.smartPresets(forSourceFPS: 30.0)
        XCTAssertEqual(presets30.map(\.target), [nil, .x2, .fps120])

        let presets60 = OpticalFlowTargetFPS.smartPresets(forSourceFPS: 60.0)
        XCTAssertEqual(presets60.map(\.target), [nil, .fps120])

        XCTAssertEqual(OpticalFlowTargetFPS.x2.effectiveTargetFPS(sourceFPS: 23.976), 47.952, accuracy: 0.01)
        XCTAssertEqual(OpticalFlowTargetFPS.fps60.effectiveTargetFPS(sourceFPS: 24.0), 60.0, accuracy: 0.01)
        XCTAssertEqual(OpticalFlowTargetFPS.fps60.effectiveTargetFPS(sourceFPS: 60.0), 60.0, accuracy: 0.01)

        XCTAssertEqual(OpticalFlowTargetFPS.x2.maxInterpolatedFramesPerPair(sourceFPS: 24.0), 1)
        XCTAssertEqual(OpticalFlowTargetFPS.fps60.maxInterpolatedFramesPerPair(sourceFPS: 24.0), 3)
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

        var sched96 = OpticalFlowPhaseScheduler(targetTier: .fps96, sourceFPS: 24.0)
        let step96 = sched96.planStep(previousPTS: 0.0, currentPTS: 1.0 / 24.0, maxAllowedSlots: 4)
        XCTAssertTrue(step96.shouldEmitOriginalFrame)
        XCTAssertEqual(step96.interpolatedSlots.count, 3)
        XCTAssertEqual(Double(step96.interpolatedSlots[0].phase), 0.25, accuracy: 0.005)
        XCTAssertEqual(Double(step96.interpolatedSlots[1].phase), 0.50, accuracy: 0.005)
        XCTAssertEqual(Double(step96.interpolatedSlots[2].phase), 0.75, accuracy: 0.005)

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

        let rangeInterp48 = OpticalFlowResolutionPlanner.recommendedDisplayFrameRateRange(
            targetFPS: 47.952,
            isInterpolationEnabled: true,
            maxScreenFPS: 120
        )
        XCTAssertEqual(rangeInterp48.minimum, 48)
        XCTAssertEqual(rangeInterp48.maximum, 48)
        XCTAssertEqual(rangeInterp48.preferred, 48)

        let rangeInterp60Lock = OpticalFlowResolutionPlanner.recommendedDisplayFrameRateRange(
            targetFPS: 60.0,
            isInterpolationEnabled: true,
            maxScreenFPS: 120
        )
        XCTAssertEqual(rangeInterp60Lock.minimum, 60)
        XCTAssertEqual(rangeInterp60Lock.maximum, 60)
        XCTAssertEqual(rangeInterp60Lock.preferred, 60)

        let rangeInterp96Lock = OpticalFlowResolutionPlanner.recommendedDisplayFrameRateRange(
            targetFPS: 96.0,
            isInterpolationEnabled: true,
            maxScreenFPS: 120
        )
        XCTAssertEqual(rangeInterp96Lock.minimum, 80)
        XCTAssertEqual(rangeInterp96Lock.maximum, 120)
        XCTAssertEqual(rangeInterp96Lock.preferred, 120)

        let rangeInterp120 = OpticalFlowResolutionPlanner.recommendedDisplayFrameRateRange(
            targetFPS: 120.0,
            isInterpolationEnabled: true,
            maxScreenFPS: 120
        )
        XCTAssertEqual(rangeInterp120.minimum, 80)
        XCTAssertEqual(rangeInterp120.maximum, 120)
        XCTAssertEqual(rangeInterp120.preferred, 120)

        let rangeInterpLowPower = OpticalFlowResolutionPlanner.recommendedDisplayFrameRateRange(
            targetFPS: 120.0,
            isInterpolationEnabled: true,
            maxScreenFPS: 120,
            isLowPowerMode: true
        )
        XCTAssertEqual(rangeInterpLowPower.minimum, 60)
        XCTAssertEqual(rangeInterpLowPower.maximum, 60)
        XCTAssertEqual(rangeInterpLowPower.preferred, 60)

        let rangeInterp60 = OpticalFlowResolutionPlanner.recommendedDisplayFrameRateRange(
            targetFPS: 48.0,
            isInterpolationEnabled: true,
            maxScreenFPS: 60
        )
        XCTAssertEqual(rangeInterp60.maximum, 60)
        XCTAssertEqual(rangeInterp60.preferred, 60)

        let rangePassthrough = OpticalFlowResolutionPlanner.recommendedDisplayFrameRateRange(
            targetFPS: 48.0,
            isInterpolationEnabled: false,
            maxScreenFPS: 120
        )
        XCTAssertEqual(rangePassthrough.maximum, 60)
        XCTAssertEqual(rangePassthrough.preferred, 48)

        XCTAssertEqual(
            OpticalFlowResolutionPlanner.effectivePowerThermalCap(active: .fps120, thermalState: .nominal, isLowPowerMode: true)?.tier,
            .fps60
        )
        XCTAssertEqual(
            OpticalFlowResolutionPlanner.effectivePowerThermalCap(active: .fps96, thermalState: .nominal, isLowPowerMode: true)?.tier,
            .fps60
        )
        XCTAssertNil(
            OpticalFlowResolutionPlanner.effectivePowerThermalCap(active: .fps60, thermalState: .nominal, isLowPowerMode: true)
        )
        XCTAssertEqual(
            OpticalFlowResolutionPlanner.effectivePowerThermalCap(active: .fps60, thermalState: .critical, isLowPowerMode: false)?.tier,
            .x2
        )

        XCTAssertNil(OpticalFlowResolutionPlanner.thermalMaxTargetTier(for: .nominal))
        XCTAssertNil(OpticalFlowResolutionPlanner.thermalMaxTargetTier(for: .fair))
        XCTAssertEqual(OpticalFlowResolutionPlanner.thermalMaxTargetTier(for: .serious), .x2)
        XCTAssertEqual(OpticalFlowResolutionPlanner.thermalMaxTargetTier(for: .critical), .x2)
        XCTAssertEqual(OpticalFlowResolutionPlanner.exceedsThermalCap(active: .fps120, thermalState: .serious), .x2)
        XCTAssertEqual(OpticalFlowResolutionPlanner.exceedsThermalCap(active: .fps60, thermalState: .serious), .x2)
        XCTAssertNil(OpticalFlowResolutionPlanner.exceedsThermalCap(active: .x2, thermalState: .serious))
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
            version: "v0.1.0-beta.1",
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

    @MainActor
    func testIdentifiableSelectionTagsDolbyVisionAndDisplaySwitches() throws {
        // 确保 Identifiable id 为自身而非 String，防止 SwiftUI 选择器 Tag 失配
        for tier in OpticalFlowTargetFPS.allCases {
            XCTAssertEqual(tier.id, tier)
        }
        for mode in InterpolationMode.allCases {
            XCTAssertEqual(mode.id, mode)
        }

        let coordinator = PlayerCoordinator()
        defer { coordinator.closeToHome() }

        coordinator.selectFrameRateOption(.fps96)
        XCTAssertEqual(coordinator.interpolationMode, .vtOpticalFlow)
        XCTAssertEqual(coordinator.opticalFlowTargetFPS, .fps96)
        XCTAssertEqual(coordinator.opticalFlowController.requestedTargetFPS, .fps96)

        coordinator.selectFrameRateOption(.fps120)
        XCTAssertEqual(coordinator.opticalFlowTargetFPS, .fps120)
        XCTAssertEqual(coordinator.opticalFlowController.requestedTargetFPS, .fps120)

        coordinator.selectFrameRateOption(nil)
        XCTAssertEqual(coordinator.interpolationMode, .off)

        coordinator.selectFrameRateOption(.x2)
        XCTAssertEqual(coordinator.interpolationMode, .vtOpticalFlow)
        XCTAssertEqual(coordinator.opticalFlowTargetFPS, .x2)

        coordinator.setEDREnabled(false)
        XCTAssertFalse(coordinator.isEDREnabled)
        XCTAssertFalse(coordinator.opticalFlowController.isEDREnabled)
        coordinator.setEDREnabled(true)
        XCTAssertTrue(coordinator.opticalFlowController.isEDREnabled)

        coordinator.setAspectFill(true)
        XCTAssertTrue(coordinator.opticalFlowController.isAspectFill)

        coordinator.setLooping(false)
        XCTAssertFalse(coordinator.opticalFlowController.isLoopingEnabled)

        // Dolby Vision 描述归一化保留 dvcC 与 passthrough 优先级
        var dvDescOpt: CMVideoFormatDescription?
        let dvAtoms: [String: Any] = [
            "hvcC": Data([1, 2, 3, 4]),
            "dvcC": Data([1, 0, 0, 5])
        ]
        let dvExt: [String: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: dvAtoms,
            kCMFormatDescriptionExtension_TransferFunction as String: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
        ]
        let dvStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: HEVCFormatNormalizer.fourCCCode("dvhe"),
            width: 3840,
            height: 2160,
            extensions: dvExt as CFDictionary,
            formatDescriptionOut: &dvDescOpt
        )
        XCTAssertEqual(dvStatus, noErr)
        let dvDesc = try XCTUnwrap(dvDescOpt)
        let dvCandidates = HEVCFormatNormalizer.makeNormalizedFormatDescriptionCandidates(from: dvDesc)
        XCTAssertEqual(dvCandidates.first?.strategy, "dvhe-to-dvh1")
        XCTAssertTrue(dvCandidates.contains(where: { $0.strategy == "passthrough" }))
        let cleanAtoms = (CMFormatDescriptionGetExtensions(dvCandidates[0].description) as? [String: Any])?[
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String
        ] as? [String: Any]
        XCTAssertNotNil(cleanAtoms?["dvcC"])
    }

    @MainActor
    func testProMotionPulseLayerFramePacerAndDecodeScalePlanner() async throws {
        // 1. OpticalFlowFramePacer：轻微迟到批次在 55ms 容错内逐帧送显而不被同帧丢弃，仅超 55ms 且有新帧时丢弃过期帧
        var pacerQueue: [(pts: Double, buffer: String)] = [
            (0.975, "f1"),
            (0.992, "f2"),
            (1.000, "f3")
        ]
        let tick1 = OpticalFlowFramePacer.dequeueNextFrame(from: &pacerQueue, now: 1.010, isInterpolationEnabled: true)
        XCTAssertEqual(tick1.frame, "f1")
        XCTAssertEqual(tick1.droppedCount, 0)
        XCTAssertEqual(pacerQueue.count, 2)

        let tick2 = OpticalFlowFramePacer.dequeueNextFrame(from: &pacerQueue, now: 1.018, isInterpolationEnabled: true)
        XCTAssertEqual(tick2.frame, "f2")
        XCTAssertEqual(tick2.droppedCount, 0)
        XCTAssertEqual(pacerQueue.count, 1)

        let tick3 = OpticalFlowFramePacer.dequeueNextFrame(from: &pacerQueue, now: 1.026, isInterpolationEnabled: true)
        XCTAssertEqual(tick3.frame, "f3")
        XCTAssertEqual(tick3.droppedCount, 0)
        XCTAssertTrue(pacerQueue.isEmpty)

        var staleQueue: [(pts: Double, buffer: String)] = [
            (0.940, "stale"),
            (0.980, "recent"),
            (1.010, "next")
        ]
        let staleStep = OpticalFlowFramePacer.dequeueNextFrame(from: &staleQueue, now: 1.010, isInterpolationEnabled: true)
        XCTAssertEqual(staleStep.frame, "recent")
        XCTAssertEqual(staleStep.droppedCount, 1)
        XCTAssertEqual(staleQueue.count, 1)

        // 2. SampleBufferDisplayContainerView：微扰层位于安全视口内，且连续两次提交产生不同透明度与亚像素偏移
        let container = SampleBufferDisplayContainerView(frame: CGRect(x: 0, y: 0, width: 852, height: 393))
        container.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(container.proMotionPulseLayer.frame.origin.x, 64.0)
        XCTAssertGreaterThanOrEqual(container.proMotionPulseLayer.frame.origin.y, 12.0)

        container.pulseProMotionCommit()
        let opacityA = container.proMotionPulseLayer.opacity
        let xA = container.proMotionPulseLayer.frame.origin.x
        XCTAssertGreaterThan(opacityA, 0)

        container.pulseProMotionCommit()
        let opacityB = container.proMotionPulseLayer.opacity
        let xB = container.proMotionPulseLayer.frame.origin.x
        XCTAssertGreaterThan(opacityB, 0)
        XCTAssertNotEqual(opacityA, opacityB)
        XCTAssertNotEqual(xA, xB)

        // 3. 4K 光流硬件缩放解码尺寸规划
        let scaled4K = try XCTUnwrap(
            OpticalFlowResolutionPlanner.recommendedDecodeDimensions(
                sourceWidth: 2960,
                sourceHeight: 2160,
                forOpticalFlow: true
            )
        )
        XCTAssertEqual(scaled4K.width, 1480)
        XCTAssertEqual(scaled4K.height, 1080)
        XCTAssertNil(
            OpticalFlowResolutionPlanner.recommendedDecodeDimensions(
                sourceWidth: 1920,
                sourceHeight: 1080,
                forOpticalFlow: true
            )
        )
        XCTAssertNil(
            OpticalFlowResolutionPlanner.recommendedDecodeDimensions(
                sourceWidth: 2960,
                sourceHeight: 2160,
                forOpticalFlow: false
            )
        )

        // 4. OpticalFlowDecodedFramePipe 有界 FIFO 顺序与背压排空
        let pipe = OpticalFlowDecodedFramePipe(capacity: 2)
        var pbOpt: CVPixelBuffer?
        let pbStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &pbOpt
        )
        XCTAssertEqual(pbStatus, kCVReturnSuccess)
        let pb = try XCTUnwrap(pbOpt)

        let producer = Task {
            for idx in 0..<5 {
                let pts = CMTime(value: CMTimeValue(idx), timescale: 24)
                let ok = await pipe.send(OpticalFlowSendableFrame(pts: pts, buffer: pb))
                XCTAssertTrue(ok)
            }
            pipe.finishProducer(error: nil)
        }

        var receivedValues: [CMTimeValue] = []
        while case .frame(let item) = await pipe.receive() {
            receivedValues.append(item.pts.value)
        }
        await producer.value
        XCTAssertEqual(receivedValues, [0, 1, 2, 3, 4])
    }

    @MainActor
    func testVideoEnhancementPlannerAndMetalEnhancer() throws {
        let offParams = VideoEnhancementPlanner.parameters(for: .off, strength: .standard)
        XCTAssertEqual(offParams.casStrength, 0)
        XCTAssertFalse(offParams.wantsSpatialUpscale)

        let subtleOld = VideoEnhancementPlanner.parameters(for: .old4KRestore, strength: .subtle)
        let stdOld = VideoEnhancementPlanner.parameters(for: .old4KRestore, strength: .standard)
        let strongOld = VideoEnhancementPlanner.parameters(for: .old4KRestore, strength: .strong)
        XCTAssertLessThan(subtleOld.casStrength, stdOld.casStrength)
        XCTAssertLessThan(stdOld.casStrength, strongOld.casStrength)
        XCTAssertGreaterThan(stdOld.deblurStrength, 0)
        XCTAssertLessThan(subtleOld.deblurStrength, stdOld.deblurStrength)
        XCTAssertFalse(stdOld.wantsSpatialUpscale)

        let budget24 = VideoEnhancementPlanner.effectiveUpscaleBudget(outputFPS: 24.0, thermalState: .nominal)
        XCTAssertTrue(budget24.allowSpatialUpscale)
        XCTAssertEqual(budget24.maxLongSide, 2560)

        let budget60 = VideoEnhancementPlanner.effectiveUpscaleBudget(outputFPS: 60.0, thermalState: .nominal)
        XCTAssertTrue(budget60.allowSpatialUpscale)
        XCTAssertEqual(budget60.maxLongSide, 1920)
        XCTAssertEqual(budget60.maxShortSide, 1080)

        let budget120 = VideoEnhancementPlanner.effectiveUpscaleBudget(outputFPS: 120.0, thermalState: .nominal)
        XCTAssertFalse(budget120.allowSpatialUpscale)

        let budgetSerious = VideoEnhancementPlanner.effectiveUpscaleBudget(outputFPS: 24.0, thermalState: .serious)
        XCTAssertFalse(budgetSerious.allowSpatialUpscale)

        let superParams = VideoEnhancementPlanner.parameters(for: .lowResSuperRes, strength: .standard)
        XCTAssertTrue(superParams.wantsSpatialUpscale)
        XCTAssertGreaterThan(superParams.casStrength, 0)

        let up720 = try XCTUnwrap(VideoEnhancementPlanner.recommendedUpscaleDimensions(inputWidth: 986, inputHeight: 720))
        XCTAssertEqual(up720.width, 1972)
        XCTAssertEqual(up720.height, 1440)

        let up360 = try XCTUnwrap(VideoEnhancementPlanner.recommendedUpscaleDimensions(inputWidth: 640, inputHeight: 360))
        XCTAssertEqual(up360.width, 1280)
        XCTAssertEqual(up360.height, 720)

        let up1080 = try XCTUnwrap(VideoEnhancementPlanner.recommendedUpscaleDimensions(inputWidth: 1920, inputHeight: 1080))
        XCTAssertEqual(up1080.width, 2560)
        XCTAssertEqual(up1080.height, 1440)

        XCTAssertNil(VideoEnhancementPlanner.recommendedUpscaleDimensions(inputWidth: 2960, inputHeight: 2160))

        let upPortrait = try XCTUnwrap(VideoEnhancementPlanner.recommendedUpscaleDimensions(inputWidth: 720, inputHeight: 1280))
        XCTAssertEqual(upPortrait.width, 1440)
        XCTAssertEqual(upPortrait.height, 2560)

        let coordinator = PlayerCoordinator()
        defer { coordinator.closeToHome() }
        coordinator.setVideoEnhancementPreset(.old4KRestore)
        XCTAssertEqual(coordinator.opticalFlowController.videoEnhancementPreset, .old4KRestore)
        coordinator.setVideoEnhancementStrength(.strong)
        XCTAssertEqual(coordinator.opticalFlowController.videoEnhancementStrength, .strong)
        coordinator.setComparingOriginalQuality(true)
        XCTAssertTrue(coordinator.opticalFlowController.isComparingOriginalQuality)
        XCTAssertEqual(coordinator.qualityCompareMode, .original)
        coordinator.setQualityCompareMode(.split)
        XCTAssertEqual(coordinator.opticalFlowController.qualityCompareMode, .split)
        XCTAssertFalse(coordinator.opticalFlowController.isComparingOriginalQuality)
        XCTAssertTrue(coordinator.uiAuditLogs.contains(where: { $0.contains("setVideoEnhancementPreset") }))

        let enhancer = MetalVideoEnhancer()
        var yuvOpt: CVPixelBuffer?
        let yuvStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            128,
            72,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ] as CFDictionary,
            &yuvOpt
        )
        XCTAssertEqual(yuvStatus, kCVReturnSuccess)
        let yuvBuffer = try XCTUnwrap(yuvOpt)

        CVPixelBufferLockBaseAddress(yuvBuffer, [])
        if let baseY = CVPixelBufferGetBaseAddressOfPlane(yuvBuffer, 0) {
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(yuvBuffer, 0)
            let ptr = baseY.assumingMemoryBound(to: UInt8.self)
            for row in 0..<72 {
                for col in 0..<128 {
                    ptr[row * bytesPerRow + col] = col < 64 ? 48 : 200
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(yuvBuffer, [])

        let bypassedCompare = enhancer.process(
            yuvBuffer,
            preset: .old4KRestore,
            strength: .standard,
            isHDRContent: false,
            isDolbyVision: false,
            bypassForComparison: true
        )
        XCTAssertTrue(bypassedCompare === yuvBuffer)

        let bypassedDV = enhancer.process(
            yuvBuffer,
            preset: .lowResSuperRes,
            strength: .standard,
            isHDRContent: true,
            isDolbyVision: true,
            bypassForComparison: false
        )
        XCTAssertTrue(bypassedDV === yuvBuffer)

        let restoredYUV = enhancer.process(
            yuvBuffer,
            preset: .old4KRestore,
            strength: .standard,
            isHDRContent: false,
            isDolbyVision: false
        )
        XCTAssertEqual(CVPixelBufferGetWidth(restoredYUV), 128)
        XCTAssertEqual(CVPixelBufferGetHeight(restoredYUV), 72)

        let upscaledYUV = enhancer.process(
            yuvBuffer,
            preset: .lowResSuperRes,
            strength: .standard,
            isHDRContent: false,
            isDolbyVision: false
        )
        if MTLCreateSystemDefaultDevice() != nil {
            XCTAssertEqual(CVPixelBufferGetWidth(upscaledYUV), 256)
            XCTAssertEqual(CVPixelBufferGetHeight(upscaledYUV), 144)
        }

        var bgraOpt: CVPixelBuffer?
        let bgraStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            128,
            72,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ] as CFDictionary,
            &bgraOpt
        )
        XCTAssertEqual(bgraStatus, kCVReturnSuccess)
        let bgraBuffer = try XCTUnwrap(bgraOpt)
        let animeBGRA = enhancer.process(
            bgraBuffer,
            preset: .animeLineArt,
            strength: .strong,
            isHDRContent: false,
            isDolbyVision: false
        )
        XCTAssertEqual(CVPixelBufferGetWidth(animeBGRA), 128)
        XCTAssertEqual(CVPixelBufferGetHeight(animeBGRA), 72)

        let splitYUV = enhancer.process(
            yuvBuffer,
            preset: .old4KRestore,
            strength: .standard,
            isHDRContent: false,
            isDolbyVision: false,
            compareMode: .split
        )
        XCTAssertEqual(CVPixelBufferGetWidth(splitYUV), 128)
        XCTAssertEqual(CVPixelBufferGetHeight(splitYUV), 72)

        let highFPSDowngraded = enhancer.process(
            yuvBuffer,
            preset: .lowResSuperRes,
            strength: .standard,
            isHDRContent: false,
            isDolbyVision: false,
            outputFPS: 120.0,
            thermalState: .nominal
        )
        XCTAssertEqual(CVPixelBufferGetWidth(highFPSDowngraded), 128)
        XCTAssertEqual(CVPixelBufferGetHeight(highFPSDowngraded), 72)
    }

    func testQuarkDriveClientParsersAndStreamSelection() throws {
        let listJSON = Data((
            "{\"code\":0,\"message\":\"ok\",\"data\":{\"list\":["
            + "{\"fid\":\"dir1\",\"file_name\":\"动画番剧\",\"dir\":true,\"file_type\":0},"
            + "{\"fid\":\"f1\",\"file_name\":\"TomAndJerry_4K.mp4\",\"dir\":false,\"size\":419430400,\"video_max_resolution\":\"4k\"},"
            + "{\"fid\":\"f2\",\"file_name\":\"Movie.mkv\",\"dir\":false,\"size\":2147483648},"
            + "{\"fid\":\"f3\",\"file_name\":\"readme.txt\",\"dir\":false,\"size\":120}"
            + "]}}"
        ).utf8)

        let parsed = try QuarkDriveClient.parseFileListJSON(listJSON)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertTrue(parsed[0].isDirectory)
        XCTAssertEqual(parsed[0].name, "动画番剧")
        XCTAssertEqual(parsed[1].name, "Movie.mkv")
        XCTAssertEqual(parsed[2].name, "TomAndJerry_4K.mp4")

        let dlJSON = Data("{\"code\":0,\"data\":[{\"download_url\":\"https://cdn.example.com/file.mp4\"}]}".utf8)
        let dlURL = try QuarkDriveClient.parseDownloadURLJSON(dlJSON)
        XCTAssertEqual(dlURL.absoluteString, "https://cdn.example.com/file.mp4")

        let playJSON = Data((
            "{\"code\":0,\"data\":{\"video_list\":["
            + "{\"resolution\":\"normal\",\"video_info\":{\"url\":\"https://cdn.example.com/720p.m3u8\"}},"
            + "{\"resolution\":\"4k\",\"video_info\":{\"url\":\"https://cdn.example.com/4k.m3u8\"}},"
            + "{\"resolution\":\"high\",\"video_info\":{\"url\":\"https://cdn.example.com/1080p.m3u8\"}}"
            + "]}}"
        ).utf8)
        let headers = QuarkDriveClient.requestHeaders(cookie: "__pus=abc")
        XCTAssertEqual(headers["Referer"], "https://pan.quark.cn/")
        let variants = QuarkDriveClient.parsePlayVariantsJSON(playJSON, headers: headers)
        XCTAssertEqual(variants.map(\.label), ["夸克 4K", "夸克 1080P", "夸克 720P"])

        let mp4Stream = try QuarkDriveClient.selectBestStream(
            item: parsed[2],
            downloadURL: dlURL,
            cloudVariants: variants,
            headers: headers,
            preferTranscode: false
        )
        XCTAssertEqual(mp4Stream.url, dlURL)
        XCTAssertEqual(mp4Stream.qualityLabel, "原画直链")
        XCTAssertFalse(mp4Stream.isHLS)
        XCTAssertEqual(mp4Stream.alternatives.count, 4)

        let mkvStream = try QuarkDriveClient.selectBestStream(
            item: parsed[1],
            downloadURL: dlURL,
            cloudVariants: variants,
            headers: headers,
            preferTranscode: false
        )
        XCTAssertEqual(mkvStream.qualityLabel, "夸克 4K")
        XCTAssertTrue(mkvStream.isHLS)
    }

    func testEmbyClientParsersAndStreamBuilders() throws {
        let baseURL = try XCTUnwrap(EmbyClient.normalizedBaseURL("http://192.168.1.20:8096/emby/"))
        XCTAssertEqual(baseURL.absoluteString, "http://192.168.1.20:8096")

        let authJSON = Data("{\"AccessToken\":\"tok123\",\"User\":{\"Id\":\"u456\",\"Name\":\"LivingRoom\"}}".utf8)
        let auth = try EmbyClient.parseAuthJSON(authJSON)
        XCTAssertEqual(auth.userId, "u456")
        XCTAssertEqual(auth.accessToken, "tok123")

        let itemsJSON = Data((
            "{\"Items\":["
            + "{\"Id\":\"dir1\",\"Name\":\"电影库\",\"Type\":\"CollectionFolder\",\"IsFolder\":true},"
            + "{\"Id\":\"mov1\",\"Name\":\"测试电影\",\"Type\":\"Movie\",\"IsFolder\":false,\"MediaType\":\"Video\",\"Container\":\"mkv\",\"RunTimeTicks\":1200000000,\"MediaSources\":[{\"Id\":\"ms99\",\"Container\":\"mkv\",\"Size\":1073741824}]},"
            + "{\"Id\":\"mov2\",\"Name\":\"原生MP4\",\"Type\":\"Movie\",\"IsFolder\":false,\"MediaType\":\"Video\",\"Container\":\"mp4\",\"RunTimeTicks\":600000000,\"MediaSources\":[{\"Id\":\"ms100\",\"Container\":\"mp4\"}]}"
            + "]}"
        ).utf8)

        let items = try EmbyClient.parseItemsJSON(itemsJSON, baseURL: baseURL, token: auth.accessToken)
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items[0].isDirectory)
        XCTAssertEqual(items[1].mediaSourceId, "ms99")
        XCTAssertEqual(items[1].durationSeconds ?? 0, 120.0, accuracy: 0.1)

        let mkvStream = try EmbyClient.buildPlaybackStream(item: items[1], baseURL: baseURL, token: auth.accessToken)
        XCTAssertTrue(mkvStream.isHLS)
        XCTAssertTrue(mkvStream.url.absoluteString.contains("master.m3u8"))
        XCTAssertEqual(mkvStream.alternatives.count, 2)

        let mp4Stream = try EmbyClient.buildPlaybackStream(item: items[2], baseURL: baseURL, token: auth.accessToken)
        XCTAssertFalse(mp4Stream.isHLS)
        XCTAssertTrue(mp4Stream.url.absoluteString.contains("Static=true"))
    }

    func testWebDAVPropfindXMLParser() throws {
        let baseURL = try XCTUnwrap(URL(string: "http://192.168.1.10:5244/dav/"))
        let xml = Data((
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<D:multistatus xmlns:D=\"DAV:\">"
            + "<D:response><D:href>/dav/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>"
            + "<D:response><D:href>/dav/%E7%94%B5%E5%BD%B1/</D:href><D:propstat><D:prop><D:displayname>电影</D:displayname><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>"
            + "<D:response><D:href>/dav/Sample_2160p.mp4</D:href><D:propstat><D:prop><D:displayname>Sample_2160p.mp4</D:displayname><D:getcontentlength>52428800</D:getcontentlength><D:resourcetype/></D:prop></D:propstat></D:response>"
            + "<D:response><D:href>/dav/poster.jpg</D:href><D:propstat><D:prop><D:displayname>poster.jpg</D:displayname><D:resourcetype/></D:prop></D:propstat></D:response>"
            + "</D:multistatus>"
        ).utf8)

        let parsed = WebDAVClient.parsePropfindXML(xml, baseURL: baseURL)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertTrue(parsed[0].isDirectory)
        XCTAssertEqual(parsed[0].name, "电影")
        XCTAssertFalse(parsed[1].isDirectory)
        XCTAssertEqual(parsed[1].name, "Sample_2160p.mp4")

        let stream = try WebDAVClient.buildPlaybackStream(item: parsed[1], username: "admin", password: "secret")
        XCTAssertEqual(stream.url.absoluteString, "http://192.168.1.10:5244/dav/Sample_2160p.mp4")
        XCTAssertTrue(stream.headers["Authorization"]?.hasPrefix("Basic ") == true)
    }

    @MainActor
    func testMediaSourceStoreAndCloudPlaybackRequest() throws {
        let suiteName = "glassmpv.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MediaSourceStore(defaults: defaults, storageKey: "testAccounts", useKeychain: false)
        let quark = MediaSourceAccount(kind: .quark, name: "我的夸克")
        store.addOrUpdate(account: quark, secret: "cookie=xyz")
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.secret(for: quark.id), "cookie=xyz")

        let storeReloaded = MediaSourceStore(defaults: defaults, storageKey: "testAccounts", useKeychain: false)
        XCTAssertEqual(storeReloaded.accounts.first?.name, "我的夸克")

        let coordinator = PlayerCoordinator()
        defer { coordinator.closeToHome() }
        let u1 = try XCTUnwrap(URL(string: "https://cdn.example.com/a.mp4"))
        let u2 = try XCTUnwrap(URL(string: "https://cdn.example.com/a_4k.m3u8"))
        let alt1 = StreamVariantOption(id: "orig", label: "原画直链", url: u1, headers: [:], isHLS: false)
        let alt2 = StreamVariantOption(id: "4k", label: "夸克 4K", url: u2, headers: [:], isHLS: true)
        let req = PlaybackMediaRequest(
            url: u1,
            headers: ["Referer": "https://pan.quark.cn/"],
            displayTitle: "Test.mp4",
            sourceLabel: "夸克 · 原画直链",
            alternatives: [alt1, alt2]
        )
        coordinator.openCloudStream(req)
        XCTAssertEqual(coordinator.currentURL, u1)
        XCTAssertEqual(coordinator.currentStreamVariants.count, 2)
        XCTAssertTrue(coordinator.opticalFlowController.isRemoteStream)

        coordinator.switchStreamVariant(alt2)
        XCTAssertEqual(coordinator.currentURL, u2)
        XCTAssertEqual(coordinator.activeMediaRequest?.sourceLabel, "夸克 4K")

        store.delete(accountID: quark.id)
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testLocalHTTPStreamProxyParsersCookieMergeAndHLSRewrite() throws {
        let rawHTTP = "GET /stream/tok1/video.mp4?x=1 HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nRange: bytes=0-1023\r\n\r\n"
        let parsed = try XCTUnwrap(LocalHTTPStreamProxy.parseHTTPRequestHead(rawHTTP))
        XCTAssertEqual(parsed.method, "GET")
        XCTAssertEqual(parsed.path, "/stream/tok1/video.mp4")
        XCTAssertEqual(parsed.rangeHeader, "bytes=0-1023")

        let merged = LocalHTTPStreamProxy.mergeSetCookieHeaders(
            ["__puus=new_token_999; Path=/; HttpOnly", "__extra=val2; Secure"],
            into: "__pus=keep1; __puus=old_token_111; uid=42"
        )
        XCTAssertTrue(merged.contains("__pus=keep1"))
        XCTAssertTrue(merged.contains("__puus=new_token_999"))
        XCTAssertFalse(merged.contains("old_token_111"))
        XCTAssertTrue(merged.contains("__extra=val2"))

        let baseURL = try XCTUnwrap(URL(string: "https://cdn.quark.cn/hls/master.m3u8"))
        let manifest = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\nseg_000.m4s\nhttps://other.cdn.cn/seg_001.m4s\n"
        let rewritten = LocalHTTPStreamProxy.rewriteHLSManifest(manifest, baseURL: baseURL) { child in
            URL(string: "http://127.0.0.1:9999/sub/" + child.lastPathComponent)!
        }
        XCTAssertTrue(rewritten.contains("URI=\"http://127.0.0.1:9999/sub/init.mp4\""))
        XCTAssertTrue(rewritten.contains("http://127.0.0.1:9999/sub/seg_000.m4s"))
        XCTAssertTrue(rewritten.contains("http://127.0.0.1:9999/sub/seg_001.m4s"))
    }

    func testLocalHTTPStreamProxyLiveLoopbackRoundTrip() async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let upstreamListener = try NWListener(using: params)
        final class StubCapture: @unchecked Sendable {
            private let lock = NSLock()
            private let readySem = DispatchSemaphore(value: 0)
            private var receivedHeaderText = ""
            private var port: UInt16 = 0
            private var refreshedCookie = ""

            func markReady(port: UInt16) {
                lock.lock()
                self.port = port
                lock.unlock()
                readySem.signal()
            }

            func waitForPort() -> UInt16 {
                _ = readySem.wait(timeout: .now() + 2.0)
                lock.lock()
                let p = port
                lock.unlock()
                return p
            }

            func recordRequest(_ text: String) {
                lock.lock()
                receivedHeaderText = text
                lock.unlock()
            }

            func recordRefreshedCookie(_ cookie: String) {
                lock.lock()
                refreshedCookie = cookie
                lock.unlock()
            }

            func snapshot() -> (headerText: String, cookie: String) {
                lock.lock()
                let res = (receivedHeaderText, refreshedCookie)
                lock.unlock()
                return res
            }
        }
        let capture = StubCapture()
        let stubQueue = DispatchQueue(label: "com.glassmpv.test.upstream")

        upstreamListener.stateUpdateHandler = { state in
            if case .ready = state {
                capture.markReady(port: upstreamListener.port?.rawValue ?? 0)
            }
        }
        upstreamListener.newConnectionHandler = { conn in
            conn.start(queue: stubQueue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                if let data, let text = String(data: data, encoding: .utf8) {
                    capture.recordRequest(text)
                }
                let body = Data("GLASSMPV_OK".utf8)
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: \(body.count)\r\nSet-Cookie: __puus=fresh_cookie_777; Path=/\r\nConnection: close\r\n\r\n"
                var packet = Data(resp.utf8)
                packet.append(body)
                conn.send(content: packet, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
        upstreamListener.start(queue: stubQueue)
        defer {
            upstreamListener.cancel()
            LocalHTTPStreamProxy.shared.resetRoutes()
        }

        let stubPort = capture.waitForPort()
        XCTAssertGreaterThan(stubPort, 0)

        let upstreamURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(stubPort)/movie.mp4"))
        let proxyURL = LocalHTTPStreamProxy.shared.registerStream(
            url: upstreamURL,
            headers: [
                "Cookie": "__puus=stale_cookie_111",
                "Referer": "https://pan.quark.cn/"
            ],
            isHLS: false,
            onCookieUpdate: { updated in
                capture.recordRefreshedCookie(updated)
            }
        )
        XCTAssertEqual(proxyURL.host, "127.0.0.1")

        let (data, response) = try await URLSession.shared.data(from: proxyURL)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "GLASSMPV_OK")

        let snap = capture.snapshot()
        XCTAssertTrue(snap.headerText.contains("__puus=stale_cookie_111"))
        XCTAssertTrue(snap.headerText.contains("https://pan.quark.cn/"))
        XCTAssertTrue(snap.cookie.contains("__puus=fresh_cookie_777"))
    }

    @MainActor
    func testMetalDirectRendererAspectMathAndZeroWaitMetrics() throws {
        let fitScale = MetalVideoEnhancer.aspectVertexScale(
            videoWidth: 4,
            videoHeight: 3,
            drawableWidth: 16,
            drawableHeight: 9,
            aspectFill: false
        )
        XCTAssertEqual(fitScale.y, 1.0, accuracy: 0.001)
        XCTAssertEqual(fitScale.x, 0.75, accuracy: 0.001)

        let fillScale = MetalVideoEnhancer.aspectVertexScale(
            videoWidth: 4,
            videoHeight: 3,
            drawableWidth: 16,
            drawableHeight: 9,
            aspectFill: true
        )
        XCTAssertEqual(fillScale.x, 1.0, accuracy: 0.001)
        XCTAssertGreaterThan(fillScale.y, 1.3)

        let enhancer = MetalVideoEnhancer()
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.drawableSize = CGSize(width: 256, height: 144)

        var yuvOpt: CVPixelBuffer?
        let st = CVPixelBufferCreate(
            kCFAllocatorDefault,
            128,
            72,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ] as CFDictionary,
            &yuvOpt
        )
        XCTAssertEqual(st, kCVReturnSuccess)
        let yuv = try XCTUnwrap(yuvOpt)

        let didRender = enhancer.renderToLayer(
            yuv,
            on: metalLayer,
            preset: .old4KRestore,
            strength: .standard,
            aspectFill: false,
            compareMode: .split,
            outputFPS: 48.0,
            thermalState: .nominal
        )
        if MTLCreateSystemDefaultDevice() != nil {
            XCTAssertTrue(didRender)
            XCTAssertTrue(enhancer.activePipelineLabel.contains("直绘"))
        }
    }
}
