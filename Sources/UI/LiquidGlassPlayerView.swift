import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PlayerCoordinator: ObservableObject {
    @Published var engineMode: PlayerEngineMode = .mpv
    @Published var selectedPreset: ShaderPreset = ShaderPreset.allPresets[1] // 默认 Anime4K Mode A (FAST)
    @Published var selectedExtras: Set<String> = []
    @Published var interpolationMode: InterpolationMode = .mpvSmooth120Hz
    @Published var vtSpatial2x: Bool = false
    @Published var speed: Double = 1.0
    @Published var currentURL: URL?

    let mpvController = MPVPlayerController()
    let opticalFlowController = OpticalFlowPlayerController()

    private var securityScopedURL: URL?

    func open(url: URL, isSecurityScoped: Bool = false) {
        if isSecurityScoped {
            if let old = securityScopedURL, old != url {
                old.stopAccessingSecurityScopedResource()
            }
            if url.startAccessingSecurityScopedResource() {
                securityScopedURL = url
            }
        }
        currentURL = url
        startPlaybackForCurrentEngine()
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

    deinit {
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }
}

struct LiquidGlassPlayerView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject private var mpv: MPVPlayerController
    @ObservedObject private var optical: OpticalFlowPlayerController

    @State private var showHUD: Bool = true
    @State private var showFileImporter: Bool = false
    @State private var showURLPrompt: Bool = false
    @State private var streamURLInput: String = ""
    @State private var showEnhancementSheet: Bool = false
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
            } else if showHUD {
                playerHUDOverlay
                    .transition(.opacity)
            }

            if coordinator.engineMode == .opticalFlow, let error = optical.errorMessage {
                opticalFlowErrorBanner(error)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let first = urls.first {
                coordinator.open(url: first, isSecurityScoped: true)
            }
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
    }

    // MARK: - Welcome Empty State

    private var welcomeOverlay: some View {
        GlassEffectContainer(spacing: 18) {
            VStack(spacing: 20) {
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

                HStack(spacing: 14) {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("打开本地视频", systemImage: "folder.badge.plus")
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.cyan).interactive(), in: .capsule)

                    Button {
                        showURLPrompt = true
                    } label: {
                        Label("网络串流", systemImage: "link")
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }

                Button {
                    showEnhancementSheet = true
                } label: {
                    Label("预设超分：\(coordinator.selectedPreset.title)", systemImage: "wand.and.stars")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
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

                    Button {
                        showURLPrompt = true
                    } label: {
                        Image(systemName: "link")
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
