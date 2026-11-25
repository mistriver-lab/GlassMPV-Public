import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private final class ThermalObserverToken: @unchecked Sendable {
    var observer: NSObjectProtocol?

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

@MainActor
final class PlayerCoordinator: ObservableObject {
    @Published var engineMode: PlayerEngineMode = .mpv
    @Published var selectedPreset: ShaderPreset = .off // 保守默认原画直出，确保首次 100% 起播后再按需开启超分
    @Published var selectedExtras: Set<String> = []
    @Published var interpolationMode: InterpolationMode = .off
    @Published var vtSpatial2x: Bool = false
    @Published var speed: Double = 1.0
    @Published var currentURL: URL?
    @Published var isGeneratingSample: Bool = false
    @Published var isImportingFile: Bool = false
    @Published var selfCheckReport: String = ""
    @Published var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    let mpvController = MPVPlayerController()
    let opticalFlowController = OpticalFlowPlayerController()
    private let thermalToken = ThermalObserverToken()

    init() {
        thermalToken.observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let current = ProcessInfo.processInfo.thermalState
            Task { @MainActor [weak self] in
                self?.thermalState = current
            }
        }
    }

    var activeVideoWidth: Int {
        engineMode == .mpv ? mpvController.videoWidth : opticalFlowController.videoWidth
    }

    var activeVideoHeight: Int {
        engineMode == .mpv ? mpvController.videoHeight : opticalFlowController.videoHeight
    }

    var isSuperResolutionDisabledBy4K: Bool {
        SuperResolutionPolicy.isAlready4K(width: activeVideoWidth, height: activeVideoHeight)
    }

    var superResolutionDisabledReason: String? {
        SuperResolutionPolicy.disabledReason(width: activeVideoWidth, height: activeVideoHeight)
    }

    var hudMetrics: PlaybackHUDMetrics {
        let thermal = ThermalLevel(state: thermalState)
        if engineMode == .mpv {
            let honestDisplayFPS = mpvController.displaySyncFPS > 0
                ? mpvController.displaySyncFPS
                : mpvController.measuredProMotionFPS
            return PlaybackHUDMetrics(
                engineBadge: "MPV",
                interpolationBadge: interpolationMode.shortBadge,
                codec: mpvController.videoCodec,
                width: mpvController.videoWidth,
                height: mpvController.videoHeight,
                sourceFPS: mpvController.sourceFPS,
                outputFPS: mpvController.outputFPS,
                displayFPS: honestDisplayFPS,
                bitDepth: mpvController.bitDepthLabel,
                hdrTag: mpvController.hdrLabel,
                isHDRActive: mpvController.isHDRActive,
                decoderBadge: PlaybackHUDMetrics.formatDecoderBadge(hardwareDecoder: mpvController.hardwareDecoder),
                droppedFrames: mpvController.droppedFrames,
                activeShaderCount: mpvController.activeShaderCount,
                thermalLevel: thermal
            )
        } else {
            let interpBadge = opticalFlowController.enableSpatial2xUpscale ? "光流2x+超分2x" : interpolationMode.shortBadge
            return PlaybackHUDMetrics(
                engineBadge: "ANE",
                interpolationBadge: interpBadge,
                codec: opticalFlowController.videoCodec,
                width: opticalFlowController.videoWidth,
                height: opticalFlowController.videoHeight,
                sourceFPS: opticalFlowController.sourceFPS,
                outputFPS: opticalFlowController.actualOutputFPS,
                displayFPS: 0,
                bitDepth: opticalFlowController.bitDepthLabel,
                hdrTag: opticalFlowController.hdrLabel,
                isHDRActive: opticalFlowController.isHDRActive,
                decoderBadge: "硬解 VT+ANE",
                droppedFrames: opticalFlowController.droppedFrames,
                activeShaderCount: 0,
                thermalLevel: thermal
            )
        }
    }

    func presentLocalVideoPicker() {
        mpvController.clearError()
        mpvController.appendLog("[file] 正在拉起系统原生文件选择器 (UIDocumentPickerViewController, asCopy=true)...")
        NativeDocumentPickerPresenter.shared.present(
            onPick: { [weak self] url in
                self?.open(url: url, isSecurityScoped: false)
            },
            onCancel: { [weak self] in
                self?.mpvController.appendLog("[file] 用户取消了本地文件选择")
            },
            onError: { [weak self] message in
                self?.mpvController.recordExternalError("无法打开本地文件选择器：\(message)")
            }
        )
    }

    func open(url: URL, isSecurityScoped: Bool = false) {
        mpvController.clearError()

        if !url.isFileURL {
            beginPlayback(url: url)
            return
        }

        isImportingFile = true
        mpvController.appendLog("[file] 正在异步准备本地视频: \(url.lastPathComponent)")

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let playableURL = try await LocalMediaImporter.preparePlayableLocalURL(
                    from: url,
                    isSecurityScoped: isSecurityScoped
                )
                self.isImportingFile = false
                self.mpvController.appendLog("[file] 本地视频已就绪: \(playableURL.lastPathComponent)")
                self.beginPlayback(url: playableURL)
            } catch {
                self.isImportingFile = false
                self.mpvController.recordExternalError("无法读取本地视频（\(url.lastPathComponent)）：\(error.localizedDescription)")
            }
        }
    }

    func importFromPhotosItem(_ item: PhotosPickerItem) {
        guard !isImportingFile else { return }
        isImportingFile = true
        mpvController.clearError()
        mpvController.appendLog("[photos] 开始从系统相册导入视频...")

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let movie = try await item.loadTransferable(type: MovieFileTransferable.self) else {
                    self.isImportingFile = false
                    self.mpvController.recordExternalError("未能从系统相册读取该视频（请确认 iCloud 原片已下载到本地）。")
                    return
                }
                self.isImportingFile = false
                self.mpvController.appendLog("[photos] 相册视频已拷贝至沙盒: \(movie.url.lastPathComponent)")
                self.beginPlayback(url: movie.url)
            } catch {
                self.isImportingFile = false
                self.mpvController.recordExternalError("相册视频导入失败：\(error.localizedDescription)")
            }
        }
    }

    func closeToHome() {
        mpvController.stopPlayback()
        opticalFlowController.stop()
        currentURL = nil
        isImportingFile = false
        isGeneratingSample = false
        OrientationController.shared.returnToHomeOrientation()
    }

    private func beginPlayback(url: URL) {
        let enteringFromHome = (currentURL == nil)
        currentURL = url
        if enteringFromHome {
            OrientationController.shared.enterVideoLandscape()
        }
        startPlaybackForCurrentEngine()
    }

    func playBuiltInSampleVideo() {
        guard !isGeneratingSample else { return }
        isGeneratingSample = true
        mpvController.clearError()
        mpvController.appendLog("[sample] 开始生成内置 3 秒自测视频...")

        Task { [weak self] in
            guard let self else { return }
            do {
                let sampleURL = try await TestVideoGenerator.generateSampleMP4()
                self.isGeneratingSample = false
                self.open(url: sampleURL, isSecurityScoped: false)
            } catch {
                self.isGeneratingSample = false
                self.mpvController.recordExternalError("内置测试视频生成失败：\(error.localizedDescription)")
            }
        }
    }

    func retryWithoutShaders() {
        selectedPreset = .off
        selectedExtras = []
        interpolationMode = .off
        mpvController.clearError()
        mpvController.applyShaders(preset: .off, extras: [])
        mpvController.applyInterpolation(.off)
        if currentURL != nil {
            startPlaybackForCurrentEngine()
        }
    }

    func runRealDeviceSelfCheck() {
        mpvController.refreshDiagnosticsSnapshot()

        let maxScreenFPS = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.maximumFramesPerSecond ?? 60

        let shaderCount: Int = {
            guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Shaders", isDirectory: true),
                  let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                return 0
            }
            return items.filter { $0.pathExtension.lowercased() == "glsl" }.count
        }()

        let resolvedShaderCount = SingleShaderOption.resolvedShaderPaths(
            preset: selectedPreset,
            extras: selectedExtras
        ).count

        let importCheck: String = {
            do {
                try FileManager.default.createDirectory(
                    at: LocalMediaImporter.importsDirectory,
                    withIntermediateDirectories: true
                )
                let currentReadable = currentURL.map {
                    $0.isFileURL ? FileManager.default.isReadableFile(atPath: $0.path(percentEncoded: false)) : true
                } ?? true
                return "PASS (沙盒导入目录可写, 当前片源可读=\(currentReadable))"
            } catch {
                return "FAIL (\(error.localizedDescription))"
            }
        }()

        let mpvDisplayText = mpvController.displaySyncFPS > 0
            ? String(format: "%.1fHz", mpvController.displaySyncFPS)
            : "未上报"
        let proMotionText = mpvController.isProMotionKeeperActive
            ? "保活中(\(String(format: "%.1f", mpvController.measuredProMotionFPS))Hz)"
            : "未保活"

        let mpvStatus = mpvController.isInitialized
            ? "就绪 | state=\(mpvController.playbackState) | \(mpvController.videoWidth)x\(mpvController.videoHeight) | codec=\(mpvController.videoCodec.isEmpty ? "-" : mpvController.videoCodec) | hwdec=\(mpvController.hardwareDecoder.isEmpty ? "-" : mpvController.hardwareDecoder) | fps=\(String(format: "%.1f", mpvController.sourceFPS))/\(String(format: "%.1f", mpvController.outputFPS)) | targetSync=\(String(format: "%.0f", mpvController.targetDisplaySyncFPS))Hz | mpvDisplay=\(mpvDisplayText) | proMotion=\(proMotionText) | pass(fresh/redraw)=\(mpvController.freshRenderPassCount)/\(mpvController.redrawRenderPassCount) | mistimed=\(mpvController.mistimedFrames) | delayed=\(mpvController.delayedFrames) | err=\(mpvController.lastErrorMessage ?? "none")"
            : "未初始化"

        let opticalStatus = "\(opticalFlowController.capabilityDescription) | 时钟=\(opticalFlowController.clockSourceLabel) | 补帧=\(opticalFlowController.interpolatedFrameCount) | 跳帧追赶=\(opticalFlowController.skippedInterpolationCount) | 失败=\(opticalFlowController.failedInterpolationCount) | 送显=\(opticalFlowController.presentedFrameCount) | 平均耗时=\(String(format: "%.1f", opticalFlowController.averageInterpolationMs))ms | 实测FPS=\(String(format: "%.1f", opticalFlowController.actualOutputFPS)) | err=\(opticalFlowController.errorMessage ?? opticalFlowController.lastInterpolationError ?? "none")"

        let gateStatus = isSuperResolutionDisabledBy4K ? "已触发4K禁超分" : "允许超分"
        let lines = [
            "=== GlassMPV 真机 5 项体检报告 ===",
            "版本: \(AppReleaseInfo.displayVersion) | 当前引擎: \(engineMode.rawValue) | 4K超分门控: \(gateStatus)",
            "1. 屏幕 ProMotion 上限: \(maxScreenFPS) Hz \(maxScreenFPS >= 120 ? "(PASS)" : "(非120Hz)")",
            "2. GLSL 着色器包校验: \(shaderCount)/58 个 (\(shaderCount == 58 ? "PASS" : "FAIL")), 当前激活=\(resolvedShaderCount) 个",
            "3. 本地/相册导入沙盒通道: \(importCheck)",
            "4. MPVUI 播放内核: \(mpvStatus)",
            "5. ANE 光流真补帧核: \(opticalStatus)"
        ]
        selfCheckReport = lines.joined(separator: "\n")
    }

    func switchEngine(to target: PlayerEngineMode) {
        guard target != engineMode else { return }
        let resumeTime = activeCurrentTime
        mpvController.pause()
        opticalFlowController.stop()

        engineMode = target
        if target == .opticalFlow {
            interpolationMode = .vtOpticalFlow2x
        } else if interpolationMode == .vtOpticalFlow2x {
            interpolationMode = .mpvSmooth120Hz
        }

        startPlaybackForCurrentEngine(seekTo: resumeTime)
    }

    func applyPreset(_ preset: ShaderPreset) {
        if isSuperResolutionDisabledBy4K && preset.id != ShaderPreset.off.id {
            let reason = superResolutionDisabledReason ?? "片源已达 4K，自动禁用超分"
            mpvController.appendLog("[shader] \(reason)")
            return
        }
        selectedPreset = preset
        mpvController.applyShaders(preset: preset, extras: selectedExtras)
    }

    func toggleExtraShader(_ id: String) {
        if isSuperResolutionDisabledBy4K && !selectedExtras.contains(id) {
            let reason = superResolutionDisabledReason ?? "片源已达 4K，自动禁用超分"
            mpvController.appendLog("[shader] \(reason)")
            return
        }
        if selectedExtras.contains(id) {
            selectedExtras.remove(id)
        } else {
            selectedExtras.insert(id)
        }
        mpvController.applyShaders(preset: selectedPreset, extras: selectedExtras)
    }

    func setInterpolation(_ mode: InterpolationMode) {
        interpolationMode = mode
        switch mode {
        case .off, .mpvSmooth120Hz:
            if engineMode != .mpv {
                switchEngine(to: .mpv)
            } else {
                mpvController.applyInterpolation(mode)
            }
        case .vtOpticalFlow2x:
            if engineMode != .opticalFlow {
                switchEngine(to: .opticalFlow)
            }
        }
    }

    func setVTSpatial2x(_ enabled: Bool) {
        if enabled && isSuperResolutionDisabledBy4K {
            vtSpatial2x = false
            let reason = superResolutionDisabledReason ?? "片源已达 4K，自动禁用 ANE 2× 超分"
            opticalFlowController.appendLog("[ane] \(reason)")
            return
        }
        vtSpatial2x = enabled
        if engineMode == .opticalFlow, let url = currentURL {
            let t = opticalFlowController.currentTime
            opticalFlowController.load(url: url, spatial2x: enabled, startAt: t)
        }
    }

    func setSpeed(_ value: Double) {
        speed = value
        mpvController.setSpeed(value)
        opticalFlowController.setSpeed(value)
    }

    func togglePlayPause() {
        switch engineMode {
        case .mpv:
            mpvController.togglePlayPause()
        case .opticalFlow:
            opticalFlowController.togglePlayPause()
        }
    }

    func seek(to seconds: Double) {
        switch engineMode {
        case .mpv:
            mpvController.seek(to: seconds)
        case .opticalFlow:
            opticalFlowController.seek(to: seconds)
        }
    }

    func seekRelative(_ delta: Double) {
        switch engineMode {
        case .mpv:
            mpvController.seekRelative(delta)
        case .opticalFlow:
            opticalFlowController.seekRelative(delta)
        }
    }

    var activeCurrentTime: Double {
        engineMode == .mpv ? mpvController.currentTime : opticalFlowController.currentTime
    }

    var activeDuration: Double {
        engineMode == .mpv ? mpvController.duration : opticalFlowController.duration
    }

    var activePaused: Bool {
        engineMode == .mpv ? mpvController.isPaused : opticalFlowController.isPaused
    }

    private func startPlaybackForCurrentEngine(seekTo: Double = 0) {
        guard let url = currentURL else { return }
        switch engineMode {
        case .mpv:
            opticalFlowController.stop()
            mpvController.applyInterpolation(interpolationMode)
            mpvController.applyShaders(preset: selectedPreset, extras: selectedExtras)
            mpvController.load(url: url)
            mpvController.setSpeed(speed)
            if seekTo > 0.5 {
                mpvController.seek(to: seekTo)
            }
        case .opticalFlow:
            mpvController.pause()
            opticalFlowController.load(url: url, spatial2x: vtSpatial2x, startAt: seekTo)
            opticalFlowController.setSpeed(speed)
        }
    }
}

