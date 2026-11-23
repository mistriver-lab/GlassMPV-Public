import Combine
import Foundation
import Libmpv
import QuartzCore
import SwiftUI
import UIKit

/// 防止 MoltenVK 将 drawableSize 临时设为 1x1 引起闪烁，并保证 EDR 在主线程更新
final class MPVMetalLayer: CAMetalLayer, @unchecked Sendable {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                let layer = self
                DispatchQueue.main.sync {
                    layer.setSuperWantsEDR(newValue)
                }
            }
        }
    }

    private func setSuperWantsEDR(_ value: Bool) {
        super.wantsExtendedDynamicRangeContent = value
    }
}

final class MPVMetalContainerView: UIView {
    override class var layerClass: AnyClass { MPVMetalLayer.self }

    var metalLayer: MPVMetalLayer {
        // swiftlint:disable:next force_cast
        layer as! MPVMetalLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        metalLayer.contentsScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3.0
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fallbackScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3.0
        metalLayer.contentsScale = window?.screen.nativeScale ?? fallbackScale
    }
}

/// libmpv 播放核心控制器（支持 GLSL 超分 + 时域插值）
final class MPVPlayerController: ObservableObject, @unchecked Sendable {
    @Published @MainActor var isPaused: Bool = true
    @Published @MainActor var currentTime: Double = 0
    @Published @MainActor var duration: Double = 0
    @Published @MainActor var sourceFPS: Double = 0
    @Published @MainActor var outputFPS: Double = 0
    @Published @MainActor var videoWidth: Int = 0
    @Published @MainActor var videoHeight: Int = 0
    @Published @MainActor var activeShaderCount: Int = 0
    @Published @MainActor var statusMessage: String = ""

