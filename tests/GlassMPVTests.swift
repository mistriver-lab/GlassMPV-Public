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
        XCTAssertEqual(rangeInterp96Lock.minimum, 120)
        XCTAssertEqual(rangeInterp96Lock.maximum, 120)
        XCTAssertEqual(rangeInterp96Lock.preferred, 120)

        let rangeInterp120 = OpticalFlowResolutionPlanner.recommendedDisplayFrameRateRange(
            targetFPS: 120.0,
            isInterpolationEnabled: true,
            maxScreenFPS: 120
        )
        XCTAssertEqual(rangeInterp120.minimum, 120)
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
        XCTAssertEqual(rangePassthrough.preferred, 60)

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
        func waitForPassthroughFrames(timeoutSeconds: TimeInterval) async throws {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while Date() < deadline {
                if coordinator.opticalFlowController.errorMessage != nil {
                    break
                }
                if coordinator.opticalFlowController.presentedFrameCount > 0 {
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        coordinator.open(url: sampleURL, isSecurityScoped: false)
        try await waitForPassthroughFrames(timeoutSeconds: 15.0)
        if coordinator.opticalFlowController.presentedFrameCount == 0 {
            coordinator.opticalFlowController.clearError()
            coordinator.open(url: sampleURL, isSecurityScoped: false)
            try await waitForPassthroughFrames(timeoutSeconds: 15.0)
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
        XCTAssertNil(enhancer.shaderInitError)
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

    func testQuarkQRLoginParsingAndURLBuilder() throws {
        let qrURL = QuarkDriveClient.buildQRLoginURL(token: "tok_abc_123")
        XCTAssertTrue(qrURL.absoluteString.contains("su.quark.cn/4_eMHBJ"))
        XCTAssertTrue(qrURL.absoluteString.contains("token=tok_abc_123"))
        XCTAssertTrue(qrURL.absoluteString.contains("client_id=532"))

        let tokenJSON = Data("{\"status\":2000000,\"message\":\"ok\",\"data\":{\"members\":{\"token\":\"sta33633316wsy\"}}}".utf8)
        XCTAssertEqual(try QuarkDriveClient.parseQRTokenJSON(tokenJSON), "sta33633316wsy")

        let pendingJSON = Data("{\"status\":50004001,\"message\":\"Query result is empty\"}".utf8)
        XCTAssertEqual(try QuarkDriveClient.parseQRPollJSON(pendingJSON), .pending)

        let expiredJSON = Data("{\"status\":50004002,\"message\":\"qrcode expired\"}".utf8)
        XCTAssertEqual(try QuarkDriveClient.parseQRPollJSON(expiredJSON), .expired)

        let authJSON = Data("{\"status\":2000000,\"message\":\"ok\",\"data\":{\"members\":{\"service_ticket\":\"st_ticket_999\"}}}".utf8)
        XCTAssertEqual(try QuarkDriveClient.parseQRPollJSON(authJSON), .authorized(serviceTicket: "st_ticket_999"))

        let mergedCookie = LocalHTTPStreamProxy.mergeSetCookieHeaders(
            ["__puus=bootstrapped_puus_val; Path=/; HttpOnly"],
            into: "__pus=keep_pus_val; uid=101"
        )
        XCTAssertTrue(mergedCookie.contains("__pus=keep_pus_val"))
        XCTAssertTrue(mergedCookie.contains("__puus=bootstrapped_puus_val"))
    }

    @MainActor
    func testMetalDrawableSizingAndTelemetryThrottling() throws {
        XCTAssertEqual(SampleBufferDisplayContainerView.recommendedMetalMaxLongSide(outputFPS: 120.0, allowSpatialUpscale: false), 1600.0)
        XCTAssertEqual(SampleBufferDisplayContainerView.recommendedMetalMaxLongSide(outputFPS: 96.0, allowSpatialUpscale: false), 1600.0)
        XCTAssertEqual(SampleBufferDisplayContainerView.recommendedMetalMaxLongSide(outputFPS: 60.0, allowSpatialUpscale: false), 2560.0)
        XCTAssertEqual(SampleBufferDisplayContainerView.recommendedMetalMaxLongSide(outputFPS: 48.0, allowSpatialUpscale: true), 2560.0)
        XCTAssertEqual(SampleBufferDisplayContainerView.recommendedMetalMaxLongSide(outputFPS: 120.0, allowSpatialUpscale: true), 2560.0)

        let container = SampleBufferDisplayContainerView(frame: CGRect(x: 0, y: 0, width: 932, height: 430))
        container.updateMetalMaxLongSide(1600.0)
        container.layoutIfNeeded()
        XCTAssertLessThanOrEqual(container.metalLayer.drawableSize.width, 1601.0)
        container.applyVideoTransform(.identity)

        let enhancer = MetalVideoEnhancer()
        XCTAssertNil(enhancer.shaderInitError)
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

        let status = enhancer.renderToLayerStatus(
            yuv,
            on: metalLayer,
            preset: .lowResSuperRes,
            strength: .standard,
            aspectFill: false,
            compareMode: .off,
            outputFPS: 120.0,
            thermalState: .nominal
        )
        if MTLCreateSystemDefaultDevice() != nil {
            XCTAssertEqual(status, .rendered)
        } else {
            XCTAssertEqual(status, .unavailable)
        }

        let controller = OpticalFlowPlayerController()
        controller.flushPublishedTelemetryIfNeeded(force: true)
        XCTAssertEqual(controller.presentedFrameCount, 0)
    }

    func testLocalHTTPStreamProxyHEV1ToHVC1RewriteAndChunkBoundary() throws {
        func makeVisualSampleEntry(fourCC: String, width: UInt16, height: UInt16, includeHVCC: Bool) -> Data {
            var entry = Data()
            var sizePlaceholder = UInt32(0).bigEndian
            withUnsafeBytes(of: &sizePlaceholder) { entry.append(contentsOf: $0) }
            entry.append(contentsOf: fourCC.utf8.prefix(4))
            entry.append(contentsOf: [UInt8](repeating: 0, count: 6)) // reserved[6]
            var dataRefIdx = UInt16(1).bigEndian
            withUnsafeBytes(of: &dataRefIdx) { entry.append(contentsOf: $0) }
            entry.append(contentsOf: [UInt8](repeating: 0, count: 16)) // pre_defined + reserved + horiz/vert/etc
            var w = width.bigEndian
            var h = height.bigEndian
            withUnsafeBytes(of: &w) { entry.append(contentsOf: $0) }
            withUnsafeBytes(of: &h) { entry.append(contentsOf: $0) }
            entry.append(contentsOf: [UInt8](repeating: 0, count: 46)) // resolution + frame_count + compressorname[32]
            var depth = UInt16(0x0018).bigEndian
            var preDef = UInt16(0xFFFF).bigEndian
            withUnsafeBytes(of: &depth) { entry.append(contentsOf: $0) }
            withUnsafeBytes(of: &preDef) { entry.append(contentsOf: $0) }
            if includeHVCC {
                var childLen = UInt32(16).bigEndian
                withUnsafeBytes(of: &childLen) { entry.append(contentsOf: $0) }
                entry.append(contentsOf: "hvcC".utf8)
                entry.append(contentsOf: [UInt8](repeating: 0x01, count: 8))
            } else {
                entry.append(contentsOf: [UInt8](repeating: 0x00, count: 16))
            }
            var totalLen = UInt32(entry.count).bigEndian
            entry.replaceSubrange(0..<4, with: withUnsafeBytes(of: &totalLen) { Data($0) })
            return entry
        }

        let validHEV1 = makeVisualSampleEntry(fourCC: "hev1", width: 1920, height: 1080, includeHVCC: true)
        let prefixNoise = Data([0x11, 0x22, 0x33]) + Data("mdat_hev1_payload_bytes".utf8)
        var randomFalseHEV1 = makeVisualSampleEntry(fourCC: "hev1", width: 1920, height: 1080, includeHVCC: false)
        randomFalseHEV1[20] = 0xAA // corrupt non-hvcC noise box

        var packet = Data()
        packet.append(prefixNoise)
        packet.append(validHEV1)
        packet.append(randomFalseHEV1)

        var oneShot = packet
        let count = LocalHTTPStreamProxy.patchHEV1ToHVC1(in: &oneShot)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(oneShot.count, packet.count)
        let entrySlice = Data(oneShot[prefixNoise.count..<(prefixNoise.count + validHEV1.count)])
        XCTAssertEqual(String(data: entrySlice.subdata(in: 4..<8), encoding: .utf8), "hvc1")
        XCTAssertTrue(String(decoding: oneShot.prefix(prefixNoise.count), as: UTF8.self).contains("hev1"))
        let untouchedSlice = Data(oneShot[(prefixNoise.count + validHEV1.count)...])
        XCTAssertEqual(String(data: untouchedSlice.subdata(in: 4..<8), encoding: .utf8), "hev1")

        // 切分跨 "hev1" 与 "hvcC" 边界的流式重组校验
        var patcher = MP4HEV1StreamPatcher()
        let splitPoints = [0, 5, prefixNoise.count + 6, prefixNoise.count + 40, prefixNoise.count + 90, packet.count]
        var streamed = Data()
        for idx in 0..<(splitPoints.count - 1) {
            let chunk = packet.subdata(in: splitPoints[idx]..<splitPoints[idx + 1])
            streamed.append(patcher.processChunk(chunk))
        }
        streamed.append(patcher.flush())
        XCTAssertEqual(streamed, oneShot)
    }

    func testRemoteOpticalFlowBudgetPlannerAndAdaptiveLag() {
        let plan2x = RemoteOpticalFlowBudgetPlanner.buildRemoteCandidatePlan(
            sourceWidth: 3840,
            sourceHeight: 2160,
            maxInterpolatedFrames: 1
        )
        XCTAssertEqual(plan2x.map(\.height), [1080, 810])

        let plan96 = RemoteOpticalFlowBudgetPlanner.buildRemoteCandidatePlan(
            sourceWidth: 3840,
            sourceHeight: 2160,
            maxInterpolatedFrames: 3
        )
        XCTAssertEqual(plan96.map(\.height), [810, 720])
        XCTAssertFalse(plan96.contains(where: { $0.height < 720 }))

        let plan120 = RemoteOpticalFlowBudgetPlanner.buildRemoteCandidatePlan(
            sourceWidth: 3840,
            sourceHeight: 2160,
            maxInterpolatedFrames: 4
        )
        XCTAssertEqual(plan120.map(\.height), [720])
        XCTAssertFalse(plan120.contains(where: { $0.height < 720 }))

        XCTAssertFalse(
            RemoteOpticalFlowBudgetPlanner.isCatchUpOverload(
                skippedInputs: 2,
                processMs: 28.8,
                sourceIntervalMs: 40.0
            )
        )
        XCTAssertTrue(
            RemoteOpticalFlowBudgetPlanner.isCatchUpOverload(
                skippedInputs: 1,
                processMs: 36.5,
                sourceIntervalMs: 40.0
            )
        )
        XCTAssertFalse(
            RemoteOpticalFlowBudgetPlanner.isCatchUpOverload(
                skippedInputs: 0,
                processMs: 45.0,
                sourceIntervalMs: 40.0
            )
        )

        XCTAssertTrue(
            RemoteOpticalFlowBudgetPlanner.shouldEmitPreparedOriginalFrame(
                sourceWidth: 3840,
                sourceHeight: 2160,
                candidateWidth: 1280,
                candidateHeight: 720
            )
        )
        XCTAssertFalse(
            RemoteOpticalFlowBudgetPlanner.shouldEmitPreparedOriginalFrame(
                sourceWidth: 1280,
                sourceHeight: 720,
                candidateWidth: 1280,
                candidateHeight: 720
            )
        )

        let lagLow = RemoteOpticalFlowBudgetPlanner.recommendedPacerLagSeconds(
            sourceFPS: 24.0,
            averageInterpolationMs: 17.0,
            targetFPS: .x2
        )
        let lagHigh = RemoteOpticalFlowBudgetPlanner.recommendedPacerLagSeconds(
            sourceFPS: 24.0,
            averageInterpolationMs: 58.0,
            targetFPS: .fps120
        )
        XCTAssertGreaterThan(lagHigh, lagLow)
        XCTAssertGreaterThanOrEqual(lagHigh, 0.13)
        XCTAssertLessThanOrEqual(lagHigh, 0.195)
    }

    func testSubtitleParserSRTWebVTTASSAndActiveLookup() {
        let srt = """
        1
        00:00:01,500 --> 00:00:04,200
        <i>第一句字幕</i>
        第二行内容

        2
        00:00:05,000 --> 00:00:08,000
        {\\an8}顶部注释
        """
        let srtCues = SubtitleParser.parse(text: srt, fileExtension: "srt")
        XCTAssertEqual(srtCues.count, 2)
        XCTAssertEqual(srtCues[0].text, "第一句字幕\n第二行内容")
        XCTAssertEqual(srtCues[1].text, "顶部注释")

        let activeAt2 = SubtitleParser.activeCues(in: srtCues, at: 2.0, offset: 0)
        XCTAssertEqual(activeAt2.map(\.text), ["第一句字幕\n第二行内容"])
        let activeWithOffset = SubtitleParser.activeCues(in: srtCues, at: 4.5, offset: 1.0)
        XCTAssertEqual(activeWithOffset.map(\.text), ["顶部注释"])

        let vtt = """
        WEBVTT

        NOTE comment ignored

        00:10.000 --> 00:12.500 align:start position:10%
        <c.cyan>WebVTT Cue</c>
        """
        let vttCues = SubtitleParser.parse(text: vtt, fileExtension: "vtt")
        XCTAssertEqual(vttCues.count, 1)
        XCTAssertEqual(vttCues[0].startTime, 10.0, accuracy: 0.001)
        XCTAssertEqual(vttCues[0].text, "WebVTT Cue")

        let ass = """
        [Script Info]
        Title: Test

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:01:02.50,0:01:05.75,Default,,0,0,0,,{\\pos(100,200)}Hello, World\\N第二行
        """
        let assCues = SubtitleParser.parse(text: ass, fileExtension: "ass")
        XCTAssertEqual(assCues.count, 1)
        XCTAssertEqual(assCues[0].startTime, 62.50, accuracy: 0.001)
        XCTAssertEqual(assCues[0].endTime, 65.75, accuracy: 0.001)
        XCTAssertEqual(assCues[0].text, "Hello, World\n第二行")
    }

    @MainActor
    func testWatchHistoryStorePersistenceProgressAndContinueWatching() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassmpv_history_test_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let accountID = UUID()
        let cloudItem = CloudMediaItem(
            id: "fid_028",
            name: "028.mp4",
            isDirectory: false,
            sizeBytes: 1_024_000,
            durationSeconds: 3000,
            fileExtension: "mp4",
            subtitle: "MP4 · 4K",
            sourceKind: .quark
        )
        let entryID = WatchHistoryEntry.makeEntryID(
            sourceKind: .quark,
            accountID: accountID,
            cloudItemID: cloudItem.id
        )

        let store1 = WatchHistoryStore(storageDirectory: tempDir)
        let saved = store1.upsertProgress(
            id: entryID,
            title: "028.mp4",
            subtitle: "MP4 · 4K",
            sourceKind: .quark,
            sourceBadge: "夸克",
            accountID: accountID,
            cloudItem: cloudItem,
            positionSeconds: 750,
            durationSeconds: 3000
        )
        XCTAssertEqual(saved.progress, 0.25, accuracy: 0.001)
        XCTAssertFalse(saved.isCompleted)
        XCTAssertEqual(saved.remainingText, "剩余 37 分钟")
        XCTAssertEqual(store1.continueWatchingEntries.count, 1)

        // 重建实例验证磁盘持久化与自动标为已看完逻辑
        let store2 = WatchHistoryStore(storageDirectory: tempDir)
        let reloaded = try XCTUnwrap(store2.entry(forCloudItemID: "fid_028", accountID: accountID))
        XCTAssertEqual(reloaded.positionSeconds, 750, accuracy: 0.01)

        let completed = store2.upsertProgress(
            id: entryID,
            title: "028.mp4",
            sourceKind: .quark,
            accountID: accountID,
            cloudItem: cloudItem,
            positionSeconds: 2900,
            durationSeconds: 3000
        )
        XCTAssertTrue(completed.isCompleted)
        XCTAssertEqual(completed.remainingText, "已看完")
        XCTAssertTrue(store2.continueWatchingEntries.isEmpty)

        store2.remove(id: entryID)
        XCTAssertTrue(store2.entries.isEmpty)
    }

    @MainActor
    func testMetalDirectPassthroughModeForHighFPSOriginalQuality() throws {
        let enhancer = MetalVideoEnhancer()
        XCTAssertNil(enhancer.shaderInitError)
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

        let blockedStatus = enhancer.renderToLayerStatus(
            yuv,
            on: metalLayer,
            preset: .off,
            strength: .standard,
            aspectFill: false,
            compareMode: .off,
            outputFPS: 120.0,
            thermalState: .nominal,
            allowPassthrough: false
        )
        XCTAssertEqual(blockedStatus, .unavailable)

        let passthroughStatus = enhancer.renderToLayerStatus(
            yuv,
            on: metalLayer,
            preset: .off,
            strength: .standard,
            aspectFill: false,
            compareMode: .off,
            outputFPS: 120.0,
            thermalState: .nominal,
            allowPassthrough: true
        )
        if MTLCreateSystemDefaultDevice() != nil {
            XCTAssertEqual(passthroughStatus, .rendered)
            XCTAssertTrue(enhancer.activePipelineLabel.contains("原画高刷直绘"))
        } else {
            XCTAssertEqual(passthroughStatus, .unavailable)
        }
    }

    func testPlayerGestureMathZonesScrubAndLevels() {
        XCTAssertEqual(PlayerGestureMath.zone(forX: 50, inWidth: 400), .left)
        XCTAssertEqual(PlayerGestureMath.zone(forX: 200, inWidth: 400), .center)
        XCTAssertEqual(PlayerGestureMath.zone(forX: 350, inWidth: 400), .right)

        let forwardDelta = PlayerGestureMath.seekDeltaSeconds(translationX: 200, viewWidth: 400, duration: 1200)
        let backwardDelta = PlayerGestureMath.seekDeltaSeconds(translationX: -200, viewWidth: 400, duration: 1200)
        XCTAssertGreaterThan(forwardDelta, 40.0)
        XCTAssertEqual(forwardDelta, -backwardDelta, accuracy: 0.01)

        let upLevel = PlayerGestureMath.adjustedLevel(start: 0.5, translationY: -100, viewHeight: 400)
        XCTAssertGreaterThan(upLevel, 0.5)
        let clampedMax = PlayerGestureMath.adjustedLevel(start: 0.9, translationY: -300, viewHeight: 400)
        XCTAssertEqual(clampedMax, 1.0, accuracy: 0.001)
        let clampedMin = PlayerGestureMath.adjustedLevel(start: 0.1, translationY: 300, viewHeight: 400)
        XCTAssertEqual(clampedMin, 0.0, accuracy: 0.001)
    }

    func testLocalHTTPStreamProxyErrorStatusAndMediaHeaders() async throws {
        let mediaHdrs = QuarkDriveClient.mediaHeaders(cookie: " __puus=fresh_cookie ")
        XCTAssertEqual(mediaHdrs["Cookie"], "__puus=fresh_cookie")
        XCTAssertEqual(mediaHdrs["Accept"], "*/*")
        XCTAssertEqual(mediaHdrs["Referer"], "https://pan.quark.cn/")
        XCTAssertNil(mediaHdrs["Origin"])

        let timedOutErr = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        XCTAssertEqual(LocalHTTPStreamProxy.httpErrorStatus(for: timedOutErr), "504 Gateway Timeout")

        let cannotConnectErr = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: nil)
        XCTAssertEqual(LocalHTTPStreamProxy.httpErrorStatus(for: cannotConnectErr), "502 Bad Gateway")

        final class LogBox: @unchecked Sendable {
            private let lock = NSLock()
            private var logs: [String] = []
            func append(_ line: String) {
                lock.lock()
                logs.append(line)
                lock.unlock()
            }
            func snapshot() -> [String] {
                lock.lock()
                let copy = logs
                lock.unlock()
                return copy
            }
        }
        let logBox = LogBox()
        let deadPortURL = try XCTUnwrap(URL(string: "http://127.0.0.1:1/unreachable.mp4"))
        let proxyURL = LocalHTTPStreamProxy.shared.registerStream(
            url: deadPortURL,
            headers: mediaHdrs,
            isHLS: false,
            onLog: { msg in
                logBox.append(msg)
            }
        )
        defer { LocalHTTPStreamProxy.shared.resetRoutes() }

        let (_, response) = try await URLSession.shared.data(from: proxyURL)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 502)
        XCTAssertTrue(logBox.snapshot().contains(where: { $0.contains("[proxy][error]") }))
    }

    @MainActor
    func testUserPreferencesStorePinnedFoldersAndSkipIntro() throws {
        let suiteName = "glassmpv.prefs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = UserPreferencesStore(defaults: defaults)
        XCTAssertTrue(store.continuousPlayback)
        XCTAssertTrue(store.gesturesEnabled)
        XCTAssertEqual(store.skipIntervalSeconds, 10)
        XCTAssertEqual(store.defaultSkipIntroSeconds, 85)
        XCTAssertFalse(store.showDeveloperHUD)

        store.continuousPlayback = false
        store.skipIntervalSeconds = 15
        let account = MediaSourceAccount(kind: .quark, name: "主力夸克")
        store.togglePin(account: account, folderKey: "folder_1", folderTitle: "追剧合集")
        XCTAssertTrue(store.isPinned(accountID: account.id, folderKey: "folder_1"))

        let folderKey = PinnedFolder.makeID(accountID: account.id, folderKey: "folder_1")
        XCTAssertEqual(store.introDuration(forFolderKey: folderKey), 85)
        store.setIntroDuration(105, forFolderKey: folderKey)
        XCTAssertEqual(store.introDuration(forFolderKey: folderKey), 105)
        XCTAssertTrue(store.hasCustomIntroDuration(forFolderKey: folderKey))

        let reloaded = UserPreferencesStore(defaults: defaults)
        XCTAssertFalse(reloaded.continuousPlayback)
        XCTAssertEqual(reloaded.skipIntervalSeconds, 15)
        XCTAssertEqual(reloaded.pinnedFolders.count, 1)
        XCTAssertEqual(reloaded.pinnedFolders.first?.folderTitle, "追剧合集")
        XCTAssertEqual(reloaded.introDuration(forFolderKey: folderKey), 105)

        reloaded.clearIntroDuration(forFolderKey: folderKey)
        XCTAssertEqual(reloaded.introDuration(forFolderKey: folderKey), 85)
        reloaded.removePins(forAccountID: account.id)
        XCTAssertTrue(reloaded.pinnedFolders.isEmpty)
    }

    func testPlayerGestureMathPinchZoom() {
        XCTAssertEqual(PlayerGestureMath.pinchTargetAspectFill(scale: 1.25, currentFill: false), true)
        XCTAssertNil(PlayerGestureMath.pinchTargetAspectFill(scale: 1.25, currentFill: true))
        XCTAssertEqual(PlayerGestureMath.pinchTargetAspectFill(scale: 0.78, currentFill: true), false)
        XCTAssertNil(PlayerGestureMath.pinchTargetAspectFill(scale: 0.78, currentFill: false))
        XCTAssertNil(PlayerGestureMath.pinchTargetAspectFill(scale: 1.02, currentFill: false))
    }

    func testMP4HEV1StreamPatcherBoxAwareMdatSkipAndTailMoov() {
        func makeBox(fourCC: String, payload: Data) -> Data {
            var box = Data()
            var total = UInt32(8 + payload.count).bigEndian
            withUnsafeBytes(of: &total) { box.append(contentsOf: $0) }
            box.append(contentsOf: fourCC.utf8.prefix(4))
            box.append(payload)
            return box
        }

        func makeValidHEV1Entry(width: UInt16, height: UInt16) -> Data {
            var entry = Data()
            var sizePlaceholder = UInt32(0).bigEndian
            withUnsafeBytes(of: &sizePlaceholder) { entry.append(contentsOf: $0) }
            entry.append(contentsOf: "hev1".utf8)
            entry.append(contentsOf: [UInt8](repeating: 0, count: 6))
            var dataRefIdx = UInt16(1).bigEndian
            withUnsafeBytes(of: &dataRefIdx) { entry.append(contentsOf: $0) }
            entry.append(contentsOf: [UInt8](repeating: 0, count: 16))
            var w = width.bigEndian
            var h = height.bigEndian
            withUnsafeBytes(of: &w) { entry.append(contentsOf: $0) }
            withUnsafeBytes(of: &h) { entry.append(contentsOf: $0) }
            entry.append(contentsOf: [UInt8](repeating: 0, count: 46))
            var depth = UInt16(0x0018).bigEndian
            var preDef = UInt16(0xFFFF).bigEndian
            withUnsafeBytes(of: &depth) { entry.append(contentsOf: $0) }
            withUnsafeBytes(of: &preDef) { entry.append(contentsOf: $0) }
            var childLen = UInt32(16).bigEndian
            withUnsafeBytes(of: &childLen) { entry.append(contentsOf: $0) }
            entry.append(contentsOf: "hvcC".utf8)
            entry.append(contentsOf: [UInt8](repeating: 0x01, count: 8))
            var totalLen = UInt32(entry.count).bigEndian
            entry.replaceSubrange(0..<4, with: withUnsafeBytes(of: &totalLen) { Data($0) })
            return entry
        }

        let ftyp = makeBox(fourCC: "ftyp", payload: Data("isom\0\0\u{02}\0isomiso2mp41".utf8))
        let fakeEntryInsideMdat = makeValidHEV1Entry(width: 3840, height: 2160)
        let mdatPayload = Data(repeating: 0xAA, count: 4096) + fakeEntryInsideMdat + Data(repeating: 0x55, count: 4096)
        let mdat = makeBox(fourCC: "mdat", payload: mdatPayload)
        let tailMoovPayload = Data("trak_stbl_stsd".utf8) + makeValidHEV1Entry(width: 3840, height: 2160)
        let tailMoov = makeBox(fourCC: "moov", payload: tailMoovPayload)

        let fullMP4 = ftyp + mdat + tailMoov
        var boxPatcher = MP4HEV1StreamPatcher(startsAtFileOffsetZero: true)
        var out = Data()
        let chunkSize = 1024
        var cursor = 0
        while cursor < fullMP4.count {
            let next = min(fullMP4.count, cursor + chunkSize)
            out.append(boxPatcher.processChunk(fullMP4.subdata(in: cursor..<next)))
            cursor = next
        }
        out.append(boxPatcher.flush())

        XCTAssertEqual(out.count, fullMP4.count)
        let outMdatSlice = out.subdata(in: ftyp.count..<(ftyp.count + mdat.count))
        XCTAssertEqual(outMdatSlice, mdat)
        let outMoovSlice = out.subdata(in: (ftyp.count + mdat.count)..<out.count)
        XCTAssertNotNil(outMoovSlice.range(of: Data("hvc1".utf8)))
        XCTAssertNil(outMoovSlice.range(of: Data("hev1".utf8)))

        let midRangePayload = Data(repeating: 0x3C, count: 81920)
        var midPatcher = MP4HEV1StreamPatcher(startsAtFileOffsetZero: false)
        var midOut = midPatcher.processChunk(midRangePayload)
        midOut.append(midPatcher.flush())
        XCTAssertEqual(midOut, midRangePayload)
    }

    @MainActor
    func testAutoMetalFXUpscaleOpticalFlowDecision() {
        XCTAssertTrue(
            MetalVideoEnhancer.shouldAutoMetalFXUpscaleOpticalFlow(
                preset: .off,
                allowPassthrough: true,
                isDownsampledOpticalFlow: true,
                thermalState: .nominal
            )
        )
        XCTAssertTrue(
            MetalVideoEnhancer.shouldAutoMetalFXUpscaleOpticalFlow(
                preset: .off,
                allowPassthrough: true,
                isDownsampledOpticalFlow: true,
                thermalState: .fair
            )
        )
        XCTAssertFalse(
            MetalVideoEnhancer.shouldAutoMetalFXUpscaleOpticalFlow(
                preset: .off,
                allowPassthrough: true,
                isDownsampledOpticalFlow: true,
                thermalState: .serious
            )
        )
        XCTAssertFalse(
            MetalVideoEnhancer.shouldAutoMetalFXUpscaleOpticalFlow(
                preset: .off,
                allowPassthrough: true,
                isDownsampledOpticalFlow: false,
                thermalState: .nominal
            )
        )
        XCTAssertFalse(
            MetalVideoEnhancer.shouldAutoMetalFXUpscaleOpticalFlow(
                preset: .old4KRestore,
                allowPassthrough: true,
                isDownsampledOpticalFlow: true,
                thermalState: .nominal
            )
        )
        let restoreParams = MetalVideoEnhancer.opticalFlowDownsampleRestoreParameters()
        XCTAssertGreaterThan(restoreParams.casStrength, 0)
        XCTAssertEqual(restoreParams.lineDarken, 0, accuracy: 0.0001)
    }

    func testLocalHTTPStreamProxyParallelChunkedRangeAndCacheReuse() async throws {
        XCTAssertEqual(
            LocalHTTPStreamProxy.parseContentRangeTotalLength("bytes 0-1/5864456763"),
            5_864_456_763
        )
        XCTAssertNil(LocalHTTPStreamProxy.parseContentRangeTotalLength("bytes 0-1/*"))
        let parsedClosed = try XCTUnwrap(LocalHTTPStreamProxy.parseByteRangeHeader("bytes=100-999", totalLength: 500))
        XCTAssertEqual(parsedClosed.start, 100)
        XCTAssertEqual(parsedClosed.end, 499)
        let parsedOpen = try XCTUnwrap(LocalHTTPStreamProxy.parseByteRangeHeader("bytes=200-", totalLength: 500))
        XCTAssertEqual(parsedOpen.start, 200)
        XCTAssertEqual(parsedOpen.end, 499)
        let parsedSuffix = try XCTUnwrap(LocalHTTPStreamProxy.parseByteRangeHeader("bytes=-50", totalLength: 500))
        XCTAssertEqual(parsedSuffix.start, 450)
        XCTAssertEqual(parsedSuffix.end, 499)

        func makeBox(fourCC: String, payload: Data) -> Data {
            var box = Data()
            var total = UInt32(8 + payload.count).bigEndian
            withUnsafeBytes(of: &total) { box.append(contentsOf: $0) }
            box.append(contentsOf: fourCC.utf8.prefix(4))
            box.append(payload)
            return box
        }

        func makeValidHEV1Entry(width: UInt16, height: UInt16) -> Data {
            var entry = Data()
            var sizePlaceholder = UInt32(0).bigEndian
            withUnsafeBytes(of: &sizePlaceholder) { entry.append(contentsOf: $0) }
            entry.append(contentsOf: "hev1".utf8)
            entry.append(contentsOf: [UInt8](repeating: 0, count: 6))
            var dataRefIdx = UInt16(1).bigEndian
            withUnsafeBytes(of: &dataRefIdx) { entry.append(contentsOf: $0) }
            entry.append(contentsOf: [UInt8](repeating: 0, count: 16))
            var w = width.bigEndian
            var h = height.bigEndian
            withUnsafeBytes(of: &w) { entry.append(contentsOf: $0) }
            withUnsafeBytes(of: &h) { entry.append(contentsOf: $0) }
            entry.append(contentsOf: [UInt8](repeating: 0, count: 46))
            var depth = UInt16(0x0018).bigEndian
            var preDef = UInt16(0xFFFF).bigEndian
            withUnsafeBytes(of: &depth) { entry.append(contentsOf: $0) }
            withUnsafeBytes(of: &preDef) { entry.append(contentsOf: $0) }
            var childLen = UInt32(16).bigEndian
            withUnsafeBytes(of: &childLen) { entry.append(contentsOf: $0) }
            entry.append(contentsOf: "hvcC".utf8)
            entry.append(contentsOf: [UInt8](repeating: 0x01, count: 8))
            var totalLen = UInt32(entry.count).bigEndian
            entry.replaceSubrange(0..<4, with: withUnsafeBytes(of: &totalLen) { Data($0) })
            return entry
        }

        let ftyp = makeBox(fourCC: "ftyp", payload: Data("isom\0\0\u{02}\0isomiso2mp41".utf8))
        let tailMoov = makeBox(
            fourCC: "moov",
            payload: Data("trak_stbl_stsd".utf8) + makeValidHEV1Entry(width: 3840, height: 2160)
        )
        let targetTotalSize = 6 * 1024 * 1024
        let mdatPayloadSize = targetTotalSize - ftyp.count - 8 - tailMoov.count
        let mdat = makeBox(fourCC: "mdat", payload: Data(repeating: 0x5A, count: mdatPayloadSize))
        let fullFileData = ftyp + mdat + tailMoov
        XCTAssertEqual(fullFileData.count, targetTotalSize)

        final class RangeMockServer: @unchecked Sendable {
            private let lock = NSLock()
            private let readySem = DispatchSemaphore(value: 0)
            private var port: UInt16 = 0
            private(set) var recordedRanges: [(start: Int64, end: Int64)] = []
            let bodyData: Data

            init(bodyData: Data) {
                self.bodyData = bodyData
            }

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

            func record(start: Int64, end: Int64) {
                lock.lock()
                recordedRanges.append((start: start, end: end))
                lock.unlock()
            }

            func snapshotRanges() -> [(start: Int64, end: Int64)] {
                lock.lock()
                let copy = recordedRanges
                lock.unlock()
                return copy
            }
        }

        let mockServer = RangeMockServer(bodyData: fullFileData)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        let stubQueue = DispatchQueue(label: "com.glassmpv.test.parallel.upstream")

        listener.stateUpdateHandler = { state in
            if case .ready = state {
                mockServer.markReady(port: listener.port?.rawValue ?? 0)
            }
        }
        listener.newConnectionHandler = { conn in
            conn.start(queue: stubQueue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let reqText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let parsed = LocalHTTPStreamProxy.parseHTTPRequestHead(reqText)
                let totalLen = Int64(mockServer.bodyData.count)
                let rangeTuple = parsed?.rangeHeader.flatMap {
                    LocalHTTPStreamProxy.parseByteRangeHeader($0, totalLength: totalLen)
                } ?? (start: 0, end: totalLen - 1)
                mockServer.record(start: rangeTuple.start, end: rangeTuple.end)
                let slice = mockServer.bodyData.subdata(in: Int(rangeTuple.start)..<Int(rangeTuple.end + 1))
                let head = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Length: \(slice.count)\r\nContent-Range: bytes \(rangeTuple.start)-\(rangeTuple.end)/\(totalLen)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
                var packet = Data(head.utf8)
                packet.append(slice)
                conn.send(content: packet, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            }
        }
        listener.start(queue: stubQueue)
        defer {
            listener.cancel()
            LocalHTTPStreamProxy.shared.resetRoutes()
        }

        let port = mockServer.waitForPort()
        XCTAssertGreaterThan(port, 0)

        let upstreamURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/4k_movie.mp4"))
        let proxyURL = LocalHTTPStreamProxy.shared.registerStream(
            url: upstreamURL,
            headers: ["Referer": "https://pan.quark.cn/"],
            isHLS: false
        )

        var probeReq = URLRequest(url: proxyURL)
        probeReq.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        let (probeData, probeResp) = try await URLSession.shared.data(for: probeReq)
        let probeHTTP = try XCTUnwrap(probeResp as? HTTPURLResponse)
        XCTAssertEqual(probeHTTP.statusCode, 206)
        XCTAssertEqual(probeData, fullFileData.subdata(in: 0..<2))

        var fullReq = URLRequest(url: proxyURL)
        fullReq.setValue("bytes=0-\(targetTotalSize - 1)", forHTTPHeaderField: "Range")
        let (streamedData, fullResp) = try await URLSession.shared.data(for: fullReq)
        let fullHTTP = try XCTUnwrap(fullResp as? HTTPURLResponse)
        XCTAssertEqual(fullHTTP.statusCode, 206)
        XCTAssertEqual(streamedData.count, targetTotalSize)
        XCTAssertEqual(streamedData.subdata(in: ftyp.count..<(ftyp.count + mdat.count)), mdat)
        let outMoovSlice = streamedData.subdata(in: (ftyp.count + mdat.count)..<streamedData.count)
        XCTAssertNotNil(outMoovSlice.range(of: Data("hvc1".utf8)))
        XCTAssertNil(outMoovSlice.range(of: Data("hev1".utf8)))

        let upstreamCountAfterFull = mockServer.snapshotRanges().count
        var midReq = URLRequest(url: proxyURL)
        midReq.setValue("bytes=2500000-5000000", forHTTPHeaderField: "Range")
        let (midData, midResp) = try await URLSession.shared.data(for: midReq)
        let midHTTP = try XCTUnwrap(midResp as? HTTPURLResponse)
        XCTAssertEqual(midHTTP.statusCode, 206)
        XCTAssertEqual(midData.count, 5_000_000 - 2_500_000 + 1)
        XCTAssertEqual(midData, fullFileData.subdata(in: 2_500_000..<5_000_001))
        XCTAssertEqual(mockServer.snapshotRanges().count, upstreamCountAfterFull, "已缓存 2MB 分块再次读取应零上游请求命中缓存")
        let chunkSizes = mockServer.snapshotRanges().map { $0.end - $0.start + 1 }
        XCTAssertTrue(chunkSizes.allSatisfy { $0 <= Int64(2 * 1024 * 1024) }, "所有上游分块请求不得超过 2MB")
    }

    @MainActor
    func testHybrid4KFlowWarpPlannerAndMetalRender() throws {
        XCTAssertTrue(
            RemoteOpticalFlowBudgetPlanner.shouldUseHybridFlowWarp(
                sourceWidth: 3840,
                sourceHeight: 2160,
                targetFPS: .fps120,
                isHDR: false,
                isDolbyVision: false,
                is8BitSDRPixelFormat: true
            ),
            "4K 120fps SDR 默认开启原生光流变形 v2 以保留真 4K 分辨率并突破 ANE 40ms 墙"
        )
        XCTAssertFalse(
            RemoteOpticalFlowBudgetPlanner.shouldUseHybridFlowWarp(
                sourceWidth: 3840,
                sourceHeight: 2160,
                targetFPS: .fps120,
                isHDR: false,
                isDolbyVision: false,
                is8BitSDRPixelFormat: true,
                allowExperimentalFlowWarp: false
            )
        )
        XCTAssertTrue(
            RemoteOpticalFlowBudgetPlanner.shouldUseHybridFlowWarp(
                sourceWidth: 3840,
                sourceHeight: 2160,
                targetFPS: .fps96,
                isHDR: false,
                isDolbyVision: false,
                is8BitSDRPixelFormat: true
            )
        )
        XCTAssertTrue(
            RemoteOpticalFlowBudgetPlanner.shouldUseHybridFlowWarp(
                sourceWidth: 3840,
                sourceHeight: 2160,
                targetFPS: .fps60,
                isHDR: false,
                isDolbyVision: false,
                is8BitSDRPixelFormat: true
            )
        )
        XCTAssertFalse(
            RemoteOpticalFlowBudgetPlanner.shouldUseHybridFlowWarp(
                sourceWidth: 3840,
                sourceHeight: 2160,
                targetFPS: .x2,
                isHDR: false,
                isDolbyVision: false,
                is8BitSDRPixelFormat: true
            )
        )
        XCTAssertEqual(OpticalFlowTargetFPS.fps96.effectiveTargetFPS(sourceFPS: 25.0), 100.0, accuracy: 0.01)
        XCTAssertEqual(OpticalFlowTargetFPS.fps96.maxInterpolatedFramesPerPair(sourceFPS: 25.0), 3)
        XCTAssertEqual(OpticalFlowResolutionPlanner.lowLatencyExponent(forInterpolatedFrames: 3), 2)
        XCTAssertFalse(
            RemoteOpticalFlowBudgetPlanner.shouldUseHybridFlowWarp(
                sourceWidth: 3840,
                sourceHeight: 2160,
                targetFPS: .fps120,
                isHDR: true,
                isDolbyVision: false,
                is8BitSDRPixelFormat: true
            )
        )
        XCTAssertFalse(
            RemoteOpticalFlowBudgetPlanner.shouldUseHybridFlowWarp(
                sourceWidth: 3840,
                sourceHeight: 2160,
                targetFPS: .fps120,
                isHDR: false,
                isDolbyVision: false,
                is8BitSDRPixelFormat: false
            )
        )
        XCTAssertFalse(
            RemoteOpticalFlowBudgetPlanner.shouldUseHybridFlowWarp(
                sourceWidth: 960,
                sourceHeight: 540,
                targetFPS: .fps120,
                isHDR: false,
                isDolbyVision: false,
                is8BitSDRPixelFormat: true
            )
        )

        let flowCaps120 = RemoteOpticalFlowBudgetPlanner.flowResolutionCaps(forMaxInterpolatedFrames: 5)
        XCTAssertEqual(flowCaps120.first?.0, 960)
        XCTAssertEqual(flowCaps120.first?.1, 540)
        let flowPlan120 = RemoteOpticalFlowBudgetPlanner.buildHybridFlowCandidates(
            sourceWidth: 3840,
            sourceHeight: 2160,
            maxInterpolatedFrames: 5
        )
        XCTAssertEqual(flowPlan120.count, 2)
        XCTAssertEqual(flowPlan120[0].width, 960)
        XCTAssertEqual(flowPlan120[0].height, 540)
        XCTAssertEqual(flowPlan120[1].width, 640)
        XCTAssertEqual(flowPlan120[1].height, 360)

        XCTAssertEqual(
            FlowVectorCalibrator.selectOptimalFlowSourceFormat(from: [kCVPixelFormatType_64RGBAHalf, kCVPixelFormatType_32BGRA]),
            kCVPixelFormatType_32BGRA
        )
        XCTAssertEqual(
            FlowVectorCalibrator.selectOptimalFlowSourceFormat(from: [kCVPixelFormatType_64RGBAHalf, kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertEqual(FlowVectorCalibrator.decodeFloat16(FlowVectorCalibrator.encodeFloat16(3.5)), 3.5, accuracy: 0.01)
        XCTAssertEqual(FlowVectorCalibrator.decodeFloat16(FlowVectorCalibrator.encodeFloat16(-2.25)), -2.25, accuracy: 0.01)
        XCTAssertEqual(FlowVectorCalibrator.decodeFloat16(FlowVectorCalibrator.encodeFloat16(0.0)), 0.0, accuracy: 0.0001)

        XCTAssertEqual(
            MetalVideoEnhancer.flowMetalPixelFormat(for: kCVPixelFormatType_TwoComponent16Half),
            .rg16Float
        )
        XCTAssertEqual(
            MetalVideoEnhancer.flowMetalPixelFormat(for: kCVPixelFormatType_TwoComponent32Float),
            .rg32Float
        )
        XCTAssertNil(
            MetalVideoEnhancer.flowMetalPixelFormat(for: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        )

        let enhancer = MetalVideoEnhancer()
        XCTAssertNil(enhancer.shaderInitError)
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.drawableSize = CGSize(width: 256, height: 144)

        let ioAttrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var prevOpt: CVPixelBuffer?
        var currOpt: CVPixelBuffer?
        var fwdOpt: CVPixelBuffer?
        var bwdOpt: CVPixelBuffer?

        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                128,
                72,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                ioAttrs as CFDictionary,
                &prevOpt
            ),
            kCVReturnSuccess
        )
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                128,
                72,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                ioAttrs as CFDictionary,
                &currOpt
            ),
            kCVReturnSuccess
        )
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                64,
                36,
                kCVPixelFormatType_TwoComponent16Half,
                ioAttrs as CFDictionary,
                &fwdOpt
            ),
            kCVReturnSuccess
        )
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                64,
                36,
                kCVPixelFormatType_TwoComponent16Half,
                ioAttrs as CFDictionary,
                &bwdOpt
            ),
            kCVReturnSuccess
        )

        let prevBuf = try XCTUnwrap(prevOpt)
        let currBuf = try XCTUnwrap(currOpt)
        let fwdBuf = try XCTUnwrap(fwdOpt)
        let bwdBuf = try XCTUnwrap(bwdOpt)

        func fillPattern(_ buf: CVPixelBuffer, shiftX: Float, shiftY: Float) {
            CVPixelBufferLockBaseAddress(buf, [])
            defer { CVPixelBufferUnlockBaseAddress(buf, []) }
            let w = CVPixelBufferGetWidth(buf)
            let h = CVPixelBufferGetHeight(buf)
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
            guard let ptr = CVPixelBufferGetBaseAddressOfPlane(buf, 0)?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<h {
                for x in 0..<w {
                    let sx = Float(x) - shiftX
                    let sy = Float(y) - shiftY
                    let v = 128.0 + 70.0 * sin(sx * 0.25) * cos(sy * 0.30)
                    ptr[y * bpr + x] = UInt8(max(16, min(235, Int(v.rounded()))))
                }
            }
        }
        func fillFlow(_ buf: CVPixelBuffer, dx: Float, dy: Float) {
            CVPixelBufferLockBaseAddress(buf, [])
            defer { CVPixelBufferUnlockBaseAddress(buf, []) }
            let w = CVPixelBufferGetWidth(buf)
            let h = CVPixelBufferGetHeight(buf)
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            guard let ptr = CVPixelBufferGetBaseAddress(buf) else { return }
            let hx = FlowVectorCalibrator.encodeFloat16(dx)
            let hy = FlowVectorCalibrator.encodeFloat16(dy)
            for y in 0..<h {
                let row = ptr.advanced(by: y * bpr).assumingMemoryBound(to: UInt16.self)
                for x in 0..<w {
                    row[x * 2] = hx
                    row[x * 2 + 1] = hy
                }
            }
        }

        fillPattern(prevBuf, shiftX: 0, shiftY: 0)
        fillPattern(currBuf, shiftX: 4, shiftY: 2)

        fillFlow(fwdBuf, dx: 2.0, dy: 1.0)
        let calNormal = try XCTUnwrap(FlowVectorCalibrator.calibrate(prevBuffer: prevBuf, currBuffer: currBuf, forwardFlow: fwdBuf))
        XCTAssertTrue(calNormal.isLocked)
        XCTAssertEqual(calNormal.signX, 1.0)
        XCTAssertEqual(calNormal.signY, 1.0)
        XCTAssertFalse(calNormal.isNormalizedUV)
        XCTAssertLessThan(calNormal.calibratedSAD, calNormal.baselineSAD * 0.5)

        fillFlow(fwdBuf, dx: 2.0, dy: -1.0)
        let calYFlip = try XCTUnwrap(FlowVectorCalibrator.calibrate(prevBuffer: prevBuf, currBuffer: currBuf, forwardFlow: fwdBuf))
        XCTAssertEqual(calYFlip.signX, 1.0)
        XCTAssertEqual(calYFlip.signY, -1.0)

        fillFlow(fwdBuf, dx: -2.0, dy: -1.0)
        let calInv = try XCTUnwrap(FlowVectorCalibrator.calibrate(prevBuffer: prevBuf, currBuffer: currBuf, forwardFlow: fwdBuf))
        XCTAssertEqual(calInv.signX, -1.0)
        XCTAssertEqual(calInv.signY, -1.0)

        fillFlow(fwdBuf, dx: 2.0, dy: 1.0)
        fillFlow(bwdBuf, dx: -2.0, dy: -1.0)

        let status = enhancer.renderFlowWarpedToLayerStatus(
            prevBuffer: prevBuf,
            currBuffer: currBuf,
            forwardFlow: fwdBuf,
            backwardFlow: bwdBuf,
            phase: 0.4,
            flowSignX: calNormal.signX,
            flowSignY: calNormal.signY,
            isNormalizedUV: calNormal.isNormalizedUV,
            on: metalLayer,
            preset: .off,
            strength: .standard,
            aspectFill: false,
            compareMode: .off,
            outputFPS: 120.0,
            thermalState: .nominal
        )
        if MTLCreateSystemDefaultDevice() != nil {
            XCTAssertEqual(status, .rendered)
            XCTAssertTrue(enhancer.activePipelineLabel.contains("光流变形"))
        } else {
            XCTAssertEqual(status, .unavailable)
        }
    }

    func testLocalHTTPStreamProxyHLSAndMislabeledFMP4VariantSwitch() async throws {
        let playJSON = Data((
            "{\"code\":0,\"data\":{\"video_list\":["
            + "{\"resolution\":\"super\",\"format\":\"fmp4\",\"video_info\":{\"url\":\"https://cdn.example.com/1080p_fmp4\",\"format\":\"mp4\"}},"
            + "{\"resolution\":\"high\",\"video_info\":{\"url\":\"https://cdn.example.com/1080p.m3u8\"}}"
            + "]}}"
        ).utf8)
        let headers = QuarkDriveClient.requestHeaders(cookie: "__pus=abc")
        let variants = QuarkDriveClient.parsePlayVariantsJSON(playJSON, headers: headers)
        XCTAssertEqual(variants.count, 2)
        XCTAssertFalse(variants[0].isHLS)
        XCTAssertTrue(variants[1].isHLS)

        let fakeFMP4Payload = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D]) + Data(repeating: 0x3C, count: 65536)
        let tsPayload = Data(repeating: 0x47, count: 4096)

        final class MockVariantServer: @unchecked Sendable {
            private let lock = NSLock()
            private let readySem = DispatchSemaphore(value: 0)
            private var port: UInt16 = 0

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
        }
        let server = MockVariantServer()
        let stubQueue = DispatchQueue(label: "com.glassmpv.test.hls_fmp4")
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                server.markReady(port: listener.port?.rawValue ?? 0)
            }
        }
        listener.newConnectionHandler = { conn in
            conn.start(queue: stubQueue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let reqStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let parsed = LocalHTTPStreamProxy.parseHTTPRequestHead(reqStr)
                let path = parsed?.path ?? ""
                if path.hasPrefix("/playlist.m3u8") {
                    let body = Data("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg0.ts\n#EXT-X-ENDLIST\n".utf8)
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    var pkt = Data(head.utf8)
                    pkt.append(body)
                    conn.send(content: pkt, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                } else if path.hasPrefix("/seg0.ts") {
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nContent-Length: \(tsPayload.count)\r\nConnection: close\r\n\r\n"
                    var pkt = Data(head.utf8)
                    pkt.append(tsPayload)
                    conn.send(content: pkt, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                } else {
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(fakeFMP4Payload.count)\r\nConnection: close\r\n\r\n"
                    var pkt = Data(head.utf8)
                    pkt.append(fakeFMP4Payload)
                    conn.send(content: pkt, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                }
            }
        }
        listener.start(queue: stubQueue)
        defer {
            listener.cancel()
            LocalHTTPStreamProxy.shared.resetRoutes()
        }

        let port = server.waitForPort()
        XCTAssertGreaterThan(port, 0)

        // 1) 验证真实 HLS manifest 改写 + 子分片透传
        let hlsUpstream = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/playlist.m3u8"))
        let hlsProxy = LocalHTTPStreamProxy.shared.registerStream(
            url: hlsUpstream,
            headers: ["Referer": "https://pan.quark.cn/"],
            isHLS: true
        )
        let (hlsData, hlsResp) = try await URLSession.shared.data(from: hlsProxy)
        XCTAssertEqual((hlsResp as? HTTPURLResponse)?.statusCode, 200)
        let rewrittenText = try XCTUnwrap(String(data: hlsData, encoding: .utf8))
        XCTAssertTrue(rewrittenText.contains("/sub/"))
        let segLine = try XCTUnwrap(
            rewrittenText.components(separatedBy: .newlines).first(where: { $0.hasPrefix("http://127.0.0.1:") })
        )
        let segURL = try XCTUnwrap(URL(string: segLine))
        let (segData, segResp) = try await URLSession.shared.data(from: segURL)
        XCTAssertEqual((segResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(segData, tsPayload)

        // 2) 验证即使误传 isHLS=true 的二进制 fmp4 流也能毫秒级直传而不卡死
        let fmp4Upstream = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/1080p_fmp4?auth=1"))
        let fmp4Proxy = LocalHTTPStreamProxy.shared.registerStream(
            url: fmp4Upstream,
            headers: ["Referer": "https://pan.quark.cn/"],
            isHLS: true
        )
        let (binData, binResp) = try await URLSession.shared.data(from: fmp4Proxy)
        XCTAssertEqual((binResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(binData, fakeFMP4Payload)
    }

    @MainActor
    func testEndToEndSimulatorRemoteVariantSwitchPlayback() async throws {
        let sampleURL = try await TestVideoGenerator.generateSampleMP4(
            durationSeconds: 1.5,
            width: 320,
            height: 180,
            fps: 24
        )
        let mp4Data = try Data(contentsOf: sampleURL)

        final class MockMP4RangeServer: @unchecked Sendable {
            private let lock = NSLock()
            private let readySem = DispatchSemaphore(value: 0)
            private var port: UInt16 = 0
            let bodyData: Data

            init(bodyData: Data) {
                self.bodyData = bodyData
            }

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
        }

        let mockServer = MockMP4RangeServer(bodyData: mp4Data)
        let stubQueue = DispatchQueue(label: "com.glassmpv.test.e2e_variant_switch")
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                mockServer.markReady(port: listener.port?.rawValue ?? 0)
            }
        }
        listener.newConnectionHandler = { conn in
            conn.start(queue: stubQueue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let reqStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let parsed = LocalHTTPStreamProxy.parseHTTPRequestHead(reqStr)
                let totalLen = Int64(mockServer.bodyData.count)
                let range = parsed?.rangeHeader.flatMap {
                    LocalHTTPStreamProxy.parseByteRangeHeader($0, totalLength: totalLen)
                } ?? (start: Int64(0), end: totalLen - 1)
                let slice = mockServer.bodyData.subdata(in: Int(range.start)..<Int(range.end + 1))
                let head = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Length: \(slice.count)\r\nContent-Range: bytes \(range.start)-\(range.end)/\(totalLen)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
                var pkt = Data(head.utf8)
                pkt.append(slice)
                conn.send(content: pkt, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            }
        }
        listener.start(queue: stubQueue)
        defer {
            listener.cancel()
            LocalHTTPStreamProxy.shared.resetRoutes()
        }

        let port = mockServer.waitForPort()
        XCTAssertGreaterThan(port, 0)

        let controller = OpticalFlowPlayerController()
        let displayContainer = SampleBufferDisplayContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        controller.attach(to: displayContainer)
        defer {
            controller.stop()
            _ = displayContainer
        }

        func waitFrames(timeout: TimeInterval) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if controller.errorMessage != nil || controller.presentedFrameCount > 0 {
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        let variantAURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/original_4k.mp4"))
        controller.load(
            url: variantAURL,
            spatial2x: false,
            targetFPS: .fps60,
            startAt: 0,
            autoPlay: true,
            enableInterpolation: false,
            httpHeaders: ["Referer": "https://pan.quark.cn/"],
            displayTitle: "SwitchTest",
            streamLabel: "原画直链",
            isHLS: false
        )
        try await waitFrames(timeout: 15.0)
        if controller.presentedFrameCount == 0 {
            controller.clearError()
            controller.load(
                url: variantAURL,
                spatial2x: false,
                targetFPS: .fps60,
                startAt: 0,
                autoPlay: true,
                enableInterpolation: false,
                httpHeaders: ["Referer": "https://pan.quark.cn/"],
                displayTitle: "SwitchTest",
                streamLabel: "原画直链",
                isHLS: false
            )
            try await waitFrames(timeout: 15.0)
        }
        XCTAssertNil(controller.errorMessage)
        XCTAssertGreaterThan(controller.presentedFrameCount, 0)

        let variantBURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/transcode_1080p"))
        controller.load(
            url: variantBURL,
            spatial2x: false,
            targetFPS: .fps60,
            startAt: 0.2,
            autoPlay: true,
            enableInterpolation: false,
            httpHeaders: ["Referer": "https://pan.quark.cn/"],
            displayTitle: "SwitchTest",
            streamLabel: "夸克 1080P+",
            isHLS: true
        )
        try await waitFrames(timeout: 15.0)
        XCTAssertNil(controller.errorMessage)
        XCTAssertGreaterThan(controller.presentedFrameCount, 0)
    }

    @MainActor
    func testPlayerOverlayNonOverlapAndTimelineRetention() throws {
        XCTAssertFalse(
            PlayerOverlayLayoutPolicy.shouldShowCenterTransportControls(
                showFPSPicker: false,
                showQualityPicker: false,
                isLoadingPipeline: true,
                presentedFrameCount: 0,
                hasError: false
            )
        )
        XCTAssertFalse(
            PlayerOverlayLayoutPolicy.shouldShowCenterTransportControls(
                showFPSPicker: false,
                showQualityPicker: false,
                isLoadingPipeline: false,
                presentedFrameCount: 10,
                hasError: true
            )
        )
        XCTAssertTrue(
            PlayerOverlayLayoutPolicy.shouldShowCenterTransportControls(
                showFPSPicker: false,
                showQualityPicker: false,
                isLoadingPipeline: false,
                presentedFrameCount: 10,
                hasError: false
            )
        )

        XCTAssertEqual(
            PlayerOverlayLayoutPolicy.activeCenterLoadingMessage(
                isImportingFile: true,
                isResolvingHistoryResume: true,
                hasActiveURL: true,
                hasError: false,
                isLoadingPipeline: true,
                presentedFrameCount: 0,
                pipelineStatusText: "加载中"
            ),
            "正在解析续播直链..."
        )
        XCTAssertNil(
            PlayerOverlayLayoutPolicy.activeCenterLoadingMessage(
                isImportingFile: false,
                isResolvingHistoryResume: false,
                hasActiveURL: true,
                hasError: false,
                isLoadingPipeline: false,
                presentedFrameCount: 12,
                pipelineStatusText: ""
            )
        )

        XCTAssertGreaterThan(
            PlayerOverlayLayoutPolicy.topBannerPaddingTop(showHUD: true, showStatsHUD: true),
            PlayerOverlayLayoutPolicy.topBannerPaddingTop(showHUD: true, showStatsHUD: false)
        )
        XCTAssertEqual(PlayerOverlayLayoutPolicy.compactStreamVariantLabel(from: "原画直链"), "原画")
        XCTAssertEqual(PlayerOverlayLayoutPolicy.compactStreamVariantLabel(from: "夸克 · 夸克 1080P+"), "1080P+")
    }

    func testMetalPyramidOpticalFlowRealMotionAccuracyAndSharpness() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            return
        }
        let width = 640
        let height = 360
        let ioAttrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        func makeFullRangeBuffer() throws -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            let st = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                ioAttrs as CFDictionary,
                &pb
            )
            XCTAssertEqual(st, kCVReturnSuccess)
            return try XCTUnwrap(pb)
        }

        func fillSyntheticScene(_ buf: CVPixelBuffer, blockCenterX: Float, blockCenterY: Float, invertScene: Bool = false) {
            CVPixelBufferLockBaseAddress(buf, [])
            defer { CVPixelBufferUnlockBaseAddress(buf, []) }
            let yBPR = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
            let uvBPR = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
            let uvW = CVPixelBufferGetWidthOfPlane(buf, 1)
            let uvH = CVPixelBufferGetHeightOfPlane(buf, 1)
            if let yPtr = CVPixelBufferGetBaseAddressOfPlane(buf, 0)?.assumingMemoryBound(to: UInt8.self) {
                for y in 0..<height {
                    for x in 0..<width {
                        if invertScene {
                            let val = 128.0 + 95.0 * cos(Float(x) * 0.11 - Float(y) * 0.09) * sin(Float(x + y) * 0.05)
                            yPtr[y * yBPR + x] = UInt8(max(0, min(255, Int(val.rounded()))))
                        } else {
                            let dx = Float(x) - blockCenterX
                            let dy = Float(y) - blockCenterY
                            let val: Float
                            if abs(dx) <= 72.0 && abs(dy) <= 52.0 {
                                let nx = dx / 72.0
                                let ny = dy / 52.0
                                let radial = sqrt(nx * nx + ny * ny)
                                val = 148.0 + 68.0 * (nx * 0.65 - ny * 0.45) + 42.0 * cos(radial * 4.5) * exp(-radial * 0.8)
                            } else {
                                val = 36.0 + 12.0 * sin(Float(x) * 0.05) * cos(Float(y) * 0.05)
                            }
                            yPtr[y * yBPR + x] = UInt8(max(0, min(255, Int(val.rounded()))))
                        }
                    }
                }
            }
            if let uvPtr = CVPixelBufferGetBaseAddressOfPlane(buf, 1)?.assumingMemoryBound(to: UInt8.self) {
                for y in 0..<uvH {
                    for x in 0..<uvW {
                        uvPtr[y * uvBPR + x * 2] = 128
                        uvPtr[y * uvBPR + x * 2 + 1] = 128
                    }
                }
            }
        }

        let prevBuf = try makeFullRangeBuffer()
        let currBuf = try makeFullRangeBuffer()
        let gtMidBuf = try makeFullRangeBuffer()
        let cutBuf = try makeFullRangeBuffer()

        fillSyntheticScene(prevBuf, blockCenterX: 280, blockCenterY: 180)
        fillSyntheticScene(currBuf, blockCenterX: 304, blockCenterY: 168)
        fillSyntheticScene(gtMidBuf, blockCenterX: 292, blockCenterY: 174)
        fillSyntheticScene(cutBuf, blockCenterX: 280, blockCenterY: 180, invertScene: true)

        let flowEngine = MetalPyramidOpticalFlowEngine()
        XCTAssertNil(flowEngine.shaderInitError)

        let flowRaw = await flowEngine.estimateFlow(prevBuffer: prevBuf, currBuffer: currBuf)
        let flowResult = try XCTUnwrap(flowRaw)
        XCTAssertFalse(flowResult.isSceneCut, "连续运动帧不应误触发切镜保护")

        func readFlowVector(texture: MTLTexture, normU: Double, normV: Double) -> (dxPx: Float, dyPx: Float) {
            let w = texture.width
            let h = texture.height
            let bpr = w * 4
            var raw = [UInt16](repeating: 0, count: w * h * 2)
            raw.withUnsafeMutableBytes { buf in
                if let base = buf.baseAddress {
                    texture.getBytes(base, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
                }
            }
            let tx = max(0, min(w - 1, Int((normU * Double(w)).rounded())))
            let ty = max(0, min(h - 1, Int((normV * Double(h)).rounded())))
            let idx = (ty * w + tx) * 2
            let fu = FlowVectorCalibrator.decodeFloat16(raw[idx])
            let fv = FlowVectorCalibrator.decodeFloat16(raw[idx + 1])
            return (fu * Float(width), fv * Float(height))
        }

        let fwdCenter = readFlowVector(texture: flowResult.forwardFlow.texture, normU: 280.0 / Double(width), normV: 180.0 / Double(height))
        XCTAssertEqual(fwdCenter.dxPx, 24.0, accuracy: 3.0, "前向光流 X 位移应精确追踪 +24px 物体运动")
        XCTAssertEqual(fwdCenter.dyPx, -12.0, accuracy: 3.0, "前向光流 Y 位移应精确追踪 -12px 物体运动")

        let bwdCenter = readFlowVector(texture: flowResult.backwardFlow.texture, normU: 304.0 / Double(width), normV: 168.0 / Double(height))
        XCTAssertEqual(bwdCenter.dxPx, -24.0, accuracy: 3.0, "后向光流 X 位移应精确追踪 -24px")
        XCTAssertEqual(bwdCenter.dyPx, 12.0, accuracy: 3.0, "后向光流 Y 位移应精确追踪 +12px")

        let bgVec = readFlowVector(texture: flowResult.forwardFlow.texture, normU: 60.0 / Double(width), normV: 60.0 / Double(height))
        XCTAssertLessThan(hypot(bgVec.dxPx, bgVec.dyPx), 1.5, "静止纹理背景光流应锁定接近 0，避免拖影模糊")

        let cutRaw = await flowEngine.estimateFlow(prevBuffer: prevBuf, currBuffer: cutBuf)
        let cutResult = try XCTUnwrap(cutRaw)
        XCTAssertTrue(cutResult.isSceneCut, "大幅切镜帧对必须触发 scene-cut 保护")

        let prevBox = RemoteSendablePixelBuffer(buffer: prevBuf)
        let currBox = RemoteSendablePixelBuffer(buffer: currBuf)
        let fwdBox = flowResult.forwardFlow
        let bwdBox = flowResult.backwardFlow
        let warpedBGRA: [UInt8] = try await MainActor.run {
            let enhancer = MetalVideoEnhancer()
            XCTAssertNil(enhancer.shaderInitError)
            return try XCTUnwrap(
                enhancer.renderFlowWarpedOffscreenForTesting(
                    prevBuffer: prevBox.buffer,
                    currBuffer: currBox.buffer,
                    forwardFlowTexture: fwdBox.texture,
                    backwardFlowTexture: bwdBox.texture,
                    phase: 0.5,
                    isSceneCut: false
                )
            )
        }

        CVPixelBufferLockBaseAddress(prevBuf, .readOnly)
        CVPixelBufferLockBaseAddress(currBuf, .readOnly)
        CVPixelBufferLockBaseAddress(gtMidBuf, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(gtMidBuf, .readOnly)
            CVPixelBufferUnlockBaseAddress(currBuf, .readOnly)
            CVPixelBufferUnlockBaseAddress(prevBuf, .readOnly)
        }
        let pPtr = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(prevBuf, 0)?.assumingMemoryBound(to: UInt8.self))
        let cPtr = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(currBuf, 0)?.assumingMemoryBound(to: UInt8.self))
        let gPtr = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(gtMidBuf, 0)?.assumingMemoryBound(to: UInt8.self))
        let pBPR = CVPixelBufferGetBytesPerRowOfPlane(prevBuf, 0)
        let cBPR = CVPixelBufferGetBytesPerRowOfPlane(currBuf, 0)
        let gBPR = CVPixelBufferGetBytesPerRowOfPlane(gtMidBuf, 0)

        var warpedBlockErr: Double = 0
        var prevBlockErr: Double = 0
        var blendBlockErr: Double = 0
        var blockSamples = 0
        for y in 140..<210 {
            for x in 242..<342 {
                let offset = (y * width + x) * 4
                let wY = Double(warpedBGRA[offset + 1])
                let gY = Double(gPtr[y * gBPR + x])
                let pY = Double(pPtr[y * pBPR + x])
                let cY = Double(cPtr[y * cBPR + x])
                warpedBlockErr += abs(wY - gY)
                prevBlockErr += abs(pY - gY)
                blendBlockErr += abs(0.5 * (pY + cY) - gY)
                blockSamples += 1
            }
        }
        let warpedMAE = warpedBlockErr / Double(blockSamples)
        let uninterpolatedMAE = prevBlockErr / Double(blockSamples)
        let naiveBlendMAE = blendBlockErr / Double(blockSamples)

        XCTAssertLessThan(warpedMAE, uninterpolatedMAE * 0.25, "t=0.5 运动区域必须真正跟随光流位移而非停留在原帧")
        XCTAssertLessThan(warpedMAE, naiveBlendMAE * 0.35, "t=0.5 运动区域必须清晰保真而非前后帧半透明重影")

        var bgErr: Double = 0
        var bgSamples = 0
        for y in 20..<100 {
            for x in 20..<120 {
                let offset = (y * width + x) * 4
                let wY = Double(warpedBGRA[offset + 1])
                let gY = Double(gPtr[y * gBPR + x])
                bgErr += abs(wY - gY)
                bgSamples += 1
            }
        }
        let bgMAE = bgErr / Double(bgSamples)
        XCTAssertLessThan(bgMAE, 4.0, "静止背景必须零降质直出")
    }

    func testRemoteDisplayCadenceGuardAndHighFPSQueueCapNoDrops() {
        var guardState = RemoteDisplayCadenceGuard()
        var presentedPTS: [Double] = []

        // 复现 b44 1440x810 故障：实时解码领先帧(725.00+)与延迟回退队列帧(724.92+)交错竞争
        XCTAssertTrue(guardState.shouldAcceptDirectFallback(samplePTS: 725.00, hostTime: 10.00, queueIsEmpty: true, interpolatedCount: 0, lastPresentedHostTime: 0))
        presentedPTS.append(725.00)

        XCTAssertFalse(guardState.shouldAcceptQueueFrame(mediaPTS: 724.92), "绝不允许回退呈递比当前更早的队列帧")
        XCTAssertFalse(guardState.shouldAcceptQueueFrame(mediaPTS: 724.96), "绝不允许回退呈递比当前更早的队列帧")
        XCTAssertFalse(guardState.shouldAcceptQueueFrame(mediaPTS: 725.00), "绝不允许重复呈递相同时间戳")

        XCTAssertTrue(guardState.shouldAcceptDirectFallback(samplePTS: 725.04, hostTime: 10.04, queueIsEmpty: true, interpolatedCount: 0, lastPresentedHostTime: 10.00))
        presentedPTS.append(725.04)

        XCTAssertTrue(guardState.shouldAcceptQueueFrame(mediaPTS: 725.08))
        presentedPTS.append(725.08)

        // 一旦队列帧生效，即使短暂队列抽空，也不允许在 0.35s 窗口内抢插直通帧造成时间跳变闪烁
        XCTAssertFalse(guardState.shouldAcceptDirectFallback(samplePTS: 725.20, hostTime: 10.12, queueIsEmpty: true, interpolatedCount: 0, lastPresentedHostTime: 10.08))
        XCTAssertTrue(guardState.shouldAcceptDirectFallback(samplePTS: 725.44, hostTime: 10.45, queueIsEmpty: true, interpolatedCount: 0, lastPresentedHostTime: 10.08), "超过 0.35s 真断流才允许救援")
        presentedPTS.append(725.44)

        for idx in 1..<presentedPTS.count {
            XCTAssertGreaterThan(presentedPTS[idx], presentedPTS[idx - 1], "呈递 PTS 必须严格单调递增，消除闪烁跳帧")
        }

        XCTAssertEqual(RemoteOpticalFlowBudgetPlanner.recommendedFlowQueueCap(targetFPS: 60.0, maxQueued: 30), 24)
        XCTAssertEqual(RemoteOpticalFlowBudgetPlanner.recommendedFlowQueueCap(targetFPS: 100.0, maxQueued: 50), 30)
        XCTAssertEqual(RemoteOpticalFlowBudgetPlanner.recommendedFlowQueueCap(targetFPS: 120.0, maxQueued: 60), 36)

        // 模拟 25fps -> 120fps 连续 2 秒推流，验证新上限 36 帧零队列头驱逐丢帧
        let cap = RemoteOpticalFlowBudgetPlanner.recommendedFlowQueueCap(targetFPS: 120.0, maxQueued: 60)
        var simQueue: [(pts: Double, buffer: Int)] = []
        var headEvictions = 0
        var clockPTS: Double = 0.0
        var pacerLag = RemoteOpticalFlowBudgetPlanner.recommendedMetalFlowPacerLagSeconds(sourceFPS: 25.0, averageFlowMs: 3.5)
        XCTAssertGreaterThanOrEqual(pacerLag, 0.075)
        XCTAssertLessThanOrEqual(pacerLag, 0.115)
        pacerLag = 0.085

        var nextPairIdx = 1
        for tick in 0..<240 {
            clockPTS = Double(tick) / 120.0
            let sourceInterval = 0.040
            if Double(nextPairIdx) * sourceInterval <= clockPTS + 0.0001 {
                let prevPTS = Double(nextPairIdx - 1) * sourceInterval
                for k in 1...4 {
                    if simQueue.count >= cap {
                        simQueue.removeFirst()
                        headEvictions += 1
                    }
                    simQueue.append((pts: prevPTS + Double(k) * 0.008, buffer: k))
                }
                if simQueue.count >= cap {
                    simQueue.removeFirst()
                    headEvictions += 1
                }
                simQueue.append((pts: Double(nextPairIdx) * sourceInterval, buffer: 5))
                nextPairIdx += 1
            }
            let pacerNow = max(0.0, clockPTS - pacerLag)
            _ = OpticalFlowFramePacer.dequeueNextFrame(from: &simQueue, now: pacerNow, isInterpolationEnabled: true, maxLateGraceSeconds: 0.120)
        }
        XCTAssertEqual(headEvictions, 0, "120fps 动态队列上限必须彻底消除未呈递帧静默驱逐丢帧")
    }

    func testRemoteSourceNormalizationAndVariantSwitchMetalFlow() async throws {
        XCTAssertTrue(RemoteOpticalFlowBudgetPlanner.shouldForceNormalizeSourceBuffer(hasNormPool: true))
        XCTAssertFalse(RemoteOpticalFlowBudgetPlanner.shouldForceNormalizeSourceBuffer(hasNormPool: false))

        let plan1440 = RemoteOpticalFlowBudgetPlanner.buildRemoteCandidatePlan(
            sourceWidth: 1440,
            sourceHeight: 810,
            maxInterpolatedFrames: 1
        )
        XCTAssertGreaterThanOrEqual(plan1440.count, 2, "1440x810 必须保留 1280x720 16-aligned 安全降级档")
        XCTAssertEqual(plan1440[0].width, 1440)
        XCTAssertEqual(plan1440[1].width, 1280)
        XCTAssertEqual(plan1440[1].height, 720)

        guard MTLCreateSystemDefaultDevice() != nil else {
            return
        }

        final class BatchRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var emittedMetalBatches = 0
            private var totalInterpolated = 0
            private var lastPTS: Double = -1
            private var monotonicOK = true

            func record(_ frames: [RemoteOpticalFlowOutputFrame], delta: Int) {
                lock.lock()
                let hasMetalWarp = frames.contains {
                    if case .metalFlowWarped = $0.payload { return true }
                    return false
                }
                if hasMetalWarp {
                    emittedMetalBatches += 1
                }
                totalInterpolated += delta
                for frame in frames {
                    if frame.pts <= lastPTS {
                        monotonicOK = false
                    }
                    lastPTS = frame.pts
                }
                lock.unlock()
            }

            func snapshot() -> (batches: Int, interpolated: Int, monotonic: Bool) {
                lock.lock()
                let out = (emittedMetalBatches, totalInterpolated, monotonicOK)
                lock.unlock()
                return out
            }
        }

        let recorder = BatchRecorder()
        let worker = RemoteStreamOpticalFlowWorker(
            targetFPS: .fps60,
            sourceFPS: 25.0
        ) { frames, delta, _, _ in
            recorder.record(frames, delta: delta)
        }

        func makeBuffer(width: Int, height: Int, shift: Float) throws -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            let ioAttrs: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            XCTAssertEqual(
                CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, ioAttrs as CFDictionary, &pb),
                kCVReturnSuccess
            )
            let buf = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddressOfPlane(buf, 0)?.assumingMemoryBound(to: UInt8.self) {
                let bpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
                for y in stride(from: 0, to: height, by: 2) {
                    for x in stride(from: 0, to: width, by: 2) {
                        let v = UInt8(max(16, min(235, Int(128 + 60 * sin((Float(x) - shift) * 0.08) * cos(Float(y) * 0.08)))))
                        base[y * bpr + x] = v
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            return buf
        }

        for i in 0..<4 {
            let buf = try makeBuffer(width: 1440, height: 810, shift: Float(i * 4))
            worker.submitFrame(pts: Double(i) * 0.04, box: RemoteSendablePixelBuffer(buffer: buf))
        }
        try await Task.sleep(for: .milliseconds(350))

        worker.reconfigure(targetFPS: .fps120, sourceFPS: 25.0)
        for i in 0..<4 {
            let pts = 1.0 + Double(i) * 0.04
            let buf = try makeBuffer(width: 1920, height: 1080, shift: Float(i * 6))
            worker.submitFrame(pts: pts, box: RemoteSendablePixelBuffer(buffer: buf))
        }
        try await Task.sleep(for: .milliseconds(450))

        let snap = recorder.snapshot()
        XCTAssertGreaterThanOrEqual(snap.batches, 4, "60/120fps 跨分辨率切换后必须稳定输出 Metal GPU 原生光流变形帧")
        XCTAssertGreaterThan(snap.interpolated, 10)
        XCTAssertTrue(monotonicSnapshotIfNeeded(snap.monotonic), "跨分辨率重配后的输出帧时间戳必须严格递增")
    }

    private func monotonicSnapshotIfNeeded(_ v: Bool) -> Bool { v }

    func testNonInterpolatedDisplayRatePreventsLTPOFrameDrop() {
        for srcFPS in [23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 60.0] {
            let range = OpticalFlowResolutionPlanner.recommendedDisplayFrameRateRange(
                targetFPS: srcFPS,
                isInterpolationEnabled: false,
                maxScreenFPS: 120,
                isLowPowerMode: false
            )
            XCTAssertEqual(range.minimum, 60, "关闭补帧轮询 \(srcFPS)fps 时最低刷新率必须锁定 60Hz，防止 ProMotion LTPO 跌至 13-16fps")
            XCTAssertEqual(range.maximum, 60)
            XCTAssertEqual(range.preferred, 60)
        }
    }

    func testMetalPyramidAntiGhostingAndSharpMovingEdge() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            return
        }
        let width = 640
        let height = 360
        let ioAttrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        func makeFullRangeBuffer() throws -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            let st = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                ioAttrs as CFDictionary,
                &pb
            )
            XCTAssertEqual(st, kCVReturnSuccess)
            return try XCTUnwrap(pb)
        }

        func fillSilhouette(_ buf: CVPixelBuffer, centerX: Float, centerY: Float) {
            CVPixelBufferLockBaseAddress(buf, [])
            defer { CVPixelBufferUnlockBaseAddress(buf, []) }
            let yBPR = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
            let uvBPR = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
            let uvW = CVPixelBufferGetWidthOfPlane(buf, 1)
            let uvH = CVPixelBufferGetHeightOfPlane(buf, 1)
            if let yPtr = CVPixelBufferGetBaseAddressOfPlane(buf, 0)?.assumingMemoryBound(to: UInt8.self) {
                for y in 0..<height {
                    for x in 0..<width {
                        let dx = Float(x) - centerX
                        let dy = Float(y) - centerY
                        let val: Float
                        if abs(dx) <= 80.0 && abs(dy) <= 60.0 {
                            let nx = dx / 80.0
                            let ny = dy / 60.0
                            val = 180.0 + 35.0 * (nx * 0.65 - ny * 0.35)
                        } else {
                            val = 30.0 + 8.0 * sin(Float(x) * 0.05) * cos(Float(y) * 0.05)
                        }
                        yPtr[y * yBPR + x] = UInt8(max(0, min(255, Int(val.rounded()))))
                    }
                }
            }
            if let uvPtr = CVPixelBufferGetBaseAddressOfPlane(buf, 1)?.assumingMemoryBound(to: UInt8.self) {
                for y in 0..<uvH {
                    for x in 0..<uvW {
                        uvPtr[y * uvBPR + x * 2] = 128
                        uvPtr[y * uvBPR + x * 2 + 1] = 128
                    }
                }
            }
        }

        let prevBuf = try makeFullRangeBuffer()
        let currBuf = try makeFullRangeBuffer()
        fillSilhouette(prevBuf, centerX: 260, centerY: 180)
        fillSilhouette(currBuf, centerX: 280, centerY: 180)

        let flowEngine = MetalPyramidOpticalFlowEngine()
        XCTAssertNil(flowEngine.shaderInitError)
        let flowRaw = await flowEngine.estimateFlow(prevBuffer: prevBuf, currBuffer: currBuf)
        let flowResult = try XCTUnwrap(flowRaw)

        let prevBox = RemoteSendablePixelBuffer(buffer: prevBuf)
        let currBox = RemoteSendablePixelBuffer(buffer: currBuf)
        let fwdBox = flowResult.forwardFlow
        let bwdBox = flowResult.backwardFlow
        let warpedBGRA: [UInt8] = try await MainActor.run {
            let enhancer = MetalVideoEnhancer()
            XCTAssertNil(enhancer.shaderInitError)
            return try XCTUnwrap(
                enhancer.renderFlowWarpedOffscreenForTesting(
                    prevBuffer: prevBox.buffer,
                    currBuffer: currBox.buffer,
                    forwardFlowTexture: fwdBox.texture,
                    backwardFlowTexture: bwdBox.texture,
                    phase: 0.5,
                    isSceneCut: false
                )
            )
        }

        // 检查右前沿与左后沿遮挡带 (x in 332..<368, y in 140..<220) 的虚影比例与边缘锐度
        var ghostPixels = 0
        var totalBandPixels = 0
        var maxEdgeStep = 0
        for y in 140..<220 {
            for x in 332..<368 {
                let lum = Int(warpedBGRA[(y * width + x) * 4 + 1])
                if lum >= 75 && lum <= 155 {
                    ghostPixels += 1
                }
                totalBandPixels += 1
            }
            for x in 342..<358 {
                let lumA = Int(warpedBGRA[(y * width + x) * 4 + 1])
                let lumB = Int(warpedBGRA[(y * width + x + 2) * 4 + 1])
                maxEdgeStep = max(maxEdgeStep, abs(lumA - lumB))
            }
        }
        let ghostRatio = Double(ghostPixels) / Double(max(1, totalBandPixels))
        XCTAssertLessThan(ghostRatio, 0.10, "遮挡过渡带不应出现大面积 50/50 人物虚影")
        XCTAssertGreaterThanOrEqual(maxEdgeStep, 90, "运动物体边缘在 t=0.5 必须保持陡峭清晰而非拖尾模糊")
    }
}
