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
    func testAll58GLSLShadersPresentAndResolvable() throws {
        let shadersURL = try XCTUnwrap(
            Bundle.main.resourceURL?.appendingPathComponent("Shaders", isDirectory: true),
            "Bundle.main 中缺少 Shaders 目录"
        )
        let contents = try FileManager.default.contentsOfDirectory(
            at: shadersURL,
            includingPropertiesForKeys: nil
        )
        let glslFiles = contents.filter { $0.pathExtension.lowercased() == "glsl" }
        XCTAssertEqual(glslFiles.count, 58, "应打包全部 58 个 GLSL 着色器，实际为 \(glslFiles.count)")

        for preset in ShaderPreset.allPresets {
            let resolved = SingleShaderOption.resolvedShaderPaths(preset: preset, extras: [])
            XCTAssertEqual(
                resolved.count,
                preset.shaderFiles.count,
                "预设 \(preset.id) 的着色器解析数量不匹配"
            )
        }

        let allExtraIDs = Set(SingleShaderOption.allOptions.map(\.id))
        let resolvedExtras = SingleShaderOption.resolvedShaderPaths(preset: .off, extras: allExtraIDs)
        XCTAssertEqual(resolvedExtras.count, SingleShaderOption.allOptions.count)
    }

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

    @MainActor
    func testMPVUIControllerPlaybackWithWindowHost() async throws {
        let sampleURL = try await TestVideoGenerator.generateSampleMP4(
            durationSeconds: 3.0,
            width: 640,
            height: 360,
            fps: 30
        )

        let controller = MPVPlayerController()
        XCTAssertTrue(controller.isInitialized)

        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.windowLevel = .normal + 1
        let hostController = UIHostingController(rootView: MPVVideoSurface(controller: controller))
        window.rootViewController = hostController
        window.makeKeyAndVisible()
        hostController.view.setNeedsLayout()
        hostController.view.layoutIfNeeded()

        defer {
            controller.shutdown()
            window.isHidden = true
            window.rootViewController = nil
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        controller.load(url: sampleURL)

        let deadline = Date().addingTimeInterval(30.0)
        while Date() < deadline {
            if controller.lastErrorMessage != nil {
                break
            }
            if controller.duration > 2.0,
               controller.videoWidth == 640,
               controller.videoHeight == 360,
               controller.currentTime > 0.1 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let logsDump = controller.diagnosticLogs.joined(separator: "\n")
        XCTAssertNil(controller.lastErrorMessage, "播放过程不应报错，日志:\n\(logsDump)")
        XCTAssertGreaterThan(controller.duration, 2.0, "应解析出测试视频时长，日志:\n\(logsDump)")
        XCTAssertEqual(controller.videoWidth, 640, "应解出视频宽度 640，日志:\n\(logsDump)")
        XCTAssertEqual(controller.videoHeight, 360, "应解出视频高度 360，日志:\n\(logsDump)")
        XCTAssertGreaterThan(controller.currentTime, 0.1, "播放时间戳应向前推进，日志:\n\(logsDump)")

        controller.applyInterpolation(.mpvSmooth120Hz)
        controller.applyShaders(preset: .off, extras: [])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(controller.lastErrorMessage, "运行时切换插帧与着色器不应报错，日志:\n\(logsDump)")

        controller.shutdown()
        XCTAssertFalse(controller.isInitialized)
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
            engineBadge: "MPV",
            interpolationBadge: "原帧率",
            codec: "hevc",
            width: 1920,
            height: 1080,
            sourceFPS: 23.976,
            outputFPS: 24.0,
            displayFPS: 120,
            bitDepth: "10-bit",
            hdrTag: "HDR10",
            isHDRActive: false,
            decoderBadge: "硬解 VT",
            droppedFrames: 0,
            activeShaderCount: 2,
            thermalLevel: .nominal
        )
        XCTAssertEqual(metrics.videoStreamSummary, "HEVC · 1920×1080 · 10-bit HDR10")
        XCTAssertEqual(metrics.fpsSummary, "23.98 → 24.0 fps · 120Hz")
        XCTAssertEqual(metrics.pipelineSummary, "硬解 VT · 原帧率 · 2着色器")
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
        XCTAssertFalse(SuperResolutionPolicy.isAlready4K(width: 1920, height: 1080))
        XCTAssertFalse(SuperResolutionPolicy.isAlready4K(width: 2560, height: 1440))
        XCTAssertFalse(SuperResolutionPolicy.isAlready4K(width: 0, height: 0))

        XCTAssertNotNil(SuperResolutionPolicy.disabledReason(width: 3840, height: 2160))
        XCTAssertNil(SuperResolutionPolicy.disabledReason(width: 1920, height: 1080))
    }

    func testDiagnosticLogExporterBuildAndWrite() throws {
        let report = DiagnosticLogExporter.buildReport(
            version: "v2026.11.25",
            engineName: "MPV 超分核",
            playbackState: "播放中",
            resolution: "1920×1080",
            fpsSummary: "24.0 → 120.0 fps",
            decoderSummary: "HEVC / 硬解 VT",
            is4KGated: false,
            telemetrySummary: ["MPV Target Sync: 120 Hz", "ANE Clock: 合成单调时钟"],
            selfCheck: "self-check-ok",
            mpvLogs: ["[mpv] ready"],
            opticalLogs: ["[ane] idle"]
        )
        XCTAssertTrue(report.contains("GlassMPV v2026.11.25"))
        XCTAssertTrue(report.contains("4K Super-Res Gated: NO"))
        XCTAssertTrue(report.contains("--- Interpolation Telemetry ---"))
        XCTAssertTrue(report.contains("ANE Clock: 合成单调时钟"))
        XCTAssertTrue(report.contains("--- Self Check ---"))
        XCTAssertTrue(report.contains("self-check-ok"))
        XCTAssertTrue(report.contains("--- MPV Logs (1) ---"))
        XCTAssertTrue(report.contains("[mpv] ready"))
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

    @MainActor
    func testMPVProMotionKeeperAndHonestDisplaySyncFPS() {
        let keeper = ProMotionDisplayLinkKeeper()
        defer { keeper.stop() }
        for i in 0..<6 {
            _ = keeper.recordSample(timestamp: 10.0 + Double(i) / 120.0)
        }
        XCTAssertEqual(keeper.measuredRefreshHz, 120.0, accuracy: 0.5)

        let controller = MPVPlayerController()
        defer { controller.shutdown() }

        controller.applyInterpolation(.mpvSmooth120Hz)
        XCTAssertGreaterThanOrEqual(controller.targetDisplaySyncFPS, 60)
        XCTAssertEqual(controller.displaySyncFPS, 0, "未从 libmpv 采集到真实显示刷新率前不应伪造 displaySyncFPS")
        XCTAssertFalse(controller.isProMotionKeeperActive, "暂停状态不应启动 ProMotion 保活链路")

        controller.refreshDiagnosticsSnapshot()
        XCTAssertEqual(controller.displaySyncFPS, 0)

        controller.applyInterpolation(.off)
        XCTAssertEqual(controller.targetDisplaySyncFPS, 0)
    }

    func testMPVProbeSnapshotParsingAndVerdictEvaluation() throws {
        let validLine = "[14:32:42] [mpv-probe] sync_active=yes video_sync=display-resample interp=yes tscale=mitchell vsync_ratio=5.00 disp_fps=120.0 est_disp=119.9"
        let probe = try XCTUnwrap(MPVProbeSnapshot.parse(from: validLine))
        XCTAssertEqual(probe.displaySyncActive, true)
        XCTAssertEqual(probe.videoSync, "display-resample")
        XCTAssertEqual(probe.interpolation, true)
        XCTAssertEqual(probe.tscale, "mitchell")
        XCTAssertEqual(try XCTUnwrap(probe.vsyncRatio), 5.0, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(probe.displayFPS), 120.0, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(probe.estimatedDisplayFPS), 119.9, accuracy: 1e-4)

        let partialLine = "[mpv-probe] sync_active=${display-sync-active} video_sync=(unavailable) interp=no tscale= vsync_ratio=0 disp_fps=0 est_disp=-1"
        let partialProbe = try XCTUnwrap(MPVProbeSnapshot.parse(from: partialLine))
        XCTAssertNil(partialProbe.displaySyncActive)
        XCTAssertEqual(partialProbe.videoSync, "")
        XCTAssertEqual(partialProbe.interpolation, false)
        XCTAssertEqual(partialProbe.tscale, "")
        XCTAssertEqual(try XCTUnwrap(partialProbe.vsyncRatio), 0.0, accuracy: 1e-6)
        XCTAssertNil(partialProbe.displayFPS)
        XCTAssertNil(partialProbe.estimatedDisplayFPS)

        XCTAssertNil(MPVProbeSnapshot.parse(from: "[vo/gpu-next] frame rendered"))

        XCTAssertEqual(
            InterpolationVerdict.evaluateMPV(
                mode: .off,
                probe: probe,
                targetDisplaySyncFPS: 120,
                reportedDisplayFPS: 120,
                measuredProMotionFPS: 120
            ),
            .off
        )

        let activeMPV = InterpolationVerdict.evaluateMPV(
            mode: .mpvSmooth120Hz,
            probe: probe,
            targetDisplaySyncFPS: 120,
            reportedDisplayFPS: 120,
            measuredProMotionFPS: 120
        )
        XCTAssertTrue(activeMPV.isEffective)
        XCTAssertEqual(activeMPV.shortLabel, "MPV平滑生效")

        let inactiveProbe = try XCTUnwrap(
            MPVProbeSnapshot.parse(from: "[mpv-probe] sync_active=no video_sync=audio interp=yes tscale=mitchell vsync_ratio=1.00 disp_fps=60.0 est_disp=60.0")
        )
        let inactiveMPV = InterpolationVerdict.evaluateMPV(
            mode: .mpvSmooth120Hz,
            probe: inactiveProbe,
            targetDisplaySyncFPS: 120,
            reportedDisplayFPS: 60,
            measuredProMotionFPS: 120
        )
        XCTAssertFalse(inactiveMPV.isEffective)
        XCTAssertEqual(inactiveMPV.shortLabel, "MPV平滑未生效")

        let pendingMPV = InterpolationVerdict.evaluateMPV(
            mode: .mpvSmooth120Hz,
            probe: nil,
            targetDisplaySyncFPS: 120,
            reportedDisplayFPS: 0,
            measuredProMotionFPS: 120
        )
        XCTAssertFalse(pendingMPV.isEffective)
        XCTAssertEqual(pendingMPV.shortLabel, "MPV等待探针")

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

    func testRuntimeTelemetrySampleFormattingAndReportInclusion() throws {
        let probe = try XCTUnwrap(
            MPVProbeSnapshot.parse(from: "[mpv-probe] sync_active=yes video_sync=display-resample interp=yes tscale=mitchell vsync_ratio=5.00 disp_fps=120.0 est_disp=120.0")
        )
        let mpvSample = RuntimeTelemetrySample(
            engine: "MPV 超分核",
            playbackState: "播放中",
            mediaTime: 12.5,
            width: 1920,
            height: 1080,
            sourceFPS: 24.0,
            outputFPS: 24.0,
            displayFPS: 120.0,
            proMotionFPS: 120.0,
            droppedFrames: 0,
            mistimedFrames: 1,
            delayedFrames: 0,
            mpvProbe: probe,
            aneInterpolated: 0,
            aneSkipped: 0,
            aneFailed: 0,
            anePresented: 0,
            aneAvgMs: 0,
            verdictLabel: "MPV平滑生效",
            thermalLevel: .nominal
        )
        let aneSample = RuntimeTelemetrySample(
            engine: "ANE 光流核",
            playbackState: "播放中",
            mediaTime: 14.0,
            width: 1920,
            height: 1080,
            sourceFPS: 24.0,
            outputFPS: 48.0,
            displayFPS: 0,
            proMotionFPS: 0,
            droppedFrames: 0,
            mistimedFrames: 0,
            delayedFrames: 0,
            mpvProbe: nil,
            aneInterpolated: 48,
            aneSkipped: 0,
            aneFailed: 0,
            anePresented: 96,
            aneAvgMs: 6.2,
            verdictLabel: "ANE光流生效",
            thermalLevel: .fair
        )

        let mpvLine = mpvSample.formatLogLine(timeString: "14:32:42")
        XCTAssertTrue(mpvLine.contains("[14:32:42] [MPV]"))
        XCTAssertTrue(mpvLine.contains("1920x1080"))
        XCTAssertTrue(mpvLine.contains("probe(sync=yes,interp=yes,tscale=mitchell,vsync=5.00)"))
        XCTAssertTrue(mpvLine.contains("verdict=MPV平滑生效"))

        let aneLine = aneSample.formatLogLine(timeString: "14:32:44")
        XCTAssertTrue(aneLine.contains("[14:32:44] [ANE]"))
        XCTAssertTrue(aneLine.contains("ane(interp=48,skip=0,fail=0,pres=96,avg=6.2ms)"))
        XCTAssertTrue(aneLine.contains("verdict=ANE光流生效"))

        let report = DiagnosticLogExporter.buildReport(
            version: "v2026.11.25",
            engineName: "MPV 超分核",
            playbackState: "播放中",
            resolution: "1920×1080",
            fpsSummary: "24.0 → 120.0 fps",
            decoderSummary: "HEVC / 硬解 VT",
            is4KGated: false,
            telemetrySummary: ["Interpolation Verdict: MPV平滑生效"],
            runtimeTimeline: [mpvLine, aneLine],
            selfCheck: "ok",
            mpvLogs: [],
            opticalLogs: []
        )
        XCTAssertTrue(report.contains("--- Runtime Telemetry Timeline (2) ---"))
        XCTAssertTrue(report.contains(mpvLine))
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

        let fitted1080 = OpticalFlowResolutionPlanner.fitProportionally(
            width: 1920,
            height: 1080,
            maxLongSide: 1920,
            maxShortSide: 1080
        )
        XCTAssertEqual(fitted1080.width, 1920)
        XCTAssertEqual(fitted1080.height, 1080)

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

        let plan4K = OpticalFlowResolutionPlanner.buildCandidatePlan(
            sourceWidth: 2960,
            sourceHeight: 2160,
            requestedSpatial2x: true,
            lowLatencySupported: true,
            frcSupported: true
        )
        XCTAssertFalse(plan4K.contains(where: { $0.spatial2x }), "4K 片源应禁止 spatial2x")
        XCTAssertEqual(plan4K.first, OpticalFlowCandidate(backend: .lowLatency, width: 1480, height: 1080, spatial2x: false))
        XCTAssertEqual(plan4K.dropFirst().first, OpticalFlowCandidate(backend: .frameRateConversion, width: 1480, height: 1080, spatial2x: false))
        XCTAssertTrue(plan4K.contains(OpticalFlowCandidate(backend: .lowLatency, width: 986, height: 720, spatial2x: false)))
        XCTAssertTrue(plan4K.contains(OpticalFlowCandidate(backend: .frameRateConversion, width: 740, height: 540, spatial2x: false)))
        XCTAssertEqual(Set(plan4K).count, plan4K.count)

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
        // 1. OpticalFlowTargetFPS 档位契约
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

        // 24p -> 2x/96fps 属 2 的幂倍率；24p -> 60/72/120fps 非 2 的幂（优先 FRC）
        XCTAssertTrue(OpticalFlowTargetFPS.x2.isPowerOfTwoMultiplier(sourceFPS: 23.976))
        XCTAssertTrue(OpticalFlowTargetFPS.fps96.isPowerOfTwoMultiplier(sourceFPS: 23.976))
        XCTAssertFalse(OpticalFlowTargetFPS.fps60.isPowerOfTwoMultiplier(sourceFPS: 24.0))
        XCTAssertFalse(OpticalFlowTargetFPS.fps72.isPowerOfTwoMultiplier(sourceFPS: 24.0))
        XCTAssertFalse(OpticalFlowTargetFPS.fps120.isPowerOfTwoMultiplier(sourceFPS: 24.0))
        XCTAssertTrue(OpticalFlowTargetFPS.fps60.isPowerOfTwoMultiplier(sourceFPS: 30.0))
        XCTAssertTrue(OpticalFlowTargetFPS.fps120.isPowerOfTwoMultiplier(sourceFPS: 30.0))

        XCTAssertEqual(OpticalFlowTargetFPS.x2.maxInterpolatedFramesPerPair(sourceFPS: 24.0), 1)
        XCTAssertEqual(OpticalFlowTargetFPS.fps60.maxInterpolatedFramesPerPair(sourceFPS: 24.0), 3)
        XCTAssertEqual(OpticalFlowTargetFPS.fps72.maxInterpolatedFramesPerPair(sourceFPS: 24.0), 2)
        XCTAssertEqual(OpticalFlowTargetFPS.fps96.maxInterpolatedFramesPerPair(sourceFPS: 24.0), 3)
        XCTAssertEqual(OpticalFlowTargetFPS.fps120.maxInterpolatedFramesPerPair(sourceFPS: 24.0), 4)
        XCTAssertEqual(OpticalFlowTargetFPS.fps60.maxInterpolatedFramesPerPair(sourceFPS: 60.0), 0)

        // 2. 队列上限推荐与双后端排序（preferFRC + [×N] 标签）
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

        // 3. 整倍等分相位调度（24p -> 2x / 72 / 96 / 120）
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

        // 4. 非整倍时间栅格重采样（24p -> 60fps 模拟 1 秒 24 帧）
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

        // 5. 算力预算守卫：连续超预算先降分辨率，冷却期保持，冷却后且无法再降分辨率时降目标帧率
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
        // 冷却期 2 次忽略
        XCTAssertEqual(guardState.recordPair(processMs: 50, sourceIntervalMs: 41.6, skippedForCatchUp: true, canDowngradeResolution: false, canDowngradeTargetFPS: true), .keep)
        XCTAssertEqual(guardState.recordPair(processMs: 50, sourceIntervalMs: 41.6, skippedForCatchUp: true, canDowngradeResolution: false, canDowngradeTargetFPS: true), .keep)
        // 冷却结束后连续 2 次追帧跳过，且无更低分辨率 -> 降目标帧率
        XCTAssertEqual(guardState.recordPair(processMs: 0, sourceIntervalMs: 41.6, skippedForCatchUp: true, canDowngradeResolution: false, canDowngradeTargetFPS: true), .keep)
        XCTAssertEqual(guardState.recordPair(processMs: 0, sourceIntervalMs: 41.6, skippedForCatchUp: true, canDowngradeResolution: false, canDowngradeTargetFPS: true), .downgradeTargetFPS)

        // 6. 遥测判定与黑匣子格式含目标帧率标签
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
            engine: "ANE 光流核",
            playbackState: "播放中",
            mediaTime: 3.5,
            width: 1480,
            height: 1080,
            sourceFPS: 24.0,
            outputFPS: 95.8,
            displayFPS: 0,
            proMotionFPS: 0,
            droppedFrames: 0,
            mistimedFrames: 0,
            delayedFrames: 0,
            mpvProbe: nil,
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
}
