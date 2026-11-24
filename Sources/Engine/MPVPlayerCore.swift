import AVFoundation
import Combine
import Darwin
import Foundation
import Libmpv
import QuartzCore
import SwiftUI
import UIKit

private struct UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
}

private func mpvWakeupCallback(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    let controller = Unmanaged<MPVPlayerController>.fromOpaque(ctx).takeUnretainedValue()
    controller.readEvents()
}

/// 防止 MoltenVK 将 drawableSize 临时设为 1x1 引起闪烁，并避免非主线程同步切主线程造成死锁
final class MPVMetalLayer: CAMetalLayer {
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
                let box = UnsafeSendableBox(value: self)
                DispatchQueue.main.async {
                    box.value.setSuperWantsEDR(newValue)
                }
            }
        }
    }

    private func setSuperWantsEDR(_ value: Bool) {
        super.wantsExtendedDynamicRangeContent = value
    }
}

/// 对齐 MPVKit 官方 iOS 示例：使用独立 addSublayer 宿主 MPVMetalLayer，而非覆盖 layerClass
final class MPVMetalContainerView: UIView {
    let metalLayer = MPVMetalLayer()
    var onLayerReady: (@MainActor (MPVMetalLayer) -> Void)?
    private var didNotifyReady = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        let initialScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3.0
        metalLayer.contentsScale = initialScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(metalLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fallbackScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3.0
        let scale = window?.screen.nativeScale ?? fallbackScale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        metalLayer.contentsScale = scale
        if bounds.width > 1, bounds.height > 1 {
            metalLayer.drawableSize = CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )
        }
        CATransaction.commit()

        if !didNotifyReady, window != nil, bounds.width > 1, bounds.height > 1 {
            didNotifyReady = true
            onLayerReady?(metalLayer)
        }
    }
}

