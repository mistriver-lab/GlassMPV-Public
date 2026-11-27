import SwiftUI

enum PlayerSettingsTab: String, CaseIterable, Identifiable {
    case video = "视频"
    case audio = "音频"
    case subtitles = "字幕"
    case playback = "播放"

    var id: Self { self }
}

@MainActor
struct PlayerUnifiedSettingsSheet: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject private var optical: OpticalFlowPlayerController
    @ObservedObject private var subtitleManager: SubtitleManager
    @ObservedObject private var preferencesStore: UserPreferencesStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: PlayerSettingsTab
    let onOpenDiagnostics: () -> Void

    init(
        coordinator: PlayerCoordinator,
        initialTab: PlayerSettingsTab = .video,
        onOpenDiagnostics: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self._optical = ObservedObject(wrappedValue: coordinator.opticalFlowController)
        self._subtitleManager = ObservedObject(wrappedValue: coordinator.subtitleManager)
        self._preferencesStore = ObservedObject(wrappedValue: coordinator.preferencesStore)
        self._selectedTab = State(initialValue: initialTab)
        self.onOpenDiagnostics = onOpenDiagnostics
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("设置分区", selection: $selectedTab) {
                    ForEach(PlayerSettingsTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)

                List {
                    switch selectedTab {
                    case .video:
                        videoSectionContent
                    case .audio:
                        audioSectionContent
                    case .subtitles:
                        SubtitleSettingsSections(
                            coordinator: coordinator,
                            subtitleManager: subtitleManager,
                            onDismissForFilePicker: { dismiss() }
                        )
                    case .playback:
                        playbackSectionContent
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("播放选项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var videoSectionContent: some View {
        Section("ANE 光流补帧") {
            FrameRatePresetStrip(coordinator: coordinator, optical: optical, compact: true)
                .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                .listRowBackground(Color.black.opacity(0.35))
        }

        Section("Metal 实时画质增强") {
            QualityPresetStrip(coordinator: coordinator, optical: optical, compact: true)
                .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                .listRowBackground(Color.black.opacity(0.35))
        }

        Section("画面与色彩") {
            Picker("缩放模式", selection: Binding(
                get: { coordinator.isAspectFill },
                set: { coordinator.setAspectFill($0) }
            )) {
                Text("原始比例 (适应)").tag(false)
                Text("充满屏幕 (裁边)").tag(true)
            }

            if optical.isHDRContent {
                Toggle("HDR / EDR 峰值亮度渲染", isOn: Binding(
                    get: { coordinator.isEDREnabled },
                    set: { coordinator.setEDREnabled($0) }
                ))
            }

            Toggle("在播放顶部显示技术参数角标", isOn: $preferencesStore.showDeveloperHUD)
        }

        if coordinator.currentStreamVariants.count > 1 {
            Section("片源画质流") {
                ForEach(coordinator.currentStreamVariants) { variant in
                    let isCurrent = (variant.url == coordinator.currentURL)
                    Button {
                        coordinator.switchStreamVariant(variant)
                        dismiss()
                    } label: {
                        HStack {
                            Text(variant.label)
                                .foregroundStyle(.primary)
                            Spacer()
                            if variant.isHLS {
                                Text("HLS")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            if isCurrent {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.cyan)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var audioSectionContent: some View {
        Section("内嵌音轨") {
            if optical.availableAudioTracks.isEmpty {
                LabeledContent("当前音轨", value: "默认主音轨")
            } else {
                ForEach(optical.availableAudioTracks) { track in
                    let isSelected = (optical.selectedAudioTrackIndex == track.id)
                    Button {
                        coordinator.selectAudioTrack(at: track.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.displayName)
                                    .foregroundStyle(.primary)
                                if !track.languageCode.isEmpty && track.languageCode != "und" {
                                    Text(track.languageCode)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.cyan)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var playbackSectionContent: some View {
        Section("倍速调节") {
            HStack(spacing: 8) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    let selected = abs(coordinator.speed - rate) < 0.01
                    Button {
                        coordinator.setSpeed(rate)
                    } label: {
                        Text("\(rate, specifier: "%.2g")×")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(selected ? .black : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                selected ? Color.cyan : Color.white.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        Section("追剧与片头跳过") {
            Toggle("单集循环播放", isOn: Binding(
                get: { coordinator.isLooping },
                set: { coordinator.setLooping($0) }
            ))

            Toggle("片尾自动显示「下一集」倒计时", isOn: $preferencesStore.autoShowUpNextCard)

            Picker("双击 / 按钮快进退秒数", selection: $preferencesStore.skipIntervalSeconds) {
                Text("10 秒").tag(10)
                Text("15 秒").tag(15)
                Text("30 秒").tag(30)
            }

            let introSec = coordinator.currentFolderIntroSeconds
            LabeledContent("当前片头长度", value: introSec > 0 ? "\(introSec) 秒" : "未设定")

            Button {
                coordinator.skipIntro()
                dismiss()
            } label: {
                Label("立即跳过片头至 \(WatchHistoryEntry.formatClock(Double(introSec)))", systemImage: "forward.end.fill")
            }
            .disabled(introSec < 5)

            if coordinator.activeFolderKey != nil {
                Button {
                    coordinator.rememberCurrentPositionAsIntro()
                } label: {
                    Label(
                        "将当前时间 (\(WatchHistoryEntry.formatClock(coordinator.activeCurrentTime))) 记为本目录片头",
                        systemImage: "bookmark.fill"
                    )
                }
                .disabled(coordinator.activeCurrentTime < 15)

                if preferencesStore.hasCustomIntroDuration(forFolderKey: coordinator.activeFolderKey) {
                    Button(role: .destructive) {
                        coordinator.resetCurrentFolderIntro()
                    } label: {
                        Label("恢复默认片头时长", systemImage: "arrow.uturn.backward")
                    }
                }
            }
        }

        Section("手势、方向与诊断") {
            Toggle("启用播放触摸手势（滑动/捏合/长按）", isOn: $preferencesStore.gesturesEnabled)

            Button {
                OrientationController.shared.toggleVideoOrientation()
                coordinator.recordUISwitch("toggleOrientation")
            } label: {
                Label("切换横屏 / 竖屏锁定", systemImage: "rotate.right")
            }

            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    onOpenDiagnostics()
                }
            } label: {
                Label("打开运行日志中心", systemImage: "waveform.path.ecg")
            }
        }
    }
}
