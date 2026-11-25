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

        let deadline = Date().addingTimeInterval(12.0)
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
            selfCheck: "self-check-ok",
            mpvLogs: ["[mpv] ready"],
            opticalLogs: ["[ane] idle"]
        )
        XCTAssertTrue(report.contains("GlassMPV v2026.11.25"))
        XCTAssertTrue(report.contains("4K Super-Res Gated: NO"))
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
}