/// libmpv 播放核心控制器（支持 GLSL 超分 + 时域插值 + 端内诊断与无头测试模式）
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
    @Published @MainActor var playbackState: String = "待机"
    @Published @MainActor var lastErrorMessage: String?
    @Published @MainActor var diagnosticLogs: [String] = []
    @Published @MainActor var isInitialized: Bool = false

    @MainActor
    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var mpv: OpaquePointer?
    private var attachedLayer: MPVMetalLayer?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private let eventQueue = DispatchQueue(label: "com.glassmpv.mpv.events", qos: .userInitiated)
    private let eventQueueKey = DispatchSpecificKey<Bool>()
    private let stateLock = NSLock()

    private var pendingURL: URL?
    private var currentPreset: ShaderPreset = .off
    private var currentExtras: Set<String> = []
    private var currentInterpolation: InterpolationMode = .off
    private var currentSpeed: Double = 1.0
    private var isHeadlessMode: Bool = false

    init() {
        eventQueue.setSpecific(key: eventQueueKey, value: true)
    }

    @MainActor
    func attach(to metalLayer: MPVMetalLayer) {
        stateLock.lock()
        let alreadyInitialized = (mpv != nil)
        let sameLayer = (!isHeadlessMode && attachedLayer === metalLayer)
        stateLock.unlock()
        if alreadyInitialized {
            if sameLayer { return }
            shutdown()
        }

        configureAndInitialize(metalLayer: metalLayer, headless: false)
    }

    /// 供 XCTest 在无窗口 iOS Simulator 中运行真实解码与播放验证
    @MainActor
    func attachHeadlessForTesting() {
        stateLock.lock()
        let alreadyInitialized = (mpv != nil && isHeadlessMode)
        stateLock.unlock()
        if alreadyInitialized { return }
        if mpv != nil {
            shutdown()
        }
        configureAndInitialize(metalLayer: nil, headless: true)
    }

    @MainActor
    private func configureAndInitialize(metalLayer: MPVMetalLayer?, headless: Bool) {
        _ = setlocale(LC_NUMERIC, "C")
        if !headless {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }

        lastErrorMessage = nil
        playbackState = "正在初始化 MPV..."
        appendLog(headless ? "[init] 启动 Headless 测试模式" : "[init] 绑定 MPVMetalLayer(\(Int(metalLayer?.bounds.width ?? 0))x\(Int(metalLayer?.bounds.height ?? 0)))")

        guard let handle = mpv_create() else {
            let msg = "mpv_create 初始化失败"
            statusMessage = msg
            lastErrorMessage = msg
            playbackState = "初始化失败"
            appendLog("[error] \(msg)")
            return
        }

        mpv_request_log_messages(handle, "warn")

        if headless {
            checkError(mpv_set_option_string(handle, "vo", "null"))
            checkError(mpv_set_option_string(handle, "ao", "null"))
            checkError(mpv_set_option_string(handle, "hwdec", "no"))
            checkError(mpv_set_option_string(handle, "keep-open", "yes"))
            checkError(mpv_set_option_string(handle, "loop-playlist", "no"))
        } else if let metalLayer {
            attachedLayer = metalLayer
            var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque()))
            checkError(mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid))

            // Apple Metal / MoltenVK 管线配置（auto-safe 支持硬解失败安全回退软解）
            checkError(mpv_set_option_string(handle, "vo", "gpu-next"))
            checkError(mpv_set_option_string(handle, "gpu-api", "vulkan"))
            checkError(mpv_set_option_string(handle, "gpu-context", "moltenvk"))
            checkError(mpv_set_option_string(handle, "hwdec", "auto-safe"))
            checkError(mpv_set_option_string(handle, "keep-open", "yes"))
            checkError(mpv_set_option_string(handle, "osc", "no"))
            checkError(mpv_set_option_string(handle, "osd-level", "0"))
            checkError(mpv_set_option_string(handle, "loop-playlist", "inf"))
            checkError(mpv_set_option_string(handle, "slang", "chs,sc,zh,zho,chi,cht,tc"))
            checkError(mpv_set_option_string(handle, "subs-fallback", "yes"))
            checkError(mpv_set_option_string(handle, "demuxer-max-bytes", "150MiB"))
        }

        let initStatus = mpv_initialize(handle)
        if initStatus < 0 {
            checkError(initStatus)
            let errText = String(cString: mpv_error_string(initStatus))
            lastErrorMessage = "mpv_initialize 失败：\(errText)"
            playbackState = "初始化失败"
            appendLog("[fatal] mpv_initialize failed (\(initStatus)): \(errText)")
            mpv_terminate_destroy(handle)
            attachedLayer = nil
            return
        }

        mpv_observe_property(handle, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "container-fps", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "estimated-vf-fps", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "video-params/w", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 0, "video-params/h", MPV_FORMAT_INT64)

        var observers: [NSObjectProtocol] = []
        if !headless {
            let bgObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.pause()
                self.setVideoTrackProperty("no")
            }

            let fgObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.setVideoTrackProperty("auto")
            }
            observers = [bgObserver, fgObserver]
        }

        stateLock.lock()
        self.mpv = handle
        self.isHeadlessMode = headless
        self.lifecycleObservers = observers
        let queuedURL = self.pendingURL
        self.pendingURL = nil
        stateLock.unlock()

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        mpv_set_wakeup_callback(handle, mpvWakeupCallback, context)

        isInitialized = true
        playbackState = "内核就绪"
        appendLog("[init] mpv_initialize 成功")

        if !headless {
            applyInterpolation(currentInterpolation)
            applyShaders(preset: currentPreset, extras: currentExtras)
        }
        if abs(currentSpeed - 1.0) > 0.001 {
            setSpeed(currentSpeed)
        }

        if let queuedURL {
            load(url: queuedURL)
        }
    }

    func load(url: URL) {
        let target = url.isFileURL ? url.path : url.absoluteString
        appendLog("[load] 请求播放: \(target)")

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.lastErrorMessage = nil
            self.currentTime = 0
            self.duration = 0
            self.videoWidth = 0
            self.videoHeight = 0
            self.playbackState = "正在加载媒体..."
        }

        stateLock.lock()
        guard let handle = mpv else {
            pendingURL = url
            stateLock.unlock()
            appendLog("[load] 内核尚未就绪，已入队等待图层挂载")
            return
        }
        stateLock.unlock()

        commandAsync(handle: handle, "loadfile", args: [target, "replace"])
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
        commandAsync(handle: handle, "seek", args: [String(format: "%.3f", seconds), "absolute"])
    }

    func seekRelative(_ delta: Double) {
        stateLock.lock()
        guard let handle = mpv else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        commandAsync(handle: handle, "seek", args: [String(format: "%.3f", delta), "relative"])
    }

    func setSpeed(_ speed: Double) {
        currentSpeed = speed
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
            commandAsync(handle: handle, "change-list", args: ["glsl-shaders", "clr", ""])
            appendLog("[shader] 已清空着色器（原画直出）")
        } else {
            // Unix / iOS 下 mpv 使用冒号分隔多个着色器路径
            let joined = paths.joined(separator: ":")
            commandAsync(handle: handle, "change-list", args: ["glsl-shaders", "set", joined])
            appendLog("[shader] 应用 \(count) 个 GLSL 着色器 (\(preset.title))")
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
            appendLog("[interp] 开启 120Hz 时域平滑 (display-resample)")
        case .off, .vtOpticalFlow2x:
            mpv_set_property_string(handle, "interpolation", "no")
            mpv_set_property_string(handle, "video-sync", "audio")
            appendLog("[interp] 关闭时域插值 (video-sync=audio)")
        }
    }

    @MainActor
    func clearError() {
        lastErrorMessage = nil
    }

    @MainActor
    func recordExternalError(_ message: String) {
        lastErrorMessage = message
        statusMessage = message
        playbackState = "打开失败"
        appendLog("[error] \(message)")
    }

    func appendLog(_ line: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let stamp = Self.logTimeFormatter.string(from: Date())
            self.diagnosticLogs.append("[\(stamp)] \(line)")
            if self.diagnosticLogs.count > 100 {
                self.diagnosticLogs.removeFirst(self.diagnosticLogs.count - 100)
            }
        }
    }

    func shutdown() {
        shutdownCore(fromDeinit: false)
    }

    private func shutdownCore(fromDeinit: Bool) {
        stateLock.lock()
        let observers = lifecycleObservers
        lifecycleObservers.removeAll()
        guard let handle = mpv else {
            attachedLayer = nil
            isHeadlessMode = false
            stateLock.unlock()
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            if !fromDeinit {
                updateShutdownUIState(playbackState: "待机")
            }
            return
        }
        mpv = nil
        attachedLayer = nil
        isHeadlessMode = false
        stateLock.unlock()

        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        mpv_set_wakeup_callback(handle, nil, nil)
        if DispatchQueue.getSpecific(key: eventQueueKey) != true {
            eventQueue.sync {}
        }
        mpv_terminate_destroy(handle)

        if !fromDeinit {
            updateShutdownUIState(playbackState: "已停止")
        }
    }

    private func updateShutdownUIState(playbackState: String) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.isInitialized = false
                self.playbackState = playbackState
            }
        } else {
            Task { @MainActor [weak self] in
                self?.isInitialized = false
                self?.playbackState = playbackState
            }
        }
    }

    private func setVideoTrackProperty(_ value: String) {
        stateLock.lock()
        guard let handle = mpv else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        checkError(mpv_set_property_string(handle, "vid", value))
    }

    deinit {
        shutdownCore(fromDeinit: true)
    }

    // MARK: - Private libmpv helpers

    fileprivate func readEvents() {
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
                case MPV_EVENT_START_FILE:
                    Task { @MainActor [weak self] in
                        self?.playbackState = "正在打开媒体..."
                        self?.lastErrorMessage = nil
                    }
                    appendLog("[event] START_FILE")

                case MPV_EVENT_FILE_LOADED:
                    Task { @MainActor [weak self] in
                        self?.playbackState = "已加载，开始解码..."
                    }
                    appendLog("[event] FILE_LOADED")

                case MPV_EVENT_PLAYBACK_RESTART:
                    Task { @MainActor [weak self] in
                        self?.playbackState = "播放中"
                    }
                    appendLog("[event] PLAYBACK_RESTART")

                case MPV_EVENT_VIDEO_RECONFIG:
                    appendLog("[event] VIDEO_RECONFIG")

                case MPV_EVENT_END_FILE:
                    if let endFile = UnsafePointer<mpv_event_end_file>(OpaquePointer(event.data))?.pointee {
                        if endFile.reason == MPV_END_FILE_REASON_ERROR {
                            let errStr = String(cString: mpv_error_string(endFile.error))
                            let message = "播放失败：\(errStr) (\(endFile.error))"
                            Task { @MainActor [weak self] in
                                self?.lastErrorMessage = message
                                self?.statusMessage = message
                                self?.playbackState = "播放失败"
                            }
                            appendLog("[error] END_FILE error: \(errStr) (\(endFile.error))")
                        } else if endFile.reason == MPV_END_FILE_REASON_EOF {
                            Task { @MainActor [weak self] in
                                self?.playbackState = "播放结束"
                            }
                            appendLog("[event] END_FILE (EOF)")
                        } else {
                            appendLog("[event] END_FILE reason=\(endFile.reason.rawValue)")
                        }
                    }

                case MPV_EVENT_LOG_MESSAGE:
                    if let logMsg = UnsafePointer<mpv_event_log_message>(OpaquePointer(event.data))?.pointee {
                        let prefix = logMsg.prefix.map { String(cString: $0) } ?? "mpv"
                        let level = logMsg.level.map { String(cString: $0) } ?? "info"
                        let rawText = logMsg.text.map { String(cString: $0) } ?? ""
                        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            appendLog("[\(level)][\(prefix)] \(text)")
                        }
                    }

                case MPV_EVENT_PROPERTY_CHANGE:
                    if let prop = UnsafePointer<mpv_event_property>(OpaquePointer(event.data))?.pointee,
                       let cName = prop.name {
                        let name = String(cString: cName)
                        handlePropertyChange(name: name, property: prop)
                    }

                case MPV_EVENT_SHUTDOWN:
                    appendLog("[event] SHUTDOWN")
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

    private func commandAsync(handle: OpaquePointer, _ cmd: String, args: [String]) {
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
        checkError(mpv_command_async(handle, 0, &constArgs))
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
            appendLog("[warn] mpv error (\(status)): \(msg)")
        }
    }
}

/// SwiftUI 桥接渲染视图
struct MPVVideoSurface: UIViewRepresentable {
    let controller: MPVPlayerController

    func makeUIView(context: Context) -> MPVMetalContainerView {
        let view = MPVMetalContainerView(frame: .zero)
        view.onLayerReady = { [controller] layer in
            controller.attach(to: layer)
        }
        return view
    }

    func updateUIView(_ uiView: MPVMetalContainerView, context: Context) {}

    static func dismantleUIView(_ uiView: MPVMetalContainerView, coordinator: ()) {
        uiView.onLayerReady = nil
    }
}
