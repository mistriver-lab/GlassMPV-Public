import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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

    let mpvController = MPVPlayerController()
    let opticalFlowController = OpticalFlowPlayerController()

    func open(url: URL, isSecurityScoped: Bool = false) {
        mpvController.clearError()

        if !url.isFileURL {
            currentURL = url
            startPlaybackForCurrentEngine()
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
                self.currentURL = playableURL
                self.startPlaybackForCurrentEngine()
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
                self.currentURL = movie.url
                self.startPlaybackForCurrentEngine()
            } catch {
                self.isImportingFile = false
                self.mpvController.recordExternalError("相册视频导入失败：\(error.localizedDescription)")
            }
        }
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

        let mpvStatus = mpvController.isInitialized
            ? "就绪 | state=\(mpvController.playbackState) | \(mpvController.videoWidth)x\(mpvController.videoHeight) | codec=\(mpvController.videoCodec.isEmpty ? "-" : mpvController.videoCodec) | hwdec=\(mpvController.hardwareDecoder.isEmpty ? "-" : mpvController.hardwareDecoder) | fps=\(String(format: "%.1f", mpvController.sourceFPS))/\(String(format: "%.1f", mpvController.outputFPS)) | display=\(String(format: "%.0f", mpvController.displaySyncFPS))Hz | passes=\(mpvController.freshRenderPassCount) | err=\(mpvController.lastErrorMessage ?? "none")"
            : "未初始化"

        let opticalStatus = "\(opticalFlowController.capabilityDescription) | 成功补帧=\(opticalFlowController.interpolatedFrameCount) | 失败=\(opticalFlowController.failedInterpolationCount) | err=\(opticalFlowController.errorMessage ?? opticalFlowController.lastInterpolationError ?? "none")"

        let lines = [
            "=== GlassMPV 真机 5 项体检报告 ===",
            "版本: \(AppReleaseInfo.displayVersion) | 当前引擎: \(engineMode.rawValue)",
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
        selectedPreset = preset
        mpvController.applyShaders(preset: preset, extras: selectedExtras)
    }

    func toggleExtraShader(_ id: String) {
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
        vtSpatial2x = enabled
        if engineMode == .opticalFlow, let url = currentURL {
            let t = opticalFlowController.currentTime
            opticalFlowController.load(url: url, spatial2x: enabled)
            if t > 0.5 {
                opticalFlowController.seek(to: t)
            }
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
            opticalFlowController.load(url: url, spatial2x: vtSpatial2x)
            opticalFlowController.setSpeed(speed)
            if seekTo > 0.5 {
                opticalFlowController.seek(to: seekTo)
            }
        }
    }
}