struct LiquidGlassPlayerView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject private var mpv: MPVPlayerController
    @ObservedObject private var optical: OpticalFlowPlayerController

    @State private var showHUD: Bool = true
    @State private var showStatsHUD: Bool = true
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showURLPrompt: Bool = false
    @State private var streamURLInput: String = ""
    @State private var showEnhancementSheet: Bool = false
    @State private var showChangelogSheet: Bool = false
    @State private var showDiagnosticSheet: Bool = false
    @State private var isScrubbing: Bool = false
    @State private var scrubTime: Double = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(coordinator: PlayerCoordinator) {
        self.coordinator = coordinator
        self._mpv = ObservedObject(wrappedValue: coordinator.mpvController)
        self._optical = ObservedObject(wrappedValue: coordinator.opticalFlowController)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 双核视频渲染底图（仅在打开视频后挂载，避免空状态启动触发 MoltenVK）
            if coordinator.currentURL != nil {
                Group {
                    if coordinator.engineMode == .mpv {
                        MPVVideoSurface(controller: mpv)
                    } else {
                        OpticalFlowVideoSurface(controller: optical)
                    }
                }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        showHUD.toggle()
                    }
                }
            }

            if coordinator.currentURL == nil {
                welcomeOverlay
            } else {
                if coordinator.engineMode == .mpv,
                   mpv.lastErrorMessage == nil,
                   mpv.videoWidth == 0,
                   !mpv.playbackState.isEmpty {
                    loadingStatusPill(mpv.playbackState)
                } else if coordinator.engineMode == .opticalFlow,
                          optical.errorMessage == nil,
                          (optical.isLoadingPipeline || optical.presentedFrameCount == 0) {
                    loadingStatusPill(
                        optical.pipelineStatusText.isEmpty ? "正在预热 ANE 光流缓冲..." : optical.pipelineStatusText
                    )
                }

                if showStatsHUD {
                    VStack {
                        HStack {
                            compactStatsHUD(metrics: coordinator.hudMetrics)
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, showHUD ? (horizontalSizeClass == .compact ? 106 : 64) : 12)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.22), value: showHUD)
                    .transition(.opacity)
                }

                if showHUD {
                    playerHUDOverlay
                        .transition(.opacity)
                }
            }

            if coordinator.isImportingFile {
                loadingStatusPill("正在导入视频至沙盒...")
            }

            if coordinator.engineMode == .mpv, let mpvError = mpv.lastErrorMessage {
                mpvErrorBanner(mpvError)
            } else if coordinator.engineMode == .opticalFlow, let error = optical.errorMessage {
                opticalFlowErrorBanner(error)
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            selectedPhotoItem = nil
            coordinator.importFromPhotosItem(newItem)
        }
        .alert("打开网络视频流", isPresented: $showURLPrompt) {
            TextField("https:// 或 smb:// 视频地址", text: $streamURLInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("播放") {
                let trimmed = streamURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: trimmed) {
                    coordinator.open(url: url, isSecurityScoped: false)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showEnhancementSheet) {
            EnhancementControlSheet(coordinator: coordinator)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showChangelogSheet) {
            ReleaseNotesSheet()
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showDiagnosticSheet) {
            DiagnosticLogSheet(mpv: mpv, coordinator: coordinator)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
    }

    // MARK: - Welcome Empty State

    private var welcomeOverlay: some View {
        GlassEffectContainer(spacing: 16) {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles.tv")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(.cyan)
                    Text("GlassMPV")
                        .font(.largeTitle.bold())
                    Text("Anime4K 58着色器超分 · 120Hz平滑 & ANE光流补帧")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))

                HStack(spacing: 12) {
                    Button {
                        coordinator.presentLocalVideoPicker()
                    } label: {
                        Label("打开本地视频", systemImage: "folder.badge.plus")
                            .font(.headline)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 13)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Capsule())
                    .glassEffect(.regular.tint(.cyan).interactive(), in: .capsule)

                    PhotosPicker(selection: $selectedPhotoItem, matching: .videos, photoLibrary: .shared()) {
                        Label("从相册选取", systemImage: "photo.on.rectangle.angled")
                            .font(.headline)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.indigo).interactive(), in: .capsule)
                }

                Button {
                    showURLPrompt = true
                } label: {
                    Label("网络串流", systemImage: "link")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)

                Button {
                    coordinator.playBuiltInSampleVideo()
                } label: {
                    HStack(spacing: 8) {
                        if coordinator.isGeneratingSample {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "play.circle.fill")
                        }
                        Text(coordinator.isGeneratingSample ? "正在生成内置测试视频..." : "一键自测（内置 3 秒测试视频）")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .disabled(coordinator.isGeneratingSample)
                .glassEffect(.regular.tint(.green).interactive(), in: .capsule)

                HStack(spacing: 10) {
                    Button {
                        showEnhancementSheet = true
                    } label: {
                        Label("预设：\(coordinator.selectedPreset.title)", systemImage: "wand.and.stars")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)

                    Button {
                        showDiagnosticSheet = true
                    } label: {
                        Label("诊断日志", systemImage: "stethoscope")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }

                Button {
                    showChangelogSheet = true
                } label: {
                    Label("GlassMPV \(AppReleaseInfo.displayVersion) · 更新日志", systemImage: "doc.text")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .padding()
        }
    }

    // MARK: - Liquid Glass Floating HUD

    private var playerHUDOverlay: some View {
        VStack {
            // 顶部液态玻璃状态栏（移除外层 GlassEffectContainer 避免邻近按钮融合粘黏）
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    toolbarActionButtons

                    Spacer(minLength: 6)

                    if horizontalSizeClass != .compact {
                        engineSwitcherPills
                        Spacer(minLength: 6)
                    }

                    topRightMetricsBadge
                }

                if horizontalSizeClass == .compact {
                    engineSwitcherPills
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            // 底部液态玻璃播放控制坞
            VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        Text(formatTime(displayTime))
                            .font(.caption.monospacedDigit())
                            .frame(width: 48, alignment: .leading)

                        Slider(
                            value: Binding(
                                get: { displayTime },
                                set: { newVal in
                                    isScrubbing = true
                                    scrubTime = newVal
                                }
                            ),
                            in: 0...max(coordinator.activeDuration, 1),
                            onEditingChanged: { editing in
                                if !editing {
                                    coordinator.seek(to: scrubTime)
                                    isScrubbing = false
                                }
                            }
                        )
                        .tint(.cyan)

                        Text(formatTime(coordinator.activeDuration))
                            .font(.caption.monospacedDigit())
                            .frame(width: 48, alignment: .trailing)
                    }

                    HStack(spacing: 14) {
                        Button {
                            coordinator.seekRelative(-10)
                        } label: {
                            Image(systemName: "gobackward.10")
                                .font(.title3)
                                .frame(width: 42, height: 42)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)

                        Button {
                            coordinator.togglePlayPause()
                        } label: {
                            Image(systemName: coordinator.activePaused ? "play.fill" : "pause.fill")
                                .font(.title2)
                                .frame(width: 52, height: 52)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.tint(.cyan).interactive(), in: .circle)

                        Button {
                            coordinator.seekRelative(10)
                        } label: {
                            Image(systemName: "goforward.10")
                                .font(.title3)
                                .frame(width: 42, height: 42)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)

                        Spacer()

                        Menu {
                            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                                Button("\(rate, specifier: "%.2g")x") {
                                    coordinator.setSpeed(rate)
                                }
                            }
                        } label: {
                            Text("\(coordinator.speed, specifier: "%.2g")x")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                        }
                        .glassEffect(.regular.interactive(), in: .capsule)

                        Button {
                            showEnhancementSheet = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "wand.and.stars")
                                Text(coordinator.engineMode == .mpv ? "超分/补帧" : "光流设置")
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.tint(.indigo).interactive(), in: .capsule)
                    }
                }
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 26))
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
    }

    private var toolbarActionButtons: some View {
        HStack(spacing: 10) {
            Button {
                coordinator.closeToHome()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.body.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: .circle)

            Button {
                OrientationController.shared.toggleVideoOrientation()
            } label: {
                Image(systemName: "rotate.right")
                    .font(.body.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: .circle)

            Button {
                showDiagnosticSheet = true
            } label: {
                Image(systemName: "stethoscope")
                    .font(.body.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: .circle)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showStatsHUD.toggle()
                }
            } label: {
                Image(systemName: showStatsHUD ? "info.circle.fill" : "info.circle")
                    .font(.body.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .glassEffect(
                showStatsHUD ? .regular.tint(.cyan).interactive() : .regular.interactive(),
                in: .circle
            )
        }
    }

    private var engineSwitcherPills: some View {
        HStack(spacing: 2) {
            ForEach(PlayerEngineMode.allCases) { mode in
                Button {
                    coordinator.switchEngine(to: mode)
                } label: {
                    Text(mode.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(coordinator.engineMode == mode ? .black : .white)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            coordinator.engineMode == mode ? Color.cyan.opacity(0.85) : Color.clear,
                            in: Capsule()
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
    }

    private var topRightMetricsBadge: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showStatsHUD.toggle()
            }
        } label: {
            VStack(alignment: .trailing, spacing: 2) {
                Text(activeResolutionText)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                Text("\(coordinator.interpolationMode.shortBadge) · \(activeFPSText)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func compactStatsHUD(metrics: PlaybackHUDMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(metrics.engineBadge)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        Color.cyan.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )

                Text(metrics.videoStreamSummary)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(metrics.isHDRActive ? .yellow : .white)
                    .lineLimit(1)
            }

            Text("FPS \(metrics.fpsSummary) · 丢帧 \(metrics.droppedFrames)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)

            Text(metrics.pipelineSummary)
                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)

            HStack(spacing: 5) {
                Circle()
                    .fill(thermalColor(metrics.thermalLevel))
                    .frame(width: 6, height: 6)
                Text("温度 \(metrics.thermalLevel.rawValue)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(thermalColor(metrics.thermalLevel))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.62))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
                )
        )
    }

    private func thermalColor(_ level: ThermalLevel) -> Color {
        switch level {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        }
    }

    private func loadingStatusPill(_ state: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(state)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }

    private func mpvErrorBanner(_ message: String) -> some View {
        VStack(spacing: 12) {
            Label("MPV 播放遇到异常", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button {
                    coordinator.retryWithoutShaders()
                } label: {
                    Text("关闭超分重试")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.cyan).interactive(), in: .capsule)

                Button {
                    showDiagnosticSheet = true
                } label: {
                    Text("查看诊断日志")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)

                Button {
                    coordinator.closeToHome()
                } label: {
                    Text("返回主界面")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding()
    }

    private func opticalFlowErrorBanner(_ message: String) -> some View {
        VStack {
            VStack(spacing: 12) {
                Label("ANE 光流核暂不可用", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button {
                        coordinator.switchEngine(to: .mpv)
                    } label: {
                        Text("一键切回 MPV 超分核")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.cyan).interactive(), in: .capsule)

                    Button {
                        coordinator.closeToHome()
                    } label: {
                        Text("返回主界面")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
            .padding(20)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .padding()
        }
    }

    private var displayTime: Double {
        isScrubbing ? scrubTime : coordinator.activeCurrentTime
    }

    private var activeResolutionText: String {
        let m = coordinator.hudMetrics
        if m.width > 0 && m.height > 0 {
            return "\(m.width)×\(m.height)"
        }
        return coordinator.engineMode == .mpv ? "MPV" : (optical.enableSpatial2xUpscale ? "ANE 2×超分" : "ANE 光流")
    }

    private var activeFPSText: String {
        let m = coordinator.hudMetrics
        let fps = m.outputFPS > 0 ? m.outputFPS : m.sourceFPS
        return fps > 0 ? "\(PlaybackHUDMetrics.formatOutputFPS(fps)) fps" : "-- fps"
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Shader & Frame Interpolation Control Sheet

struct EnhancementControlSheet: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("播放内核（路线 C 双核）") {
                    Picker("内核", selection: Binding(
                        get: { coordinator.engineMode },
                        set: { coordinator.switchEngine(to: $0) }
                    )) {
                        ForEach(PlayerEngineMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(coordinator.engineMode.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("补帧模式（适配 iPhone 15 PM 120Hz）") {
                    ForEach(InterpolationMode.allCases) { mode in
                        Button {
                            coordinator.setInterpolation(mode)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.rawValue)
                                        .foregroundStyle(.primary)
                                    Text(interpolationHint(mode))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if coordinator.interpolationMode == mode {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.cyan)
                                }
                            }
                        }
                    }

                    if let gatedReason = coordinator.superResolutionDisabledReason {
                        Label(gatedReason, systemImage: "4k.tv.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if coordinator.engineMode == .opticalFlow {
                        Toggle("同步开启 ANE 2× 硬件超分", isOn: Binding(
                            get: { coordinator.vtSpatial2x },
                            set: { coordinator.setVTSpatial2x($0) }
                        ))
                        .disabled(coordinator.isSuperResolutionDisabledBy4K)
                    }
                }

                if coordinator.engineMode == .mpv {
                    Section("Anime4K 组合预设（源自原包 input.conf）") {
                        if let gatedReason = coordinator.superResolutionDisabledReason {
                            Label(gatedReason, systemImage: "4k.tv.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        ForEach(ShaderPreset.allPresets) { preset in
                            Button {
                                coordinator.applyPreset(preset)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(preset.title)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.primary)
                                            Text(preset.tier.rawValue)
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(tierColor(preset.tier).opacity(0.2))
                                                .foregroundStyle(tierColor(preset.tier))
                                                .clipShape(Capsule())
                                        }
                                        Text(preset.detail)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if coordinator.selectedPreset.id == preset.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.cyan)
                                    }
                                }
                            }
                            .disabled(coordinator.isSuperResolutionDisabledBy4K && preset.id != ShaderPreset.off.id)
                        }
                    }

                    Section("附加经典着色器（可叠加）") {
                        ForEach(SingleShaderOption.allOptions) { option in
                            Toggle(isOn: Binding(
                                get: { coordinator.selectedExtras.contains(option.id) },
                                set: { _ in coordinator.toggleExtraShader(option.id) }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                    Text(option.summary)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(coordinator.isSuperResolutionDisabledBy4K)
                        }
                    }
                }

                Section("关于与更新日志") {
                    LabeledContent("当前版本", value: AppReleaseInfo.displayVersion)
                    ForEach(AppReleaseInfo.changelog) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(entry.version) · \(entry.date)")
                                .font(.caption.weight(.semibold))
                            ForEach(entry.highlights, id: \.self) { item in
                                Text("• \(item)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("超分与补帧控制台")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func tierColor(_ tier: ShaderLoadTier) -> Color {
        switch tier {
        case .none: return .gray
        case .fast: return .green
        case .hq: return .orange
        }
    }

    private func interpolationHint(_ mode: InterpolationMode) -> String {
        switch mode {
        case .off:
            return "按片源原生帧率输出"
        case .mpvSmooth120Hz:
            return "display-resample + tscale=mitchell，消除24p抖动并与GLSL超分共存"
        case .vtOpticalFlow2x:
            return "Apple VideoToolbox 神经网络真光流插帧（仅 MP4/MOV）"
        }
    }
}

struct ReleaseNotesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("当前版本") {
                    LabeledContent("GlassMPV", value: AppReleaseInfo.displayVersion)
                }

                ForEach(AppReleaseInfo.changelog) { entry in
                    Section("\(entry.version) · \(entry.date)") {
                        ForEach(entry.highlights, id: \.self) { item in
                            Label(item, systemImage: "sparkles")
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("版本与更新日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

struct DiagnosticLogSheet: View {
    @ObservedObject var mpv: MPVPlayerController
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject private var optical: OpticalFlowPlayerController
    @Environment(\.dismiss) private var dismiss
    @State private var copiedFeedback: Bool = false
    @State private var copiedSelfCheckFeedback: Bool = false
    @State private var exportedFeedback: Bool = false
    @State private var exportErrorMessage: String?

    init(mpv: MPVPlayerController, coordinator: PlayerCoordinator) {
        self.mpv = mpv
        self.coordinator = coordinator
        self._optical = ObservedObject(wrappedValue: coordinator.opticalFlowController)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("真机 5 项体检") {
                    Button {
                        coordinator.runRealDeviceSelfCheck()
                    } label: {
                        Label("一键执行真机 5 项体检", systemImage: "stethoscope.circle.fill")
                    }

                    if !coordinator.selfCheckReport.isEmpty {
                        Text(coordinator.selfCheckReport)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)

                        Button {
                            UIPasteboard.general.string = coordinator.selfCheckReport
                            copiedSelfCheckFeedback = true
                        } label: {
                            Label(
                                copiedSelfCheckFeedback ? "已复制体检报告" : "一键复制体检报告",
                                systemImage: copiedSelfCheckFeedback ? "checkmark.circle.fill" : "doc.on.clipboard"
                            )
                        }
                    }
                }

                Section("内核与播放状态") {
                    let activeW = coordinator.activeVideoWidth
                    let activeH = coordinator.activeVideoHeight
                    let activeSrcFPS = coordinator.engineMode == .mpv ? mpv.sourceFPS : optical.sourceFPS
                    let activeOutFPS = coordinator.engineMode == .mpv ? mpv.outputFPS : optical.actualOutputFPS
                    let activeCodec = coordinator.engineMode == .mpv ? mpv.videoCodec : optical.videoCodec
                    let activeBitDepth = coordinator.engineMode == .mpv ? mpv.bitDepthLabel : optical.bitDepthLabel
                    let activeHDR = coordinator.engineMode == .mpv ? mpv.hdrLabel : optical.hdrLabel
                    let activeState = coordinator.engineMode == .mpv ? mpv.playbackState : (optical.isPaused ? "已暂停" : "播放中")

                    LabeledContent("当前引擎", value: coordinator.engineMode.rawValue)
                    LabeledContent("初始化状态", value: mpv.isInitialized ? "已就绪" : "未初始化")
                    LabeledContent("运行阶段", value: activeState)
                    LabeledContent("视频分辨率", value: activeW > 0 ? "\(activeW)×\(activeH)" : "暂无")
                    LabeledContent("色深 / HDR", value: "\(activeBitDepth) · \(activeHDR)")
                    LabeledContent("帧率 (源/输出)", value: "\(String(format: "%.1f", activeSrcFPS)) / \(String(format: "%.1f", activeOutFPS)) fps")
                    LabeledContent("设备温度状态", value: ThermalLevel(state: coordinator.thermalState).rawValue)
                    LabeledContent("启用着色器数", value: "\(mpv.activeShaderCount)")
                    LabeledContent(
                        "解码器 / 硬解",
                        value: "\(activeCodec.isEmpty ? "-" : activeCodec) / \(coordinator.engineMode == .mpv ? (mpv.hardwareDecoder.isEmpty ? "-" : mpv.hardwareDecoder) : "VT+ANE (\(optical.clockSourceLabel))")"
                    )
                    LabeledContent(
                        "MPV 目标 / 实报同步",
                        value: "\(mpv.targetDisplaySyncFPS > 0 ? String(format: "%.0f Hz", mpv.targetDisplaySyncFPS) : "关闭") / \(mpv.displaySyncFPS > 0 ? String(format: "%.1f Hz", mpv.displaySyncFPS) : "未上报")"
                    )
                    LabeledContent(
                        "ProMotion 保活 / 实测",
                        value: "\(mpv.isProMotionKeeperActive ? "开启" : "关闭") / \(mpv.measuredProMotionFPS > 0 ? String(format: "%.1f Hz", mpv.measuredProMotionFPS) : "--")"
                    )
                    LabeledContent(
                        "渲染 Pass (新帧 / 重绘)",
                        value: "\(mpv.freshRenderPassCount) / \(mpv.redrawRenderPassCount)"
                    )
                    LabeledContent(
                        "时序失步 / 延迟帧",
                        value: "\(mpv.mistimedFrames) / \(mpv.delayedFrames)"
                    )
                    LabeledContent(
                        "ANE 光流状态",
                        value: "\(optical.capabilityDescription) (时钟 \(optical.clockSourceLabel) · 补帧 \(optical.interpolatedFrameCount) / 追赶跳过 \(optical.skippedInterpolationCount) / 失败 \(optical.failedInterpolationCount) / 送显 \(optical.presentedFrameCount) / 耗时 \(String(format: "%.1f", optical.averageInterpolationMs))ms)"
                    )
                    if let currentURL = coordinator.currentURL {
                        LabeledContent("当前片源", value: currentURL.lastPathComponent)
                    }
                    if let err = mpv.lastErrorMessage {
                        Text("MPV 最近错误：\(err)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let optErr = optical.errorMessage ?? optical.lastInterpolationError {
                        Text("光流最近错误：\(optErr)")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }

                Section("快捷排查动作") {
                    Button {
                        coordinator.playBuiltInSampleVideo()
                        dismiss()
                    } label: {
                        Label("一键生成并播放内置 3 秒测试视频", systemImage: "play.circle.fill")
                    }

                    Button {
                        coordinator.retryWithoutShaders()
                        dismiss()
                    } label: {
                        Label("关闭全部超分/补帧并重新播放", systemImage: "arrow.counterclockwise")
                    }

                    Button {
                        UIPasteboard.general.string = buildFullDiagnosticReport()
                        copiedFeedback = true
                    } label: {
                        Label(
                            copiedFeedback ? "已复制全部诊断日志" : "一键复制全部诊断日志",
                            systemImage: copiedFeedback ? "checkmark.circle.fill" : "doc.on.doc"
                        )
                    }

                    Button {
                        exportErrorMessage = nil
                        do {
                            let fileURL = try DiagnosticLogExporter.writeLogFile(content: buildFullDiagnosticReport())
                            NativeShareSheetPresenter.present(fileURL: fileURL) { err in
                                exportErrorMessage = err
                            }
                            exportedFeedback = true
                        } catch {
                            exportErrorMessage = "写入日志文件失败：\(error.localizedDescription)"
                        }
                    } label: {
                        Label(
                            exportedFeedback ? "已生成 .txt 诊断日志文件" : "导出诊断日志 (.txt)",
                            systemImage: exportedFeedback ? "checkmark.circle.fill" : "square.and.arrow.up"
                        )
                    }

                    if let exportErrorMessage {
                        Text(exportErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("libmpv 事件与警告日志（最近 \(mpv.diagnosticLogs.count) 条）") {
                    if mpv.diagnosticLogs.isEmpty {
                        Text("暂无日志（打开视频或触发测试视频后将自动采集）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(mpv.diagnosticLogs.reversed().enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }

                Section("ANE 光流核日志（最近 \(optical.diagnosticLogs.count) 条）") {
                    if optical.diagnosticLogs.isEmpty {
                        Text("暂无光流核日志（切换至 ANE 光流核后将自动采集）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(optical.diagnosticLogs.reversed().enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .onAppear {
                coordinator.runRealDeviceSelfCheck()
            }
            .navigationTitle("播放诊断中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func buildFullDiagnosticReport() -> String {
        if coordinator.selfCheckReport.isEmpty {
            coordinator.runRealDeviceSelfCheck()
        }
        let metrics = coordinator.hudMetrics
        let resolution = (metrics.width > 0 && metrics.height > 0)
            ? "\(metrics.width)×\(metrics.height)"
            : "暂无"
        let stateText = coordinator.engineMode == .mpv
            ? mpv.playbackState
            : (optical.isPaused ? "已暂停" : "播放中")
        let telemetrySummary = [
            "MPV Target Sync: \(mpv.targetDisplaySyncFPS > 0 ? String(format: "%.0f Hz", mpv.targetDisplaySyncFPS) : "OFF")",
            "MPV Reported Display Sync: \(mpv.displaySyncFPS > 0 ? String(format: "%.1f Hz", mpv.displaySyncFPS) : "unreported")",
            "ProMotion Keeper: \(mpv.isProMotionKeeperActive ? "active" : "inactive") (\(mpv.measuredProMotionFPS > 0 ? String(format: "%.1f Hz", mpv.measuredProMotionFPS) : "--"))",
            "MPV Passes (fresh/redraw): \(mpv.freshRenderPassCount) / \(mpv.redrawRenderPassCount) | mistimed=\(mpv.mistimedFrames) | delayed=\(mpv.delayedFrames)",
            "ANE Clock: \(optical.clockSourceLabel) | spatial2x=\(optical.enableSpatial2xUpscale ? "ON" : "OFF")",
            "ANE Counters: interpolated=\(optical.interpolatedFrameCount) | skipped=\(optical.skippedInterpolationCount) | failed=\(optical.failedInterpolationCount) | presented=\(optical.presentedFrameCount) | avgMs=\(String(format: "%.1f", optical.averageInterpolationMs)) | actualFPS=\(String(format: "%.1f", optical.actualOutputFPS))"
        ]
        return DiagnosticLogExporter.buildReport(
            version: AppReleaseInfo.displayVersion,
            engineName: coordinator.engineMode.rawValue,
            playbackState: stateText,
            resolution: resolution,
            fpsSummary: metrics.fpsSummary,
            decoderSummary: "\(metrics.codec) / \(metrics.decoderBadge)",
            is4KGated: coordinator.isSuperResolutionDisabledBy4K,
            telemetrySummary: telemetrySummary,
            selfCheck: coordinator.selfCheckReport,
            mpvLogs: mpv.diagnosticLogs,
            opticalLogs: optical.diagnosticLogs
        )
    }
}
