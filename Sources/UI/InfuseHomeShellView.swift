import SwiftUI

struct LocalOfflineVideoItem: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let sizeBytes: Int64
    let modifiedAt: Date

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: sizeBytes)
    }
}

@MainActor
struct InfuseHomeShellView<PhotosTile: View>: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject private var mediaSourceStore: MediaSourceStore
    @ObservedObject private var watchHistoryStore: WatchHistoryStore
    @ObservedObject private var preferencesStore: UserPreferencesStore

    @Binding var showURLPrompt: Bool
    @Binding var showAddMediaSourceSheet: Bool
    @Binding var showHistorySheet: Bool
    @Binding var showEnhancementSheet: Bool
    @Binding var showDiagnosticSheet: Bool
    @Binding var showChangelogSheet: Bool
    @ViewBuilder let photosPickerTile: () -> PhotosTile

    @State private var selectedTab: Int = 0
    @State private var offlineFiles: [LocalOfflineVideoItem] = []

    init(
        coordinator: PlayerCoordinator,
        showURLPrompt: Binding<Bool>,
        showAddMediaSourceSheet: Binding<Bool>,
        showHistorySheet: Binding<Bool>,
        showEnhancementSheet: Binding<Bool>,
        showDiagnosticSheet: Binding<Bool>,
        showChangelogSheet: Binding<Bool>,
        @ViewBuilder photosPickerTile: @escaping () -> PhotosTile
    ) {
        self.coordinator = coordinator
        self._mediaSourceStore = ObservedObject(wrappedValue: coordinator.mediaSourceStore)
        self._watchHistoryStore = ObservedObject(wrappedValue: coordinator.watchHistoryStore)
        self._preferencesStore = ObservedObject(wrappedValue: coordinator.preferencesStore)
        self._showURLPrompt = showURLPrompt
        self._showAddMediaSourceSheet = showAddMediaSourceSheet
        self._showHistorySheet = showHistorySheet
        self._showEnhancementSheet = showEnhancementSheet
        self._showDiagnosticSheet = showDiagnosticSheet
        self._showChangelogSheet = showChangelogSheet
        self.photosPickerTile = photosPickerTile
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            homeTab
                .tabItem {
                    Label("首页", systemImage: "house.fill")
                }
                .tag(0)

            sourcesTab
                .tabItem {
                    Label("片源", systemImage: "folder.fill")
                }
                .tag(1)

            settingsTab
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
                .tag(2)
        }
        .tint(.cyan)
        .onAppear {
            reloadOfflineFiles()
        }
        .onChange(of: selectedTab) { _, _ in
            reloadOfflineFiles()
        }
    }

    // MARK: - Tab 1: 首页

    private var homeTab: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    if !watchHistoryStore.entries.isEmpty {
                        continueWatchingSection
                    }

                    pinnedFoldersSection

                    quickOpenSection

                    if !offlineFiles.isEmpty {
                        offlineLibrarySection
                    }
                }
                .frame(maxWidth: 680)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
            .refreshable {
                reloadOfflineFiles()
            }
            .navigationTitle("首页")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            showAddMediaSourceSheet = true
                        } label: {
                            Image(systemName: "plus.circle")
                        }

                        Button {
                            showDiagnosticSheet = true
                        } label: {
                            Image(systemName: "waveform.path.ecg")
                        }
                    }
                }
            }
        }
    }

    private var continueWatchingSection: some View {
        let carouselItems = watchHistoryStore.continueWatchingEntries.isEmpty
            ? Array(watchHistoryStore.entries.prefix(10))
            : watchHistoryStore.continueWatchingEntries

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("继续观看")
                    .font(.title3.bold())
                Spacer()
                Button {
                    showHistorySheet = true
                } label: {
                    HStack(spacing: 3) {
                        Text("全部 (\(watchHistoryStore.entries.count))")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(carouselItems) { entry in
                        ContinueWatchingCard(
                            entry: entry,
                            thumbnailURL: watchHistoryStore.thumbnailURL(for: entry),
                            onPlay: {
                                coordinator.resumeFromHistory(entry)
                            },
                            onPlayFromBeginning: {
                                coordinator.resumeFromHistory(entry, fromBeginning: true)
                            },
                            onToggleCompleted: {
                                watchHistoryStore.markCompleted(id: entry.id, completed: !entry.isCompleted)
                            },
                            onDelete: {
                                watchHistoryStore.remove(id: entry.id)
                            }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var pinnedFoldersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("收藏夹")
                    .font(.title3.bold())
                Spacer()
                Button {
                    selectedTab = 1
                } label: {
                    Text(mediaSourceStore.accounts.isEmpty ? "添加片源" : "浏览全部片源")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
            }

            if preferencesStore.pinnedFolders.isEmpty {
                Button {
                    if mediaSourceStore.accounts.isEmpty {
                        showAddMediaSourceSheet = true
                    } else {
                        selectedTab = 1
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "star.fill")
                            .font(.title3)
                            .foregroundStyle(.yellow)
                            .frame(width: 40, height: 40)
                            .background(Color.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mediaSourceStore.accounts.isEmpty ? "添加夸克 / Emby / WebDAV 片源" : "将常用追剧目录钉选到首页")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(mediaSourceStore.accounts.isEmpty ? "接入网盘或媒体库后即可两步直接看剧" : "前往「片源」打开任意目录，点击右上角 ☆ 或长按文件夹即可固定在此")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            )
                    )
                }
                .buttonStyle(.plain)
            } else {
                let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(preferencesStore.pinnedFolders) { pin in
                        if let account = mediaSourceStore.accounts.first(where: { $0.id == pin.accountID }) {
                            NavigationLink {
                                CloudDirectoryBrowserView(
                                    account: account,
                                    store: mediaSourceStore,
                                    watchHistoryStore: watchHistoryStore,
                                    preferencesStore: preferencesStore,
                                    initialFolderKey: pin.folderKey,
                                    initialFolderTitle: pin.folderTitle,
                                    showsCloseButton: false,
                                    onPlay: { request, seekTo in
                                        coordinator.openCloudStream(request, seekTo: seekTo)
                                    },
                                    onDownloadLocal: { localURL in
                                        coordinator.open(url: localURL, isSecurityScoped: false)
                                    }
                                )
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder.fill")
                                        .font(.title3)
                                        .foregroundStyle(pin.sourceKind == .emby ? .green : (pin.sourceKind == .quark ? .cyan : .indigo))
                                        .frame(width: 36, height: 36)
                                        .background(
                                            (pin.sourceKind == .emby ? Color.green : (pin.sourceKind == .quark ? Color.cyan : Color.indigo)).opacity(0.16),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pin.folderTitle)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text("\(pin.sourceKind.shortBadge) · \(pin.accountName)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(12)
                                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    preferencesStore.removePin(id: pin.id)
                                } label: {
                                    Label("取消首页收藏", systemImage: "star.slash")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var quickOpenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快速打开")
                .font(.title3.bold())

            HStack(spacing: 10) {
                Button {
                    coordinator.presentLocalVideoPicker()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.title3)
                            .foregroundStyle(.cyan)
                        Text("本地文件")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))

                photosPickerTile()

                Button {
                    showURLPrompt = true
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.title3)
                            .foregroundStyle(.green)
                        Text("网络串流")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            }
        }
    }

    private var offlineLibrarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("本地离线片库")
                    .font(.title3.bold())
                Spacer()
                Text("\(offlineFiles.count) 部")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(offlineFiles) { file in
                    Button {
                        coordinator.open(url: file.url, isSecurityScoped: false)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "internaldrive.fill")
                                .font(.callout)
                                .foregroundStyle(.cyan)
                                .frame(width: 34, height: 34)
                                .background(Color.cyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(file.formattedSize)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.cyan)
                        }
                        .padding(11)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            try? FileManager.default.removeItem(at: file.url)
                            reloadOfflineFiles()
                        } label: {
                            Label("删除本地缓存", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tab 2: 片源

    private var sourcesTab: some View {
        NavigationStack {
            List {
                if mediaSourceStore.accounts.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            ContentUnavailableView(
                                "尚未添加云端片源",
                                systemImage: "externaldrive.badge.icloud",
                                description: Text("接入夸克网盘、Emby 媒体库或 WebDAV / Alist，即点即播并支持首页目录收藏。")
                            )
                            Button {
                                showAddMediaSourceSheet = true
                            } label: {
                                Label("添加第一个片源", systemImage: "plus.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)
                        }
                        .padding(.vertical, 8)
                    }
                } else {
                    Section("已挂载片源") {
                        ForEach(mediaSourceStore.accounts) { account in
                            NavigationLink {
                                CloudDirectoryBrowserView(
                                    account: account,
                                    store: mediaSourceStore,
                                    watchHistoryStore: watchHistoryStore,
                                    preferencesStore: preferencesStore,
                                    showsCloseButton: false,
                                    onPlay: { request, seekTo in
                                        coordinator.openCloudStream(request, seekTo: seekTo)
                                    },
                                    onDownloadLocal: { localURL in
                                        coordinator.open(url: localURL, isSecurityScoped: false)
                                    }
                                )
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: account.kind.iconName)
                                        .font(.title3)
                                        .foregroundStyle(account.kind == .emby ? .green : (account.kind == .quark ? .cyan : .indigo))
                                        .frame(width: 38, height: 38)
                                        .background(
                                            (account.kind == .emby ? Color.green : (account.kind == .quark ? Color.cyan : Color.indigo)).opacity(0.16),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(account.name)
                                            .font(.subheadline.weight(.semibold))
                                        Text(account.kind.displayName)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .onDelete { offsets in
                            let targets = offsets.map { mediaSourceStore.accounts[$0] }
                            for acc in targets {
                                preferencesStore.removePins(forAccountID: acc.id)
                                mediaSourceStore.delete(accountID: acc.id)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("片源")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddMediaSourceSheet = true
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                }
            }
        }
    }

    // MARK: - Tab 3: 设置

    private var settingsTab: some View {
        NavigationStack {
            List {
                Section("播放与追剧") {
                    Toggle("连续播放下一集", isOn: Binding(
                        get: { preferencesStore.continuousPlayback },
                        set: { newVal in
                            preferencesStore.continuousPlayback = newVal
                            coordinator.setLooping(!newVal)
                        }
                    ))

                    Toggle("片尾显示「即将播放下一集」倒计时", isOn: $preferencesStore.autoShowUpNextCard)

                    Picker("快进 / 快退步长", selection: $preferencesStore.skipIntervalSeconds) {
                        Text("10 秒").tag(10)
                        Text("15 秒").tag(15)
                        Text("30 秒").tag(30)
                    }

                    Picker("默认跳过片头时长", selection: $preferencesStore.defaultSkipIntroSeconds) {
                        Text("关闭 (0 秒)").tag(0)
                        Text("60 秒").tag(60)
                        Text("85 秒").tag(85)
                        Text("90 秒").tag(90)
                        Text("120 秒").tag(120)
                    }

                    Toggle("默认充满屏幕 (裁边去黑边)", isOn: Binding(
                        get: { preferencesStore.defaultAspectFill },
                        set: { newVal in
                            preferencesStore.defaultAspectFill = newVal
                            coordinator.setAspectFill(newVal)
                        }
                    ))
                }

                Section("手势与画面") {
                    Toggle("启用播放手势（滑动 / 捏合 / 长按倍速）", isOn: $preferencesStore.gesturesEnabled)
                    Toggle("播放顶部显示实时技术指标角标", isOn: $preferencesStore.showDeveloperHUD)
                }

                Section("画质增强与 ANE 光流") {
                    Button {
                        showEnhancementSheet = true
                    } label: {
                        HStack {
                            Label("默认光流档位与超分增强", systemImage: "sparkles")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(coordinator.currentEnhancementSummary) · \(coordinator.videoEnhancementPreset.shortBadge)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("本地缓存与历史") {
                    let totalBytes = offlineFiles.reduce(Int64(0)) { $0 + $1.sizeBytes }
                    let formattedTotal = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                    LabeledContent("离线缓存影片", value: "\(offlineFiles.count) 部（\(formattedTotal)）")

                    if !offlineFiles.isEmpty {
                        Button(role: .destructive) {
                            clearOfflineCache()
                        } label: {
                            Label("清理全部离线缓存影片", systemImage: "trash")
                        }
                    }

                    Button {
                        showHistorySheet = true
                    } label: {
                        Label("管理观看记录 (\(watchHistoryStore.entries.count))", systemImage: "clock.arrow.circlepath")
                    }
                }

                Section("诊断与关于") {
                    Button {
                        showDiagnosticSheet = true
                    } label: {
                        Label("运行日志与硬件体检", systemImage: "waveform.path.ecg")
                    }

                    Button {
                        showChangelogSheet = true
                    } label: {
                        HStack {
                            Label("版本与更新记录", systemImage: "doc.text")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("v\(AppReleaseInfo.releaseTag)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
        }
    }

    private func reloadOfflineFiles() {
        let dir = LocalMediaImporter.importsDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            offlineFiles = []
            return
        }
        let parsed: [LocalOfflineVideoItem] = urls.compactMap { url in
            let ext = url.pathExtension.lowercased()
            guard CloudMediaItem.supportedVideoExtensions.contains(ext) else { return nil }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return LocalOfflineVideoItem(
                url: url,
                name: url.lastPathComponent,
                sizeBytes: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate ?? Date.distantPast
            )
        }
        offlineFiles = parsed.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func clearOfflineCache() {
        for item in offlineFiles {
            try? FileManager.default.removeItem(at: item.url)
        }
        reloadOfflineFiles()
    }
}
