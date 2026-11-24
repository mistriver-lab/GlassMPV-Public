import AVFoundation
import Foundation
import QuartzCore
import UIKit
import XCTest
@testable import GlassMPV

private struct TestSendableBox<T>: @unchecked Sendable {
    let value: T
}

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

    @MainActor
    func testMPVCoreHeadlessPlayback() async throws {
        let sampleURL = try await TestVideoGenerator.generateSampleMP4(
            durationSeconds: 3.0,
            width: 640,
            height: 360,
            fps: 30
        )

        let controller = MPVPlayerController()
        controller.attachHeadlessForTesting()
        XCTAssertTrue(
            controller.isInitialized,
            "mpv_initialize 失败: \(controller.lastErrorMessage ?? "unknown")"
        )

        controller.load(url: sampleURL)

        let deadline = Date().addingTimeInterval(10.0)
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

        controller.shutdown()
        XCTAssertFalse(controller.isInitialized)
    }

    @MainActor
    func testMetalContainerViewSublayerAndEDRThreadSafety() async throws {
        let container = MPVMetalContainerView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        XCTAssertFalse(container.layer is MPVMetalLayer, "不应通过重写 layerClass 绑定容器图层")
        XCTAssertTrue(
            container.layer.sublayers?.contains(where: { $0 === container.metalLayer }) ?? false,
            "MPVMetalLayer 应作为独立子图层 addSublayer 挂载"
        )

        container.metalLayer.drawableSize = CGSize(width: 390, height: 844)
        container.metalLayer.drawableSize = CGSize(width: 1, height: 1)
        XCTAssertEqual(Int(container.metalLayer.drawableSize.width), 390, "应拦截 1x1 临时 drawableSize 缩水")
        XCTAssertEqual(Int(container.metalLayer.drawableSize.height), 844)

        let layerBox = TestSendableBox(value: container.metalLayer)
        let bgDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            layerBox.value.wantsExtendedDynamicRangeContent = true
            layerBox.value.wantsExtendedDynamicRangeContent = false
            bgDone.signal()
        }
        let waitResult = bgDone.wait(timeout: .now() + 2.0)
        XCTAssertEqual(waitResult, .success, "后台线程写入 wantsExtendedDynamicRangeContent 不应同步阻塞导致死锁")
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}