struct LiquidGlassPlayerView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject private var mpv: MPVPlayerController
    @ObservedObject private var optical: OpticalFlowPlayerController

    @State private var showHUD: Bool = true
    @State private var showFileImporter: Bool = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showURLPrompt: Bool = false
    @State private var streamURLInput: String = ""
    @State private var showEnhancementSheet: Bool = false
    @State private var showChangelogSheet: Bool = false
    @State private var showDiagnosticSheet: Bool = false
    @State private var isScrubbing: Bool = false
    @State private var scrubTime: Double = 0

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
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let first = urls.first {
                    coordinator.open(url: first, isSecurityScoped: true)
                }
            case .failure(let error):
                coordinator.mpvController.recordExternalError("文件选择器返回错误：\(error.localizedDescription)")
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
                        showFileImporter = true
                    } label: {
                        Label("打开本地视频", systemImage: "folder.badge.plus")
                            .font(.headline)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
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
            // 顶部液态玻璃状态栏
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 10) {
                    Button {
                        showFileImporter = true
                    } label: {
                        Image(systemName: "folder")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)

                    PhotosPicker(selection: $selectedPhotoItem, matching: .videos, photoLibrary: .shared()) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)

                    Button {
                        showURLPrompt = true
                    } label: {
                        Image(systemName: "link")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)

                    Button {
                        showDiagnosticSheet = true
                    } label: {
                        Image(systemName: "stethoscope")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)

                    Spacer()

                    // 双核切换胶囊
                    HStack(spacing: 4) {
                        ForEach(PlayerEngineMode.allCases) { mode in
                            Button {
                                coordinator.switchEngine(to: mode)
                            } label: {
                                Text(mode.rawValue)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(
                                coordinator.engineMode == mode
                                    ? .regular.tint(.cyan).interactive()
                                    : .regular.interactive(),
                                in: .capsule
                            )
                        }
                    }

                    Spacer()

                    // 实时参数徽章
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(activeResolutionText)
                            .font(.caption2.monospacedDigit().weight(.semibold))
                        Text("\(coordinator.interpolationMode.shortBadge) · \(activeFPSText)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            Spacer()

            // 底部液态玻璃播放控制坞
            GlassEffectContainer(spacing: 12) {
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
                Button {
                    coordinator.switchEngine(to: .mpv)
                } label: {
                    Text("一键切回 MPV 超分核")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.cyan).interactive(), in: .capsule)
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
        if coordinator.engineMode == .mpv {
            return mpv.videoWidth > 0 ? "\(mpv.videoWidth)×\(mpv.videoHeight)" : "MPV"
        }
        return optical.enableSpatial2xUpscale ? "ANE 2×超分" : "ANE 光流"
    }

    private var activeFPSText: String {
        if coordinator.engineMode == .mpv {
            let fps = mpv.outputFPS > 0 ? mpv.outputFPS : mpv.sourceFPS
            return fps > 0 ? String(format: "%.1f fps", fps) : "-- fps"
        }
        return optical.interpolatedFPS > 0 ? String(format: "%.1f fps", optical.interpolatedFPS) : "-- fps"
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

                    if coordinator.engineMode == .opticalFlow {
                        Toggle("同步开启 ANE 2× 硬件超分", isOn: Binding(
                            get: { coordinator.vtSpatial2x },
                            set: { coordinator.setVTSpatial2x($0) }
                        ))
                    }
                }

                if coordinator.engineMode == .mpv {
                    Section("Anime4K 组合预设（源自原包 input.conf）") {
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
            return "display-resample + tscale=oversample，与全部GLSL超分共存"
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
                    LabeledContent("当前引擎", value: coordinator.engineMode.rawValue)
                    LabeledContent("初始化状态", value: mpv.isInitialized ? "已就绪" : "未初始化")
                    LabeledContent("运行阶段", value: mpv.playbackState)
                    LabeledContent("视频分辨率", value: mpv.videoWidth > 0 ? "\(mpv.videoWidth)×\(mpv.videoHeight)" : "暂无")
                    LabeledContent("帧率 (源/输出)", value: "\(String(format: "%.1f", mpv.sourceFPS)) / \(String(format: "%.1f", mpv.outputFPS)) fps")
                    LabeledContent("启用着色器数", value: "\(mpv.activeShaderCount)")
                    LabeledContent(
                        "解码器 / 硬解",
                        value: "\(mpv.videoCodec.isEmpty ? "-" : mpv.videoCodec) / \(mpv.hardwareDecoder.isEmpty ? "-" : mpv.hardwareDecoder)"
                    )
                    LabeledContent(
                        "显示同步 / 渲染 Pass",
                        value: "\(String(format: "%.0f", mpv.displaySyncFPS)) Hz / \(mpv.freshRenderPassCount)"
                    )
                    LabeledContent(
                        "ANE 光流状态",
                        value: "\(optical.capabilityDescription) (成功 \(optical.interpolatedFrameCount) / 失败 \(optical.failedInterpolationCount))"
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
                        if coordinator.selfCheckReport.isEmpty {
                            coordinator.runRealDeviceSelfCheck()
                        }
                        let summary = [
                            "GlassMPV \(AppReleaseInfo.displayVersion)",
                            "Engine: \(coordinator.engineMode.rawValue)",
                            "State: \(mpv.playbackState)",
                            "Video: \(mpv.videoWidth)x\(mpv.videoHeight) @ \(mpv.sourceFPS)fps",
                            "Decoder: \(mpv.videoCodec) / \(mpv.hardwareDecoder)",
                            "Error: \(mpv.lastErrorMessage ?? "none")",
                            "--- Self Check ---",
                            coordinator.selfCheckReport,
                            "--- Logs ---"
                        ] + mpv.diagnosticLogs
                        UIPasteboard.general.string = summary.joined(separator: "\n")
                        copiedFeedback = true
                    } label: {
                        Label(
                            copiedFeedback ? "已复制全部诊断日志" : "一键复制全部诊断日志",
                            systemImage: copiedFeedback ? "checkmark.circle.fill" : "doc.on.doc"
                        )
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
}
