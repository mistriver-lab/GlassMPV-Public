import UIKit
import UniformTypeIdentifiers

/// 原生 UIKit 文件选择器调度器：绕开 SwiftUI `.fileImporter` 在 iOS 26+ Liquid Glass / 多层级弹窗下偶发点击无响应的问题
@MainActor
final class NativeDocumentPickerPresenter: NSObject, UIDocumentPickerDelegate {
    static let shared = NativeDocumentPickerPresenter()

    static let supportedContentTypes: [UTType] = [
        .movie,
        .video,
        .mpeg4Movie,
        .quickTimeMovie,
        .item
    ]

    static let supportedSubtitleTypes: [UTType] = [
        .plainText,
        .text,
        .data,
        .item
    ]

    private var onPick: (@MainActor (URL) -> Void)?
    private var onCancel: (@MainActor () -> Void)?
    private var onError: (@MainActor (String) -> Void)?

    private override init() {
        super.init()
    }

    static func makePicker(contentTypes: [UTType] = supportedContentTypes) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: true
        )
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.modalPresentationStyle = .formSheet
        return picker
    }

    func present(
        onPick: @escaping @MainActor (URL) -> Void,
        onCancel: (@MainActor () -> Void)? = nil,
        onError: (@MainActor (String) -> Void)? = nil
    ) {
        presentPicker(
            contentTypes: Self.supportedContentTypes,
            onPick: onPick,
            onCancel: onCancel,
            onError: onError
        )
    }

    func presentSubtitlePicker(
        onPick: @escaping @MainActor (URL) -> Void,
        onCancel: (@MainActor () -> Void)? = nil,
        onError: (@MainActor (String) -> Void)? = nil
    ) {
        presentPicker(
            contentTypes: Self.supportedSubtitleTypes,
            onPick: onPick,
            onCancel: onCancel,
            onError: onError
        )
    }

    private func presentPicker(
        contentTypes: [UTType],
        onPick: @escaping @MainActor (URL) -> Void,
        onCancel: (@MainActor () -> Void)?,
        onError: (@MainActor (String) -> Void)?
    ) {
        guard let topVC = Self.topmostViewController() else {
            onError?("无法获取当前窗口控制器，请重试。")
            return
        }
        if topVC is UIDocumentPickerViewController {
            return
        }

        self.onPick = onPick
        self.onCancel = onCancel
        self.onError = onError

        let picker = Self.makePicker(contentTypes: contentTypes)
        picker.delegate = self
        topVC.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let callbacks = takeCallbacks()
        if let first = urls.first {
            callbacks.onPick?(first)
        } else {
            callbacks.onError?("未获取到所选视频文件路径。")
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let callbacks = takeCallbacks()
        callbacks.onCancel?()
    }

    private func takeCallbacks() -> (
        onPick: (@MainActor (URL) -> Void)?,
        onCancel: (@MainActor () -> Void)?,
        onError: (@MainActor (String) -> Void)?
    ) {
        let callbacks = (onPick, onCancel, onError)
        onPick = nil
        onCancel = nil
        onError = nil
        return callbacks
    }

    private static func topmostViewController() -> UIViewController? {
        let windowScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let activeScene = windowScenes.first { $0.activationState == .foregroundActive }
            ?? windowScenes.first { $0.activationState == .foregroundInactive }
            ?? windowScenes.first

        guard let scene = activeScene else {
            return nil
        }
        let rootWindow = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        var current = rootWindow?.rootViewController
        while let presented = current?.presentedViewController {
            current = presented
        }
        return current
    }
}
