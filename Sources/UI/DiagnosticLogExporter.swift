import Foundation
import UIKit

/// 诊断报告构造与 .txt 日志文件导出器
enum DiagnosticLogExporter: Sendable {
    static func buildReport(
        version: String,
        engineName: String,
        playbackState: String,
        resolution: String,
        fpsSummary: String,
        decoderSummary: String,
        is4KGated: Bool,
        selfCheck: String,
        mpvLogs: [String],
        opticalLogs: [String]
    ) -> String {
        var sections: [String] = [
            "GlassMPV \(version)",
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "Engine: \(engineName)",
            "State: \(playbackState)",
            "Resolution: \(resolution)",
            "FPS: \(fpsSummary)",
            "Decoder: \(decoderSummary)",
            "4K Super-Res Gated: \(is4KGated ? "YES" : "NO")",
            "",
            "--- Self Check ---",
            selfCheck.isEmpty ? "(none)" : selfCheck,
            "",
            "--- MPV Logs (\(mpvLogs.count)) ---"
        ]
        if mpvLogs.isEmpty {
            sections.append("(no mpv logs)")
        } else {
            sections.append(contentsOf: mpvLogs)
        }
        sections.append("")
        sections.append("--- Optical Flow Logs (\(opticalLogs.count)) ---")
        if opticalLogs.isEmpty {
            sections.append("(no optical flow logs)")
        } else {
            sections.append(contentsOf: opticalLogs)
        }
        return sections.joined(separator: "\n")
    }

    static func writeLogFile(content: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassMPV-Log-\(stamp).txt")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}

/// 原生系统分享表单调度器，用于导出诊断日志 .txt 文件
@MainActor
enum NativeShareSheetPresenter {
    static func present(fileURL: URL, onError: ((String) -> Void)? = nil) {
        let windowScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let activeScene = windowScenes.first { $0.activationState == .foregroundActive }
            ?? windowScenes.first { $0.activationState == .foregroundInactive }
            ?? windowScenes.first

        guard let scene = activeScene,
              let rootWindow = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first,
              var topVC = rootWindow.rootViewController else {
            onError?("无法获取当前窗口控制器，无法弹出系统分享面板。")
            return
        }
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(
                x: topVC.view.bounds.midX,
                y: topVC.view.bounds.midY,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }
        topVC.present(activityVC, animated: true)
    }
}