    private var mpv: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "com.glassmpv.mpv.events", qos: .userInitiated)
    private let stateLock = NSLock()

    private var pendingURL: URL?
    private var currentPreset: ShaderPreset = .off
    private var currentExtras: Set<String> = []
    private var currentInterpolation: InterpolationMode = .mpvSmooth120Hz

    @MainActor
    func attach(to metalLayer: MPVMetalLayer) {
        stateLock.lock()
        let alreadyInitialized = (mpv != nil)
        stateLock.unlock()
        guard !alreadyInitialized else { return }

        guard let handle = mpv_create() else {
            statusMessage = "mpv_create 初始化失败"
            return
        }

        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque()))
        checkError(mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid))

        // Apple Metal / MoltenVK 管线配置
        checkError(mpv_set_option_string(handle, "vo", "gpu-next"))
        checkError(mpv_set_option_string(handle, "gpu-api", "vulkan"))
        checkError(mpv_set_option_string(handle, "gpu-context", "moltenvk"))
        checkError(mpv_set_option_string(handle, "hwdec", "videotoolbox"))
        checkError(mpv_set_option_string(handle, "keep-open", "yes"))
        checkError(mpv_set_option_string(handle, "osc", "no"))
        checkError(mpv_set_option_string(handle, "osd-level", "0"))
        checkError(mpv_set_option_string(handle, "loop-playlist", "inf"))
        checkError(mpv_set_option_string(handle, "slang", "chs,sc,zh,zho,chi,cht,tc"))
        checkError(mpv_set_option_string(handle, "subs-fallback", "yes"))
        checkError(mpv_set_option_string(handle, "demuxer-max-bytes", "150MiB"))

        checkError(mpv_initialize(handle))

        mpv_observe_property(handle, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "container-fps", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "estimated-vf-fps", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "video-params/w", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 0, "video-params/h", MPV_FORMAT_INT64)

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        mpv_set_wakeup_callback(handle, { ctx in
            guard let ctx else { return }
            let controller = Unmanaged<MPVPlayerController>.fromOpaque(ctx).takeUnretainedValue()
            controller.readEvents()
        }, context)

        stateLock.lock()
        self.mpv = handle
        let queuedURL = self.pendingURL
        self.pendingURL = nil
        stateLock.unlock()

        applyInterpolation(currentInterpolation)
        applyShaders(preset: currentPreset, extras: currentExtras)

        if let queuedURL {
            load(url: queuedURL)
        }
    }

    func load(url: URL) {
        stateLock.lock()
        guard let handle = mpv else {
            pendingURL = url
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        let target = url.isFileURL ? url.path : url.absoluteString
        command(handle: handle, "loadfile", args: [target, "replace"])
        setFlag(handle: handle, name: "pause", value: false)
    }

    func togglePlayPause() {
        stateLock.lock()
        guard let handle = mpv else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        let paused = getFlag(handle: handle, name: "pause")
        setFlag(handle: handle, name: "pause", value: !paused)
    }

    func pause() {
        stateLock.lock()
        guard let handle = mpv else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        setFlag(handle: handle, name: "pause", value: true)
    }

    func seek(to seconds: Double) {
        stateLock.lock()
        guard let handle = mpv else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        command(handle: handle, "seek", args: [String(format: "%.3f", seconds), "absolute"])
    }

    func seekRelative(_ delta: Double) {
        stateLock.lock()
        guard let handle = mpv else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        command(handle: handle, "seek", args: [String(format: "%.3f", delta), "relative"])
    }

    func setSpeed(_ speed: Double) {
        stateLock.lock()
        guard let handle = mpv else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        mpv_set_property_string(handle, "speed", String(format: "%.2f", speed))
    }

    func applyShaders(preset: ShaderPreset, extras: Set<String>) {
        currentPreset = preset
        currentExtras = extras

        let paths = SingleShaderOption.resolvedShaderPaths(preset: preset, extras: extras)
        let count = paths.count
        Task { @MainActor [weak self] in
            self?.activeShaderCount = count
        }

        stateLock.lock()
        guard let handle = mpv else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        if paths.isEmpty {
            command(handle: handle, "change-list", args: ["glsl-shaders", "clr", ""])
        } else {
            // Unix / iOS 下 mpv 使用冒号分隔多个着色器路径
            let joined = paths.joined(separator: ":")
            command(handle: handle, "change-list", args: ["glsl-shaders", "set", joined])
        }
    }

    func applyInterpolation(_ mode: InterpolationMode) {
        currentInterpolation = mode

        stateLock.lock()
        guard let handle = mpv else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        switch mode {
        case .mpvSmooth120Hz:
            mpv_set_property_string(handle, "video-sync", "display-resample")
            mpv_set_property_string(handle, "interpolation", "yes")
            mpv_set_property_string(handle, "tscale", "oversample")
        case .off, .vtOpticalFlow2x:
            mpv_set_property_string(handle, "interpolation", "no")
            mpv_set_property_string(handle, "video-sync", "audio")
        }
    }

    func shutdown() {
        stateLock.lock()
        guard let handle = mpv else {
            stateLock.unlock()
            return
        }
        mpv = nil
        stateLock.unlock()

        mpv_set_wakeup_callback(handle, nil, nil)
        mpv_terminate_destroy(handle)
    }

    deinit {
        shutdown()
    }

    // MARK: - Private libmpv helpers

    private func readEvents() {
        eventQueue.async { [weak self] in
            guard let self else { return }
            while true {
                self.stateLock.lock()
                guard let handle = self.mpv else {
                    self.stateLock.unlock()
                    return
                }
                let eventPtr = mpv_wait_event(handle, 0)
                self.stateLock.unlock()

                guard let event = eventPtr?.pointee else { return }
                if event.event_id == MPV_EVENT_NONE {
                    break
                }

                switch event.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    if let prop = UnsafePointer<mpv_event_property>(OpaquePointer(event.data))?.pointee,
                       let cName = prop.name {
                        let name = String(cString: cName)
                        handlePropertyChange(name: name, property: prop)
                    }
                case MPV_EVENT_SHUTDOWN:
                    shutdown()
                    return
                default:
                    break
                }
            }
        }
    }

    private func handlePropertyChange(name: String, property: mpv_event_property) {
        switch name {
        case "time-pos":
            if property.format == MPV_FORMAT_DOUBLE,
               let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
                Task { @MainActor [weak self] in self?.currentTime = value }
            }
        case "duration":
            if property.format == MPV_FORMAT_DOUBLE,
               let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
                Task { @MainActor [weak self] in self?.duration = value }
            }
        case "pause":
            if property.format == MPV_FORMAT_FLAG,
               let flag = UnsafePointer<Int32>(OpaquePointer(property.data))?.pointee {
                let paused = (flag != 0)
                Task { @MainActor [weak self] in self?.isPaused = paused }
            }
        case "container-fps":
            if property.format == MPV_FORMAT_DOUBLE,
               let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
                Task { @MainActor [weak self] in self?.sourceFPS = value }
            }
        case "estimated-vf-fps":
            if property.format == MPV_FORMAT_DOUBLE,
               let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
                Task { @MainActor [weak self] in self?.outputFPS = value }
            }
        case "video-params/w":
            if property.format == MPV_FORMAT_INT64,
               let value = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee {
                let width = Int(value)
                Task { @MainActor [weak self] in self?.videoWidth = width }
            }
        case "video-params/h":
            if property.format == MPV_FORMAT_INT64,
               let value = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee {
                let height = Int(value)
                Task { @MainActor [weak self] in self?.videoHeight = height }
            }
        default:
            break
        }
    }

    private func command(handle: OpaquePointer, _ cmd: String, args: [String]) {
        let allArgs: [String?] = [cmd] + args + [nil]
        let cStrings: [UnsafeMutablePointer<CChar>?] = allArgs.map { item in
            item.map { strdup($0) } ?? nil
        }
        defer {
            for ptr in cStrings where ptr != nil {
                free(ptr)
            }
        }
        var constArgs = cStrings.map { UnsafePointer($0) }
        checkError(mpv_command(handle, &constArgs))
    }

    private func getFlag(handle: OpaquePointer, name: String) -> Bool {
        var data: Int32 = 0
        mpv_get_property(handle, name, MPV_FORMAT_FLAG, &data)
        return data != 0
    }

    private func setFlag(handle: OpaquePointer, name: String, value: Bool) {
        var data: Int32 = value ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &data)
    }

    private func checkError(_ status: CInt) {
        if status < 0 {
            let msg = String(cString: mpv_error_string(status))
            Task { @MainActor [weak self] in
                self?.statusMessage = "mpv: \(msg)"
            }
        }
    }
}

/// SwiftUI 桥接渲染视图
struct MPVVideoSurface: UIViewRepresentable {
    let controller: MPVPlayerController

    func makeUIView(context: Context) -> MPVMetalContainerView {
        let view = MPVMetalContainerView(frame: .zero)
        controller.attach(to: view.metalLayer)
        return view
    }

    func updateUIView(_ uiView: MPVMetalContainerView, context: Context) {}
}
