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

private final class TelemetryLoopToken: @unchecked Sendable {
    var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }
}

enum PlayerOverlayLayoutPolicy: Sendable {
    static func shouldShowCenterTransportControls(
        showFPSPicker: Bool,
        showQualityPicker: Bool,
        isLoadingPipeline: Bool,
        presentedFrameCount: Int,
        hasError: Bool
    ) -> Bool {
        !showFPSPicker && !showQualityPicker && !isLoadingPipeline && presentedFrameCount > 0 && !hasError
    }

    static func activeCenterLoadingMessage(
        isImportingFile: Bool,
        isResolvingHistoryResume: Bool,
        hasActiveURL: Bool,
        hasError: Bool,
        isLoadingPipeline: Bool,
        presentedFrameCount: Int,
        pipelineStatusText: String
    ) -> String? {
        if isResolvingHistoryResume {
            return "正在解析续播直链..."
        }
        if isImportingFile {
            return "正在导入视频..."
        }
        guard hasActiveURL, !hasError else {
            return nil
        }
        if isLoadingPipeline || presentedFrameCount == 0 {
            return pipelineStatusText.isEmpty ? "正在预热视频管线..." : pipelineStatusText
        }
        return nil
    }

    static func topBannerPaddingTop(showHUD: Bool, showStatsHUD: Bool) -> CGFloat {
        if showHUD {
            return showStatsHUD ? 108 : 66
        }
        return showStatsHUD ? 58 : 18
    }

    static func compactStreamVariantLabel(from fullLabel: String) -> String {
        let stripped = fullLabel
            .replacingOccurrences(of: "夸克 · ", with: "")
            .replacingOccurrences(of: "Emby · ", with: "")
            .replacingOccurrences(of: "WebDAV · ", with: "")
            .replacingOccurrences(of: "夸克 ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped == "原画直链" || stripped.isEmpty {
            return "原画"
        }
        return stripped
    }
}

@MainActor
final class PlayerCoordinator: ObservableObject {
    @Published var interpolationMode: InterpolationMode = .vtOpticalFlow
    @Published var opticalFlowTargetFPS: OpticalFlowTargetFPS = .x2
    @Published var vtSpatial2x: Bool = false
    @Published var isEDREnabled: Bool = true
    @Published var isAspectFill: Bool = false
    @Published var isLooping: Bool = true
    @Published var speed: Double = 1.0
    @Published var currentURL: URL?
    @Published var isImportingFile: Bool = false
    @Published var selfCheckReport: String = ""
    @Published var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published var runtimeTimeline: [RuntimeTelemetrySample] = []
    @Published var lastSessionSummary: SessionDiagnosticSummary?
    @Published var uiAuditLogs: [String] = []
    @Published var isLowPowerModeEnabled: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published var videoEnhancementPreset: VideoEnhancementPreset = .off
    @Published var videoEnhancementStrength: VideoEnhancementStrength = .standard
    @Published var qualityCompareMode: VideoEnhancementCompareMode = .off
    @Published var activeMediaRequest: PlaybackMediaRequest?
    @Published var currentStreamVariants: [StreamVariantOption] = []
    @Published var resumeToastText: String?
    @Published var streamNoticeText: String?
    @Published var isResolvingHistoryResume: Bool = false
    @Published private(set) var activeHistoryEntryID: String?
    @Published var activePlaylist: [CloudMediaItem] = []
    @Published var activePlaylistIndex: Int? = nil
    @Published var activeDirectorySubtitles: [CloudMediaItem] = []
    @Published var isHoldFastForwarding: Bool = false

    let opticalFlowController = OpticalFlowPlayerController()
    let mediaSourceStore = MediaSourceStore()
    let subtitleManager = SubtitleManager()
    let watchHistoryStore = WatchHistoryStore()
    let preferencesStore = UserPreferencesStore()
    private let thermalToken = ThermalObserverToken()
    private let powerModeToken = ThermalObserverToken()
    private let telemetryLoopToken = TelemetryLoopToken()
    private var autoFallbackAttemptedURLs: Set<URL> = []
    private var autoFallbackAttemptedVariantIDs: Set<String> = []
    private var resumeToastTask: Task<Void, Never>?
    private var streamNoticeTask: Task<Void, Never>?
    private var pendingSeekSeconds: Double = 0
    private var thumbnailCapturedEntryIDs: Set<String> = []
    private var speedBeforeHold: Double = 1.0

    private static let auditTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init() {
        isLooping = !preferencesStore.continuousPlayback
        isAspectFill = preferencesStore.defaultAspectFill
        opticalFlowController.setEDREnabled(isEDREnabled)
        opticalFlowController.setAspectFill(isAspectFill)
        opticalFlowController.isLoopingEnabled = isLooping
        opticalFlowController.onRemoteAssetReady = { [weak self] asset, item in
            self?.subtitleManager.inspectRemoteAsset(asset, playerItem: item)
        }
        opticalFlowController.onLocalAssetReady = { [weak self] asset, url in
            self?.subtitleManager.inspectLocalAsset(asset, url: url)
        }
        opticalFlowController.onPlaybackFinished = { [weak self] in
            guard let self else { return }
            if !self.isLooping && self.hasNextEpisode {
                self.playNextEpisode()
            }
        }

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

        powerModeToken.observer = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLowPowerModeEnabled = lowPower
                self.opticalFlowController.syncDisplayLinkState()
            }
        }
    }

    func recordUISwitch(_ detail: String) {
        let stamp = Self.auditTimeFormatter.string(from: Date())
        uiAuditLogs.append("[\(stamp)] [ui-switch] \(detail)")
        if uiAuditLogs.count > 500 {
            uiAuditLogs.removeFirst(uiAuditLogs.count - 500)
        }
    }

    var activeVideoWidth: Int {
        opticalFlowController.videoWidth
    }

    var activeVideoHeight: Int {
        opticalFlowController.videoHeight
    }

    var isSuperResolutionDisabledBy4K: Bool {
        SuperResolutionPolicy.isAlready4K(width: activeVideoWidth, height: activeVideoHeight)
    }

    var superResolutionDisabledReason: String? {
        SuperResolutionPolicy.disabledReason(width: activeVideoWidth, height: activeVideoHeight)
    }

    var currentEnhancementSummary: String {
        guard interpolationMode == .vtOpticalFlow else {
            return "原帧率"
        }
        if vtSpatial2x && opticalFlowTargetFPS.allowsSpatial2x {
            return "\(opticalFlowTargetFPS.shortBadge) + 2×超分"
        }
        return opticalFlowTargetFPS.shortBadge
    }

    var hudMetrics: PlaybackHUDMetrics {
        let thermal = ThermalLevel(state: thermalState)
        let isInterp = (interpolationMode != .off)
        let backend = opticalFlowController.activeBackendLabel
        let engineBadge = PlaybackHUDMetrics.resolveEngineBadge(isInterpolationEnabled: isInterp, backendLabel: backend)
        let resModeBadge = PlaybackHUDMetrics.resolveResolutionModeBadge(isInterpolationEnabled: isInterp, backendLabel: backend)

        if !isInterp {
            return PlaybackHUDMetrics(
                engineBadge: engineBadge,
                interpolationBadge: "原帧率",
                codec: opticalFlowController.videoCodec,
                width: opticalFlowController.videoWidth,
                height: opticalFlowController.videoHeight,
                sourceFPS: opticalFlowController.sourceFPS,
                outputFPS: opticalFlowController.actualOutputFPS,
                bitDepth: opticalFlowController.bitDepthLabel,
                hdrTag: opticalFlowController.hdrLabel,
                isHDRActive: opticalFlowController.isHDRActive,
                decoderBadge: "硬解 VT直通",
                droppedFrames: opticalFlowController.droppedFrames,
                thermalLevel: thermal,
                resolutionModeBadge: resModeBadge,
                flowAvgMs: 0,
                renderAvgMs: opticalFlowController.averageQualityEnhanceMs,
                queueDepth: opticalFlowController.publishedQueueDepth,
                memoryMB: opticalFlowController.publishedMemoryMB,
                isStalled: opticalFlowController.isRemoteOutputStalled
            )
        }
        let targetBadge = opticalFlowController.targetSummaryBadge
        let interpBadge = opticalFlowController.enableSpatial2xUpscale
            ? "光流\(targetBadge)+超分2×"
            : "光流\(targetBadge)"
        let activeDecoderBadge = backend != "--"
            ? backend
            : "硬解 VT+ANE"
        return PlaybackHUDMetrics(
            engineBadge: engineBadge,
            interpolationBadge: interpBadge,
            codec: opticalFlowController.videoCodec,
            width: opticalFlowController.videoWidth,
            height: opticalFlowController.videoHeight,
            sourceFPS: opticalFlowController.sourceFPS,
            outputFPS: opticalFlowController.actualOutputFPS,
            bitDepth: opticalFlowController.bitDepthLabel,
            hdrTag: opticalFlowController.hdrLabel,
            isHDRActive: opticalFlowController.isHDRActive,
            decoderBadge: activeDecoderBadge,
            droppedFrames: opticalFlowController.droppedFrames,
            thermalLevel: thermal,
            resolutionModeBadge: resModeBadge,
            flowAvgMs: opticalFlowController.averageInterpolationMs,
            renderAvgMs: opticalFlowController.averageQualityEnhanceMs,
            queueDepth: opticalFlowController.publishedQueueDepth,
            memoryMB: opticalFlowController.publishedMemoryMB,
            isStalled: opticalFlowController.isRemoteOutputStalled
        )
    }

    func presentLocalVideoPicker() {
        opticalFlowController.clearError()
        opticalFlowController.appendLog("[file] 正在拉起系统原生文件选择器 (UIDocumentPickerViewController, asCopy=true)...")
        NativeDocumentPickerPresenter.shared.present(
            onPick: { [weak self] url in
                self?.open(url: url, isSecurityScoped: false)
            },
            onCancel: { [weak self] in
                self?.opticalFlowController.appendLog("[file] 用户取消了本地文件选择")
            },
            onError: { [weak self] message in
                self?.opticalFlowController.recordExternalError("无法打开本地文件选择器：\(message)")
            }
        )
    }

    func presentSubtitleFilePicker() {
        opticalFlowController.appendLog("[sub] 正在拉起系统文件选择器导入外挂字幕...")
        NativeDocumentPickerPresenter.shared.presentSubtitlePicker(
            onPick: { [weak self] url in
                self?.subtitleManager.loadExternalSubtitleFile(url: url)
            },
            onCancel: { [weak self] in
                self?.opticalFlowController.appendLog("[sub] 用户取消了外挂字幕选择")
            },
            onError: { [weak self] message in
                self?.opticalFlowController.appendLog("[sub][error] 打开字幕选择器失败：\(message)")
            }
        )
    }

    func open(url: URL, isSecurityScoped: Bool = false, seekTo: Double? = nil) {
        opticalFlowController.clearError()
        activeMediaRequest = nil
        currentStreamVariants = []
        autoFallbackAttemptedURLs.removeAll()
        autoFallbackAttemptedVariantIDs.removeAll()

        if !url.isFileURL {
            let entryID = WatchHistoryEntry.makeEntryID(sourceKind: .streamURL, streamURL: url)
            let resolvedSeek = seekTo ?? {
                if let hist = watchHistoryStore.entry(forID: entryID), !hist.isCompleted, hist.positionSeconds >= 5.0 {
                    return max(0, hist.positionSeconds - 2.0)
                }
                return 0
            }()
            beginPlayback(url: url, seekTo: resolvedSeek)
            return
        }

        isImportingFile = true
        opticalFlowController.appendLog("[file] 正在异步准备本地视频: \(url.lastPathComponent)")

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let playableURL = try await LocalMediaImporter.preparePlayableLocalURL(
                    from: url,
                    isSecurityScoped: isSecurityScoped
                )
                self.isImportingFile = false
                self.opticalFlowController.appendLog("[file] 本地视频已就绪: \(playableURL.lastPathComponent)")
                let resolvedSeek = seekTo ?? {
                    if let hist = self.watchHistoryStore.entry(forLocalURL: playableURL),
                       !hist.isCompleted,
                       hist.positionSeconds >= 5.0 {
                        return max(0, hist.positionSeconds - 2.0)
                    }
                    return 0
                }()
                self.beginPlayback(url: playableURL, seekTo: resolvedSeek)
            } catch {
                self.isImportingFile = false
                self.opticalFlowController.recordExternalError("无法读取本地视频（\(url.lastPathComponent)）：\(error.localizedDescription)")
            }
        }
    }

    func importFromPhotosItem(_ item: PhotosPickerItem) {
        guard !isImportingFile else { return }
        isImportingFile = true
        opticalFlowController.clearError()
        opticalFlowController.appendLog("[photos] 开始从系统相册导入视频...")

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let movie = try await item.loadTransferable(type: MovieFileTransferable.self) else {
                    self.isImportingFile = false
                    self.opticalFlowController.recordExternalError("未能从系统相册读取该视频（请确认 iCloud 原片已下载到本地）。")
                    return
                }
                self.isImportingFile = false
                self.opticalFlowController.appendLog("[photos] 相册视频已拷贝至沙盒: \(movie.url.lastPathComponent)")
                self.beginPlayback(url: movie.url)
            } catch {
                self.isImportingFile = false
                self.opticalFlowController.recordExternalError("相册视频导入失败：\(error.localizedDescription)")
            }
        }
    }

    static var persistedLastReportURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("glassmpv_last_session_report.txt")
    }

    var hasNextEpisode: Bool {
        guard let idx = activePlaylistIndex else { return false }
        return idx + 1 < activePlaylist.count
    }

    var hasPreviousEpisode: Bool {
        guard let idx = activePlaylistIndex else { return false }
        return idx > 0
    }

    var nextEpisodeItem: CloudMediaItem? {
        guard let idx = activePlaylistIndex, idx + 1 < activePlaylist.count else { return nil }
        return activePlaylist[idx + 1]
    }

    var activeFolderKey: String? {
        activeMediaRequest?.folderKey
    }

    var currentFolderIntroSeconds: Int {
        preferencesStore.introDuration(forFolderKey: activeFolderKey)
    }

    func skipIntro() {
        let target = Double(currentFolderIntroSeconds)
        guard target >= 5 else { return }
        let clamped = activeDuration > 1 ? min(target, max(0, activeDuration - 5)) : target
        recordUISwitch("skipIntro -> \(Int(clamped))s")
        seek(to: clamped)
    }

    func rememberCurrentPositionAsIntro() {
        guard let folderKey = activeFolderKey, activeCurrentTime >= 15 else { return }
        let rounded = Int(activeCurrentTime.rounded())
        preferencesStore.setIntroDuration(rounded, forFolderKey: folderKey)
        showStreamNotice("已记住本目录片头 \(WatchHistoryEntry.formatClock(Double(rounded)))")
        recordUISwitch("rememberIntro -> \(rounded)s for \(folderKey)")
    }

    func resetCurrentFolderIntro() {
        guard let folderKey = activeFolderKey else { return }
        preferencesStore.clearIntroDuration(forFolderKey: folderKey)
        showStreamNotice("已恢复默认片头时长")
    }

    func beginHoldFastForward() {
        guard !isHoldFastForwarding, currentURL != nil else { return }
        speedBeforeHold = speed
        isHoldFastForwarding = true
        opticalFlowController.setSpeed(2.0)
        recordUISwitch("holdFastForward -> 2.0x")
    }

    func endHoldFastForward() {
        guard isHoldFastForwarding else { return }
        isHoldFastForwarding = false
        opticalFlowController.setSpeed(speedBeforeHold)
    }

    func selectAudioTrack(at index: Int) {
        opticalFlowController.selectAudioTrack(at: index)
        recordUISwitch("selectAudioTrack(\(index))")
    }

    func playNextEpisode() {
        guard let idx = activePlaylistIndex, idx + 1 < activePlaylist.count else { return }
        playEpisode(at: idx + 1)
    }

    func playPreviousEpisode() {
        guard let idx = activePlaylistIndex, idx > 0 else { return }
        playEpisode(at: idx - 1)
    }

    func playEpisode(at index: Int, fromBeginning: Bool = false) {
        guard index >= 0 && index < activePlaylist.count,
              let accountID = activeMediaRequest?.accountID,
              let account = mediaSourceStore.accounts.first(where: { $0.id == accountID }) else {
            return
        }
        let targetItem = activePlaylist[index]
        let existingHistory = watchHistoryStore.entry(forCloudItemID: targetItem.id, accountID: accountID)
        let seekTarget: Double
        if !fromBeginning, let existingHistory, !existingHistory.isCompleted, existingHistory.positionSeconds >= 5.0 {
            seekTarget = max(0, existingHistory.positionSeconds - 2.0)
        } else {
            seekTarget = 0
        }

        let secret = mediaSourceStore.secret(for: account.id)
        let dirSubs = activeDirectorySubtitles
        let playlistSnapshot = activePlaylist
        let storeRef = mediaSourceStore
        isResolvingHistoryResume = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isResolvingHistoryResume = false }
            do {
                let resolved: ResolvedPlaybackStream
                switch account.kind {
                case .quark:
                    resolved = try await QuarkDriveClient.resolvePlaybackStream(
                        item: targetItem,
                        cookie: secret,
                        preferTranscode: false,
                        onCookieRefresh: { refreshed in
                            Task { @MainActor in
                                storeRef.addOrUpdate(account: account, secret: refreshed)
                            }
                        }
                    )
                case .emby:
                    guard let baseURL = EmbyClient.normalizedBaseURL(account.baseURL) else {
                        throw MediaSourceClientError.invalidURL("Emby 地址无效")
                    }
                    resolved = try EmbyClient.buildPlaybackStream(
                        item: targetItem,
                        baseURL: baseURL,
                        token: secret,
                        preferHLS: false
                    )
                case .webdav:
                    resolved = try WebDAVClient.buildPlaybackStream(
                        item: targetItem,
                        username: account.username,
                        password: secret
                    )
                }

                var subCandidates: [CloudSubtitleCandidate] = targetItem.embeddedSubtitleCandidates.map {
                    CloudSubtitleCandidate(
                        id: $0.id,
                        name: $0.name,
                        fileExtension: $0.fileExtension,
                        sourceKind: $0.sourceKind,
                        accountID: account.id,
                        directURL: $0.directURL,
                        headers: $0.headers,
                        embySubtitleStreamIndex: $0.embySubtitleStreamIndex,
                        mediaSourceId: $0.mediaSourceId,
                        itemId: $0.itemId
                    )
                }
                let videoStem = (targetItem.name as NSString).deletingPathExtension.lowercased()
                let authHeaders: [String: String]
                switch account.kind {
                case .quark: authHeaders = QuarkDriveClient.requestHeaders(cookie: secret)
                case .emby: authHeaders = EmbyClient.requestHeaders(token: secret)
                case .webdav:
                    if let auth = WebDAVClient.basicAuthHeader(username: account.username, password: secret) {
                        authHeaders = ["Authorization": auth]
                    } else {
                        authHeaders = [:]
                    }
                }
                let sortedSubs = dirSubs.sorted { lhs, rhs in
                    let lStem = (lhs.name as NSString).deletingPathExtension.lowercased()
                    let rStem = (rhs.name as NSString).deletingPathExtension.lowercased()
                    let lMatch = !videoStem.isEmpty && (lStem == videoStem || lStem.hasPrefix(videoStem) || videoStem.hasPrefix(lStem))
                    let rMatch = !videoStem.isEmpty && (rStem == videoStem || rStem.hasPrefix(videoStem) || videoStem.hasPrefix(rStem))
                    if lMatch != rMatch { return lMatch && !rMatch }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                for sub in sortedSubs {
                    subCandidates.append(
                        CloudSubtitleCandidate(
                            id: sub.id,
                            name: sub.name,
                            fileExtension: sub.fileExtension,
                            sourceKind: account.kind,
                            accountID: account.id,
                            directURL: sub.directURL,
                            headers: authHeaders
                        )
                    )
                }

                let req = PlaybackMediaRequest(
                    url: resolved.url,
                    headers: resolved.headers,
                    displayTitle: resolved.title,
                    sourceLabel: "\(account.kind.shortBadge) · \(resolved.qualityLabel)",
                    isHLS: resolved.isHLS,
                    alternatives: resolved.alternatives,
                    accountID: account.id,
                    cloudItem: targetItem,
                    subtitleCandidates: subCandidates,
                    playlist: playlistSnapshot,
                    playlistIndex: index,
                    directorySubtitles: dirSubs,
                    folderKey: self.activeMediaRequest?.folderKey
                )
                self.openCloudStream(req, seekTo: seekTarget)
            } catch {
                self.opticalFlowController.recordExternalError("切换选集《\(targetItem.name)》失败：\(error.localizedDescription)")
            }
        }
    }

    func openCloudStream(_ request: PlaybackMediaRequest, seekTo: Double = 0) {
        opticalFlowController.clearError()
        autoFallbackAttemptedURLs.removeAll()
        autoFallbackAttemptedVariantIDs.removeAll()
        activeMediaRequest = request
        currentStreamVariants = request.alternatives
        activePlaylist = request.playlist
        activePlaylistIndex = request.playlistIndex
        activeDirectorySubtitles = request.directorySubtitles
        recordUISwitch("openCloudStream(\(request.sourceLabel)) -> \(request.displayTitle)")
        beginPlayback(url: request.url, seekTo: seekTo)
        if !request.subtitleCandidates.isEmpty {
            let storeRef = mediaSourceStore
            subtitleManager.attachCloudCandidates(
                request.subtitleCandidates,
                preferredTitle: request.displayTitle
            ) { accountID in
                storeRef.secret(for: accountID)
            }
        }
    }

    func switchStreamVariant(_ variant: StreamVariantOption) {
        guard let currentReq = activeMediaRequest,
              (variant.url != currentURL || opticalFlowController.errorMessage != nil) else { return }
        let resumeTime = activeCurrentTime > 0 ? activeCurrentTime : pendingSeekSeconds
        if let accountID = currentReq.accountID,
           let account = mediaSourceStore.accounts.first(where: { $0.id == accountID }),
           account.kind == .quark,
           let item = currentReq.cloudItem {
            let secret = mediaSourceStore.secret(for: account.id)
            let storeRef = mediaSourceStore
            opticalFlowController.clearError()
            isResolvingHistoryResume = true
            recordUISwitch("switchStreamVariant(refresh quark) -> \(variant.label) (t=\(String(format: "%.1f", resumeTime))s)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.isResolvingHistoryResume = false }
                var targetVariant = variant
                if let resolved = try? await QuarkDriveClient.resolvePlaybackStream(
                    item: item,
                    cookie: secret,
                    preferTranscode: variant.id != "quark-original",
                    onCookieRefresh: { refreshed in
                        Task { @MainActor in
                            storeRef.addOrUpdate(account: account, secret: refreshed)
                        }
                    }
                ) {
                    self.currentStreamVariants = resolved.alternatives
                    if let refreshedMatch = resolved.alternatives.first(where: { $0.id == variant.id }) {
                        targetVariant = refreshedMatch
                    }
                }
                guard self.currentURL != nil, self.activeMediaRequest?.cloudItem?.id == item.id else {
                    return
                }
                self.applyStreamVariantSwitch(targetVariant, currentReq: currentReq, resumeTime: resumeTime)
            }
            return
        }
        recordUISwitch("switchStreamVariant -> \(variant.label) (t=\(String(format: "%.1f", resumeTime))s)")
        applyStreamVariantSwitch(variant, currentReq: currentReq, resumeTime: resumeTime)
    }

    private func applyStreamVariantSwitch(
        _ variant: StreamVariantOption,
        currentReq: PlaybackMediaRequest,
        resumeTime: Double
    ) {
        let updatedVariants = currentStreamVariants.isEmpty ? currentReq.alternatives : currentStreamVariants
        let updated = PlaybackMediaRequest(
            url: variant.url,
            headers: variant.headers,
            displayTitle: currentReq.displayTitle,
            sourceLabel: variant.label,
            isHLS: variant.isHLS,
            alternatives: updatedVariants,
            accountID: currentReq.accountID,
            cloudItem: currentReq.cloudItem,
            subtitleCandidates: currentReq.subtitleCandidates,
            playlist: currentReq.playlist,
            playlistIndex: currentReq.playlistIndex,
            directorySubtitles: currentReq.directorySubtitles,
            folderKey: currentReq.folderKey
        )
        activeMediaRequest = updated
        beginPlayback(url: updated.url, seekTo: resumeTime)
        if !updated.subtitleCandidates.isEmpty {
            let storeRef = mediaSourceStore
            subtitleManager.attachCloudCandidates(
                updated.subtitleCandidates,
                preferredTitle: updated.displayTitle
            ) { accountID in
                storeRef.secret(for: accountID)
            }
        }
    }

    func showStreamNotice(_ text: String) {
        streamNoticeTask?.cancel()
        streamNoticeText = text
        streamNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else { return }
            self?.streamNoticeText = nil
        }
    }

    func reResolveCurrentCloudStream(preferTranscode: Bool = false) {
        guard let req = activeMediaRequest,
              let accountID = req.accountID,
              let account = mediaSourceStore.accounts.first(where: { $0.id == accountID }),
              let item = req.cloudItem else {
            return
        }
        let resumeTime = activeCurrentTime > 0 ? activeCurrentTime : pendingSeekSeconds
        let secret = mediaSourceStore.secret(for: account.id)
        let storeRef = mediaSourceStore
        opticalFlowController.clearError()
        isResolvingHistoryResume = true
        recordUISwitch("reResolveCurrentCloudStream(\(item.name), preferTranscode=\(preferTranscode))")

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isResolvingHistoryResume = false }
            do {
                let resolved: ResolvedPlaybackStream
                switch account.kind {
                case .quark:
                    resolved = try await QuarkDriveClient.resolvePlaybackStream(
                        item: item,
                        cookie: secret,
                        preferTranscode: preferTranscode,
                        onCookieRefresh: { refreshed in
                            Task { @MainActor in
                                storeRef.addOrUpdate(account: account, secret: refreshed)
                            }
                        }
                    )
                case .emby:
                    guard let baseURL = EmbyClient.normalizedBaseURL(account.baseURL) else {
                        throw MediaSourceClientError.invalidURL("Emby 地址无效")
                    }
                    resolved = try EmbyClient.buildPlaybackStream(
                        item: item,
                        baseURL: baseURL,
                        token: secret,
                        preferHLS: preferTranscode
                    )
                case .webdav:
                    resolved = try WebDAVClient.buildPlaybackStream(
                        item: item,
                        username: account.username,
                        password: secret
                    )
                }

                let updated = PlaybackMediaRequest(
                    url: resolved.url,
                    headers: resolved.headers,
                    displayTitle: resolved.title,
                    sourceLabel: "\(account.kind.shortBadge) · \(resolved.qualityLabel)",
                    isHLS: resolved.isHLS,
                    alternatives: resolved.alternatives,
                    accountID: account.id,
                    cloudItem: item,
                    subtitleCandidates: req.subtitleCandidates,
                    playlist: req.playlist,
                    playlistIndex: req.playlistIndex,
                    directorySubtitles: req.directorySubtitles,
                    folderKey: req.folderKey
                )
                self.openCloudStream(updated, seekTo: resumeTime)
            } catch {
                self.opticalFlowController.recordExternalError("刷新片源直链失败：\(error.localizedDescription)")
            }
        }
    }

    func closeToHome() {
        if currentURL != nil {
            saveWatchProgressNow(forceThumbnail: true)
            captureRuntimeTelemetrySample()
            lastSessionSummary = buildCurrentSessionSummary()
            persistLastSessionReport()
        }
        recordUISwitch("closeToHome interp=\(interpolationMode.rawValue) target=\(opticalFlowTargetFPS.shortBadge)")
        stopRuntimeTelemetrySampling()
        resumeToastTask?.cancel()
        resumeToastText = nil
        streamNoticeTask?.cancel()
        streamNoticeText = nil
        pendingSeekSeconds = 0
        isHoldFastForwarding = false
        subtitleManager.resetForNewMedia()
        opticalFlowController.stop()
        currentURL = nil
        activeHistoryEntryID = nil
        activeMediaRequest = nil
        currentStreamVariants = []
        activePlaylist = []
        activePlaylistIndex = nil
        activeDirectorySubtitles = []
        autoFallbackAttemptedURLs.removeAll()
        autoFallbackAttemptedVariantIDs.removeAll()
        qualityCompareMode = .off
        isImportingFile = false
        OrientationController.shared.returnToHomeOrientation()
    }

    private func beginPlayback(url: URL, seekTo: Double = 0) {
        let enteringFromHome = (currentURL == nil)
        currentURL = url
        pendingSeekSeconds = max(0, seekTo)
        if enteringFromHome {
            runtimeTimeline.removeAll()
        }
        subtitleManager.resetForNewMedia()
        activeHistoryEntryID = resolveActiveHistoryEntryID(for: url)
        saveWatchProgressNow(overridePosition: seekTo)
        if seekTo >= 5.0 {
            showResumeToast(at: seekTo)
        } else {
            resumeToastTask?.cancel()
            resumeToastText = nil
        }
        if enteringFromHome {
            OrientationController.shared.enterVideoLandscape()
        }
        startPlayback(seekTo: seekTo)
        startRuntimeTelemetrySampling()
    }

    private func resolveActiveHistoryEntryID(for url: URL) -> String {
        if let req = activeMediaRequest, let item = req.cloudItem {
            let kind: WatchHistorySourceKind
            switch item.sourceKind {
            case .quark: kind = .quark
            case .emby: kind = .emby
            case .webdav: kind = .webdav
            }
            return WatchHistoryEntry.makeEntryID(
                sourceKind: kind,
                accountID: req.accountID,
                cloudItemID: item.id
            )
        }
        if url.isFileURL {
            return WatchHistoryEntry.makeEntryID(sourceKind: .local, localURL: url)
        }
        return WatchHistoryEntry.makeEntryID(sourceKind: .streamURL, streamURL: url)
    }

    private func showResumeToast(at seconds: Double) {
        resumeToastTask?.cancel()
        resumeToastText = "已从 \(WatchHistoryEntry.formatClock(seconds)) 续播"
        resumeToastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4.0))
            guard !Task.isCancelled else { return }
            self?.resumeToastText = nil
        }
    }

    func saveWatchProgressNow(overridePosition: Double? = nil, forceThumbnail: Bool = false) {
        guard let url = currentURL else { return }
        let entryID = activeHistoryEntryID ?? resolveActiveHistoryEntryID(for: url)
        activeHistoryEntryID = entryID
        let pos = overridePosition ?? activeCurrentTime
        let dur = activeDuration
        guard pos.isFinite else { return }

        if let req = activeMediaRequest {
            let kind: WatchHistorySourceKind
            switch req.cloudItem?.sourceKind {
            case .quark: kind = .quark
            case .emby: kind = .emby
            case .webdav: kind = .webdav
            case nil: kind = .streamURL
            }
            let badge = req.cloudItem?.sourceKind.shortBadge ?? req.sourceLabel
            watchHistoryStore.upsertProgress(
                id: entryID,
                title: req.displayTitle,
                subtitle: req.cloudItem?.subtitle ?? req.sourceLabel,
                sourceKind: kind,
                sourceBadge: badge,
                accountID: req.accountID,
                cloudItem: req.cloudItem,
                streamURL: req.cloudItem == nil ? req.url : nil,
                artworkURL: req.cloudItem?.artworkURL,
                positionSeconds: pos,
                durationSeconds: dur > 0 ? dur : (req.cloudItem?.durationSeconds ?? 0)
            )
        } else if url.isFileURL {
            let resText = (activeVideoWidth > 0 && activeVideoHeight > 0) ? "\(activeVideoWidth)×\(activeVideoHeight)" : "本地视频"
            watchHistoryStore.upsertProgress(
                id: entryID,
                title: url.lastPathComponent,
                subtitle: resText,
                sourceKind: .local,
                sourceBadge: "本地",
                localURL: url,
                positionSeconds: pos,
                durationSeconds: dur
            )
        } else {
            watchHistoryStore.upsertProgress(
                id: entryID,
                title: url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent,
                subtitle: url.host ?? "网络串流",
                sourceKind: .streamURL,
                sourceBadge: "网络流",
                streamURL: url,
                positionSeconds: pos,
                durationSeconds: dur
            )
        }

        if (forceThumbnail || pos >= 3.0) && !thumbnailCapturedEntryIDs.contains(entryID) {
            captureThumbnailIfNeeded(for: entryID)
        }
    }

    private func captureThumbnailIfNeeded(for entryID: String) {
        guard let pb = opticalFlowController.captureCurrentFrameForThumbnail() else { return }
        thumbnailCapturedEntryIDs.insert(entryID)
        let box = RemoteSendablePixelBuffer(buffer: pb)
        let storeRef = watchHistoryStore
        Task.detached(priority: .utility) {
            guard let jpegData = WatchHistoryStore.renderJPEGThumbnail(from: box.buffer) else { return }
            await MainActor.run {
                storeRef.saveThumbnailJPEG(jpegData, for: entryID)
            }
        }
    }

    func resumeFromHistory(_ entry: WatchHistoryEntry, fromBeginning: Bool = false) {
        let seekTarget = (fromBeginning || entry.isCompleted) ? 0 : max(0, entry.positionSeconds - 2.0)
        opticalFlowController.clearError()

        switch entry.sourceKind {
        case .local:
            guard let path = entry.localFilePath else {
                opticalFlowController.recordExternalError("该本地视频记录缺少文件路径，请重新从文件或相册打开。")
                return
            }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.isReadableFile(atPath: path) else {
                opticalFlowController.recordExternalError("本地文件《\(entry.title)》已不存在或不可读取。")
                return
            }
            open(url: url, isSecurityScoped: false, seekTo: seekTarget)

        case .streamURL:
            guard let urlStr = entry.streamURLString, let url = URL(string: urlStr) else {
                opticalFlowController.recordExternalError("该串流记录地址无效。")
                return
            }
            open(url: url, isSecurityScoped: false, seekTo: seekTarget)

        case .quark, .emby, .webdav:
            guard let accountID = entry.accountID,
                  let account = mediaSourceStore.accounts.first(where: { $0.id == accountID }),
                  let itemID = entry.cloudItemID else {
                opticalFlowController.recordExternalError("关联的云端片源账号已删除或凭证缺失，请重新挂载后播放。")
                return
            }
            let secret = mediaSourceStore.secret(for: account.id)
            let item = CloudMediaItem(
                id: itemID,
                name: entry.cloudItemName ?? entry.title,
                isDirectory: false,
                durationSeconds: entry.durationSeconds > 0 ? entry.durationSeconds : nil,
                fileExtension: entry.cloudItemExtension ?? (entry.title as NSString).pathExtension.lowercased(),
                subtitle: entry.subtitle,
                artworkURL: entry.artworkURLString.flatMap { URL(string: $0) },
                sourceKind: account.kind,
                mediaSourceId: entry.cloudMediaSourceID,
                container: entry.cloudContainer,
                directURL: account.kind == .webdav ? URL(string: itemID) : nil
            )
            isResolvingHistoryResume = true
            let storeRef = mediaSourceStore
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.isResolvingHistoryResume = false }
                do {
                    let resolved: ResolvedPlaybackStream
                    switch account.kind {
                    case .quark:
                        resolved = try await QuarkDriveClient.resolvePlaybackStream(
                            item: item,
                            cookie: secret,
                            preferTranscode: false,
                            onCookieRefresh: { refreshed in
                                Task { @MainActor in
                                    storeRef.addOrUpdate(account: account, secret: refreshed)
                                }
                            }
                        )
                    case .emby:
                        guard let baseURL = EmbyClient.normalizedBaseURL(account.baseURL) else {
                            throw MediaSourceClientError.invalidURL("Emby 地址无效")
                        }
                        resolved = try EmbyClient.buildPlaybackStream(
                            item: item,
                            baseURL: baseURL,
                            token: secret,
                            preferHLS: false
                        )
                    case .webdav:
                        resolved = try WebDAVClient.buildPlaybackStream(
                            item: item,
                            username: account.username,
                            password: secret
                        )
                    }
                    let req = PlaybackMediaRequest(
                        url: resolved.url,
                        headers: resolved.headers,
                        displayTitle: resolved.title,
                        sourceLabel: "\(account.kind.shortBadge) · \(resolved.qualityLabel)",
                        isHLS: resolved.isHLS,
                        alternatives: resolved.alternatives,
                        accountID: account.id,
                        cloudItem: item
                    )
                    self.openCloudStream(req, seekTo: seekTarget)
                } catch {
                    self.opticalFlowController.recordExternalError("续播《\(entry.title)》失败：\(error.localizedDescription)")
                }
            }
        }
    }

    var currentInterpolationVerdict: InterpolationVerdict {
        InterpolationVerdict.evaluateANE(
            isEnabled: interpolationMode == .vtOpticalFlow,
            interpolatedCount: opticalFlowController.interpolatedFrameCount,
            failedCount: opticalFlowController.failedInterpolationCount,
            presentedCount: opticalFlowController.presentedFrameCount,
            actualOutputFPS: opticalFlowController.actualOutputFPS,
            sourceFPS: opticalFlowController.sourceFPS,
            errorMessage: opticalFlowController.errorMessage ?? opticalFlowController.lastInterpolationError,
            targetLabel: opticalFlowController.targetSummaryBadge
        )
    }

    func startRuntimeTelemetrySampling() {
        telemetryLoopToken.task?.cancel()
        let loopTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, self.currentURL != nil else { break }
                self.captureRuntimeTelemetrySample()
            }
        }
        telemetryLoopToken.task = loopTask
    }

    func stopRuntimeTelemetrySampling() {
        telemetryLoopToken.task?.cancel()
        telemetryLoopToken.task = nil
    }

    func captureRuntimeTelemetrySample() {
        opticalFlowController.flushPublishedTelemetryIfNeeded(force: true)
        let verdict = currentInterpolationVerdict
        let metrics = hudMetrics
        let memMB = DeviceDiagnosticsSampler.currentMemoryFootprintMB()
        let sample = RuntimeTelemetrySample(
            playbackState: opticalFlowController.isPaused ? "已暂停" : "播放中",
            mediaTime: activeCurrentTime,
            width: metrics.width,
            height: metrics.height,
            sourceFPS: metrics.sourceFPS,
            outputFPS: metrics.outputFPS,
            droppedFrames: metrics.droppedFrames,
            aneInterpolated: opticalFlowController.interpolatedFrameCount,
            aneSkipped: opticalFlowController.skippedInterpolationCount,
            aneFailed: opticalFlowController.failedInterpolationCount,
            anePresented: opticalFlowController.presentedFrameCount,
            aneAvgMs: opticalFlowController.averageInterpolationMs,
            aneTargetFPS: interpolationMode == .vtOpticalFlow ? opticalFlowController.targetSummaryBadge : "原帧率",
            aneBackend: opticalFlowController.activeBackendLabel,
            aneQueueDepth: opticalFlowController.currentQueueDepthSnapshot(),
            avDeltaMs: opticalFlowController.latestAVDeltaMs,
            memoryFootprintMB: memMB,
            verdictLabel: verdict.shortLabel,
            thermalLevel: ThermalLevel(state: thermalState)
        )
        runtimeTimeline.append(sample)
        if runtimeTimeline.count > 500 {
            runtimeTimeline.removeFirst(runtimeTimeline.count - 500)
        }
        if currentURL != nil {
            lastSessionSummary = buildCurrentSessionSummary()
            if runtimeTimeline.count == 1 || runtimeTimeline.count % 3 == 0 {
                persistLastSessionReport()
                saveWatchProgressNow()
            }
        }
    }

    func persistLastSessionReport() {
        let content = exportDiagnosticReportText(includePersistedFallback: false)
        try? content.write(to: Self.persistedLastReportURL, atomically: true, encoding: .utf8)
    }

    func exportDiagnosticReportText(includePersistedFallback: Bool) -> String {
        if selfCheckReport.isEmpty {
            runRealDeviceSelfCheck()
        }
        let maxScreenFPS = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.maximumFramesPerSecond ?? 60
        let deviceInfo = DeviceDiagnosticsSampler.deviceSummaryLine(maxScreenFPS: maxScreenFPS)

        let summary: SessionDiagnosticSummary
        var extraTelemetry: [String] = []
        if currentURL != nil {
            summary = buildCurrentSessionSummary()
        } else if let cached = lastSessionSummary {
            summary = cached
            extraTelemetry.append("Snapshot Source: last-session (cached before closeToHome)")
        } else {
            summary = buildCurrentSessionSummary()
        }

        var report = DiagnosticLogExporter.buildReport(
            version: AppReleaseInfo.displayVersion,
            deviceInfo: deviceInfo,
            engineName: summary.engineName,
            playbackState: summary.playbackState,
            resolution: summary.resolution,
            fpsSummary: summary.fpsSummary,
            decoderSummary: summary.decoderSummary,
            is4KGated: summary.is4KGated,
            telemetrySummary: summary.telemetrySummary + extraTelemetry,
            runtimeTimeline: runtimeTimeline.map { $0.formatLogLine() },
            uiAuditLogs: uiAuditLogs,
            selfCheck: selfCheckReport,
            opticalLogs: opticalFlowController.diagnosticLogs
        )

        if includePersistedFallback,
           currentURL == nil,
           lastSessionSummary == nil,
           runtimeTimeline.isEmpty,
           let persisted = try? String(contentsOf: Self.persistedLastReportURL, encoding: .utf8),
           !persisted.isEmpty {
            report += "\n\n--- Previous Session Backup (Before Relaunch) ---\n\(persisted)"
        }
        return report
    }

    func buildCurrentSessionSummary() -> SessionDiagnosticSummary {
        let metrics = hudMetrics
        let resolution = (metrics.width > 0 && metrics.height > 0)
            ? "\(metrics.width)×\(metrics.height)"
            : "暂无"
        let stateText = opticalFlowController.isPaused ? "已暂停" : "播放中"
        let verdict = currentInterpolationVerdict
        let engineLabel = interpolationMode == .vtOpticalFlow ? "ANE 光流核" : "原生硬解直通"
        let telemetrySummary = [
            "Interpolation Verdict: \(verdict.shortLabel) | \(verdict.detailText)",
            "HDR/EDR: \(metrics.hdrTag) (edr=\(isEDREnabled ? "ON" : "OFF"), active=\(metrics.isHDRActive ? "YES" : "NO")) | Fill=\(isAspectFill ? "Fill" : "Fit") | Loop=\(isLooping ? "ON" : "OFF")",
            "ANE Target: \(opticalFlowController.targetSummaryBadge) (requested=\(opticalFlowController.requestedTargetFPS.shortBadge), effective=\(opticalFlowController.effectiveTargetFPS.shortBadge)) | ANE Backend: \(opticalFlowController.activeBackendLabel) | Clock: \(opticalFlowController.clockSourceLabel) | spatial2x=\(opticalFlowController.enableSpatial2xUpscale ? "ON" : "OFF")",
            "Quality Enhance: \(videoEnhancementPreset.rawValue) (\(videoEnhancementStrength.rawValue)) -> \(opticalFlowController.activeQualityPipelineLabel) | avgMs=\(String(format: "%.2f", opticalFlowController.averageQualityEnhanceMs))",
            "ANE Counters: interpolated=\(opticalFlowController.interpolatedFrameCount) | skipped=\(opticalFlowController.skippedInterpolationCount) | failed=\(opticalFlowController.failedInterpolationCount) | presented=\(opticalFlowController.presentedFrameCount) | avgMs=\(String(format: "%.1f", opticalFlowController.averageInterpolationMs)) | actualFPS=\(String(format: "%.1f", opticalFlowController.actualOutputFPS)) | queueDepth=\(opticalFlowController.currentQueueDepthSnapshot()) | avDelta=\(opticalFlowController.latestAVDeltaMs.map { String(format: "%+.1fms", $0) } ?? "--")"
        ]
        return SessionDiagnosticSummary(
            capturedAt: Date(),
            engineName: engineLabel,
            playbackState: stateText,
            resolution: resolution,
            fpsSummary: metrics.fpsSummary,
            decoderSummary: "\(metrics.codec) / \(metrics.decoderBadge)",
            is4KGated: isSuperResolutionDisabledBy4K,
            telemetrySummary: telemetrySummary,
            mediaFilename: currentURL?.lastPathComponent ?? ""
        )
    }

    func retryWithoutInterpolation() {
        let resumeTime = opticalFlowController.currentTime > 0 ? opticalFlowController.currentTime : pendingSeekSeconds
        interpolationMode = .off
        vtSpatial2x = false
        opticalFlowController.clearError()
        recordUISwitch("retryWithoutInterpolation -> 原帧率直通")
        if currentURL != nil {
            startPlayback(seekTo: resumeTime, autoPlay: true)
        }
    }

    func runRealDeviceSelfCheck() {
        let verdict = currentInterpolationVerdict
        let maxScreenFPS = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.maximumFramesPerSecond ?? 60

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

        let opticalStatus = "\(opticalFlowController.capabilityDescription) | 模式=\(interpolationMode.rawValue) | 画质=\(videoEnhancementPreset.rawValue)(\(opticalFlowController.activeQualityPipelineLabel)) | HDR=\(opticalFlowController.hdrLabel)(EDR=\(isEDREnabled ? "ON" : "OFF")) | 目标=\(opticalFlowController.targetSummaryBadge) | 后端=\(opticalFlowController.activeBackendLabel) | 时钟=\(opticalFlowController.clockSourceLabel) | 补帧=\(opticalFlowController.interpolatedFrameCount) | 跳帧追赶=\(opticalFlowController.skippedInterpolationCount) | 失败=\(opticalFlowController.failedInterpolationCount) | 送显=\(opticalFlowController.presentedFrameCount) | 平均耗时=\(String(format: "%.1f", opticalFlowController.averageInterpolationMs))ms | 实测FPS=\(String(format: "%.1f", opticalFlowController.actualOutputFPS)) | err=\(opticalFlowController.errorMessage ?? opticalFlowController.lastInterpolationError ?? "none")"

        let gateStatus = isSuperResolutionDisabledBy4K ? "已触发4K禁超分" : "允许2×空间超分"
        let lines = [
            "=== GlassMPV 运行状态摘要 ===",
            "版本: \(AppReleaseInfo.displayVersion) | 模式: \(interpolationMode.rawValue) | 4K超分门控: \(gateStatus) | 补帧判定: \(verdict.shortLabel) (\(verdict.detailText))",
            "1. 屏幕 ProMotion 上限: \(maxScreenFPS) Hz \(maxScreenFPS >= 120 ? "(PASS)" : "(非120Hz)")",
            "2. 本地/相册导入沙盒通道: \(importCheck)",
            "3. ANE 光流与硬解直通核: \(opticalStatus)",
            "4. 黑匣子采样: 共 \(runtimeTimeline.count) 条（最近判定=\(runtimeTimeline.last?.verdictLabel ?? "无")）"
        ]
        selfCheckReport = lines.joined(separator: "\n")
    }

    func selectFrameRateOption(_ target: OpticalFlowTargetFPS?) {
        guard let target else {
            setInterpolation(.off)
            return
        }
        if interpolationMode == .off {
            opticalFlowTargetFPS = target
            if !target.allowsSpatial2x && vtSpatial2x {
                vtSpatial2x = false
            }
            recordUISwitch("selectFrameRateOption(fromOff) -> \(target.shortBadge)")
            setInterpolation(.vtOpticalFlow)
        } else {
            setOpticalFlowTargetFPS(target)
        }
    }

    func setInterpolation(_ mode: InterpolationMode) {
        guard mode != interpolationMode else { return }
        let previousMode = interpolationMode
        let resumeTime = activeCurrentTime
        let wasPaused = activePaused
        if currentURL != nil {
            captureRuntimeTelemetrySample()
        }
        interpolationMode = mode
        if mode == .off {
            vtSpatial2x = false
        }
        recordUISwitch("setInterpolation \(previousMode.rawValue) -> \(mode.rawValue) (paused=\(wasPaused), t=\(String(format: "%.2f", resumeTime))s)")
        if currentURL != nil {
            if opticalFlowController.canHotToggleInterpolation {
                opticalFlowController.setRemoteInterpolationEnabled(mode == .vtOpticalFlow, targetFPS: opticalFlowTargetFPS)
                opticalFlowController.setSpeed(speed)
            } else {
                startPlayback(seekTo: resumeTime, autoPlay: !wasPaused)
            }
        }
    }

    func setOpticalFlowTargetFPS(_ target: OpticalFlowTargetFPS) {
        guard target != opticalFlowTargetFPS || opticalFlowController.effectiveTargetFPS != target else {
            return
        }
        let previousTarget = opticalFlowTargetFPS
        opticalFlowTargetFPS = target
        if !target.allowsSpatial2x && vtSpatial2x {
            vtSpatial2x = false
            opticalFlowController.appendLog("[ane] 切换至多相目标 \(target.shortBadge)，已自动关闭 ANE 2× 空间超分")
        }
        let wasPaused = opticalFlowController.isPaused
        recordUISwitch("setOpticalFlowTargetFPS \(previousTarget.shortBadge) -> \(target.shortBadge) (paused=\(wasPaused))")
        if interpolationMode == .vtOpticalFlow {
            opticalFlowController.updateTargetConfiguration(targetFPS: target, spatial2x: vtSpatial2x)
            opticalFlowController.setSpeed(speed)
        }
    }

    func setVTSpatial2x(_ enabled: Bool) {
        guard enabled != vtSpatial2x else { return }
        if enabled && !opticalFlowTargetFPS.allowsSpatial2x {
            vtSpatial2x = false
            opticalFlowController.appendLog("[ane] 目标帧率 \(opticalFlowTargetFPS.shortBadge) 需多相补帧，仅 2× 档位支持同步开启 ANE 2× 空间超分")
            recordUISwitch("setVTSpatial2x(true) 被多相档位(\(opticalFlowTargetFPS.shortBadge))互斥拦截")
            return
        }
        if enabled && isSuperResolutionDisabledBy4K {
            vtSpatial2x = false
            let reason = superResolutionDisabledReason ?? "片源已达 4K，自动禁用 ANE 2× 超分"
            opticalFlowController.appendLog("[ane] \(reason)")
            recordUISwitch("setVTSpatial2x(true) 被4K门控拦截")
            return
        }
        vtSpatial2x = enabled
        let wasPaused = opticalFlowController.isPaused
        recordUISwitch("setVTSpatial2x(\(enabled)) (paused=\(wasPaused))")
        if interpolationMode == .vtOpticalFlow {
            opticalFlowController.updateTargetConfiguration(targetFPS: opticalFlowTargetFPS, spatial2x: enabled)
            opticalFlowController.setSpeed(speed)
        }
    }

    func setEDREnabled(_ enabled: Bool) {
        guard enabled != isEDREnabled else { return }
        isEDREnabled = enabled
        recordUISwitch("setEDREnabled(\(enabled))")
        opticalFlowController.setEDREnabled(enabled)
    }

    func setAspectFill(_ enabled: Bool) {
        guard enabled != isAspectFill else { return }
        isAspectFill = enabled
        recordUISwitch("setAspectFill(\(enabled))")
        opticalFlowController.setAspectFill(enabled)
    }

    func setLooping(_ enabled: Bool) {
        guard enabled != isLooping else { return }
        isLooping = enabled
        recordUISwitch("setLooping(\(enabled))")
        opticalFlowController.isLoopingEnabled = enabled
    }

    func setSpeed(_ value: Double) {
        speed = value
        recordUISwitch("setSpeed(\(String(format: "%.2g", value))x)")
        opticalFlowController.setSpeed(value)
    }

    func setVideoEnhancementPreset(_ preset: VideoEnhancementPreset) {
        guard preset != videoEnhancementPreset else { return }
        let prev = videoEnhancementPreset
        videoEnhancementPreset = preset
        opticalFlowController.videoEnhancementPreset = preset
        if preset == .off {
            qualityCompareMode = .off
            opticalFlowController.qualityCompareMode = .off
            opticalFlowController.isComparingOriginalQuality = false
        }
        opticalFlowController.refreshDisplayedFrameForQualityChange()
        recordUISwitch("setVideoEnhancementPreset \(prev.rawValue) -> \(preset.rawValue)")
    }

    func setVideoEnhancementStrength(_ strength: VideoEnhancementStrength) {
        guard strength != videoEnhancementStrength else { return }
        let prev = videoEnhancementStrength
        videoEnhancementStrength = strength
        opticalFlowController.videoEnhancementStrength = strength
        opticalFlowController.refreshDisplayedFrameForQualityChange()
        recordUISwitch("setVideoEnhancementStrength \(prev.rawValue) -> \(strength.rawValue)")
    }

    func setQualityCompareMode(_ mode: VideoEnhancementCompareMode) {
        guard mode != qualityCompareMode else { return }
        let prev = qualityCompareMode
        qualityCompareMode = mode
        opticalFlowController.qualityCompareMode = mode
        opticalFlowController.isComparingOriginalQuality = (mode == .original)
        opticalFlowController.refreshDisplayedFrameForQualityChange()
        recordUISwitch("setQualityCompareMode \(prev.rawValue) -> \(mode.rawValue)")
    }

    func setComparingOriginalQuality(_ comparing: Bool) {
        setQualityCompareMode(comparing ? .original : .off)
    }

    func togglePlayPause() {
        let nextState = activePaused ? "play" : "pause"
        recordUISwitch("togglePlayPause(\(nextState))")
        opticalFlowController.togglePlayPause()
        if opticalFlowController.isPaused {
            saveWatchProgressNow()
        }
    }

    func seek(to seconds: Double) {
        opticalFlowController.seek(to: seconds)
    }

    func seekRelative(_ delta: Double) {
        opticalFlowController.seekRelative(delta)
    }

    var activeCurrentTime: Double {
        opticalFlowController.currentTime
    }

    var activeDuration: Double {
        opticalFlowController.duration
    }

    var activePaused: Bool {
        opticalFlowController.isPaused
    }

    private func startPlayback(seekTo: Double = 0, autoPlay: Bool = true) {
        guard let url = currentURL else { return }
        opticalFlowController.setEDREnabled(isEDREnabled)
        opticalFlowController.setAspectFill(isAspectFill)
        opticalFlowController.isLoopingEnabled = isLooping
        opticalFlowController.onRemoteAssetReady = { [weak self] asset, item in
            self?.subtitleManager.inspectRemoteAsset(asset, playerItem: item)
        }
        opticalFlowController.onLocalAssetReady = { [weak self] asset, url in
            self?.subtitleManager.inspectLocalAsset(asset, url: url)
        }
        opticalFlowController.onPlaybackFinished = { [weak self] in
            guard let self else { return }
            if !self.isLooping && self.hasNextEpisode {
                self.playNextEpisode()
            }
        }
        if let accountID = activeMediaRequest?.accountID,
           let matchedAccount = mediaSourceStore.accounts.first(where: { $0.id == accountID }) {
            let storeRef = mediaSourceStore
            opticalFlowController.onRemoteCookieRefresh = { refreshedCookie in
                Task { @MainActor in
                    storeRef.addOrUpdate(account: matchedAccount, secret: refreshedCookie)
                }
            }
        } else {
            opticalFlowController.onRemoteCookieRefresh = nil
        }
        opticalFlowController.onRemoteVideoTrackUnplayable = { [weak self] reason in
            guard let self else { return }
            if let current = self.currentURL {
                self.autoFallbackAttemptedURLs.insert(current)
                if let currentID = self.currentStreamVariants.first(where: { $0.url == current })?.id {
                    self.autoFallbackAttemptedVariantIDs.insert(currentID)
                }
            }
            let candidates = self.currentStreamVariants.filter {
                $0.url != self.currentURL
                    && !self.autoFallbackAttemptedURLs.contains($0.url)
                    && !self.autoFallbackAttemptedVariantIDs.contains($0.id)
            }
            if let fallback = candidates.first(where: { !$0.isHLS && $0.id != "quark-original" })
                ?? candidates.first(where: \.isHLS)
                ?? candidates.first {
                self.opticalFlowController.appendLog("[remote][fallback] \(reason)，自动切流 -> \(fallback.label)")
                self.showStreamNotice("已自动切换至 \(fallback.label)")
                self.switchStreamVariant(fallback)
            } else {
                self.opticalFlowController.recordExternalError("\(reason)。请点击底部「画质流」切换为「夸克 4K / 1080P」，或长按列表中的「缓存到本地离线精播」。")
            }
        }
        opticalFlowController.onRemoteStreamFailed = { [weak self] detail in
            guard let self else { return false }
            let failedVariant = self.currentStreamVariants.first { $0.url == self.currentURL }
            let failedWasHLS = (failedVariant?.isHLS == true) || (self.activeMediaRequest?.isHLS == true)
            if let current = self.currentURL {
                self.autoFallbackAttemptedURLs.insert(current)
                if let currentID = failedVariant?.id {
                    self.autoFallbackAttemptedVariantIDs.insert(currentID)
                }
            }
            let candidates = self.currentStreamVariants.filter {
                $0.url != self.currentURL
                    && !self.autoFallbackAttemptedURLs.contains($0.url)
                    && !self.autoFallbackAttemptedVariantIDs.contains($0.id)
            }
            let fallback: StreamVariantOption?
            if failedWasHLS {
                fallback = candidates.first(where: { !$0.isHLS && $0.id != "quark-original" }) ?? candidates.first
            } else {
                fallback = candidates.first(where: { !$0.isHLS && $0.id != "quark-original" })
                    ?? candidates.first(where: \.isHLS)
                    ?? candidates.first
            }
            if let fallback {
                self.opticalFlowController.appendLog("[remote][fallback] 主流加载失败（\(detail)），自动切流 -> \(fallback.label)")
                self.showStreamNotice("主流超时/失败，已自动切换至 \(fallback.label)")
                self.switchStreamVariant(fallback)
                return true
            }
            return false
        }
        let enableInterp = (interpolationMode == .vtOpticalFlow)
        opticalFlowController.load(
            url: url,
            spatial2x: enableInterp && vtSpatial2x,
            targetFPS: opticalFlowTargetFPS,
            startAt: seekTo,
            autoPlay: autoPlay,
            enableInterpolation: enableInterp,
            httpHeaders: activeMediaRequest?.headers ?? [:],
            displayTitle: activeMediaRequest?.displayTitle,
            streamLabel: activeMediaRequest?.sourceLabel ?? "",
            isHLS: activeMediaRequest?.isHLS ?? false
        )
        opticalFlowController.setSpeed(speed)
    }
}

// MARK: - Smart Source-Adaptive Frame-Rate Preset Strip

struct FrameRatePresetStrip: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject var optical: OpticalFlowPlayerController
    var compact: Bool = false
    var onSelectPreset: () -> Void = {}

    var body: some View {
        let presets = OpticalFlowTargetFPS.smartPresets(forSourceFPS: optical.sourceFPS)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: compact ? 8 : 10) {
                ForEach(presets) { preset in
                    let isSelected: Bool = {
                        if let target = preset.target {
                            return coordinator.interpolationMode == .vtOpticalFlow && coordinator.opticalFlowTargetFPS == target
                        }
                        return coordinator.interpolationMode == .off
                    }()
                    let isEffectiveLower = isSelected
                        && preset.target != nil
                        && coordinator.currentURL != nil
                        && optical.effectiveTargetFPS != preset.target
                    let titleText = isEffectiveLower
                        ? "\(preset.primaryTitle)→\(Int(optical.effectiveTargetFPS.effectiveTargetFPS(sourceFPS: optical.sourceFPS).rounded()))"
                        : preset.primaryTitle
                    let subtitleText = isEffectiveLower
                        ? "已自动稳帧"
                        : preset.subtitle

                    presetCardButton(
                        title: titleText,
                        subtitle: subtitleText,
                        isSelected: isSelected,
                        accent: preset.target == nil ? .white : .cyan
                    ) {
                        coordinator.selectFrameRateOption(preset.target)
                        onSelectPreset()
                    }
                }

                if coordinator.interpolationMode == .vtOpticalFlow
                    && coordinator.opticalFlowTargetFPS.allowsSpatial2x
                    && !coordinator.isSuperResolutionDisabledBy4K {
                    presetCardButton(
                        title: "2× 超分",
                        subtitle: coordinator.vtSpatial2x ? "已开启" : "ANE 细节",
                        isSelected: coordinator.vtSpatial2x,
                        accent: .indigo
                    ) {
                        coordinator.setVTSpatial2x(!coordinator.vtSpatial2x)
                        onSelectPreset()
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func presetCardButton(
        title: String,
        subtitle: String,
        isSelected: Bool,
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: compact ? 13 : 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(subtitle)
                    .font(.system(size: compact ? 9.5 : 10.5, weight: .medium))
                    .opacity(isSelected ? 0.85 : 0.72)
            }
            .foregroundStyle(isSelected ? .black : .white.opacity(0.92))
            .padding(.horizontal, compact ? 12 : 14)
            .padding(.vertical, compact ? 7 : 9)
            .background(
                RoundedRectangle(cornerRadius: compact ? 13 : 15, style: .continuous)
                    .fill(isSelected ? accent : Color.white.opacity(0.11))
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 13 : 15, style: .continuous)
                    .strokeBorder(isSelected ? accent.opacity(0.9) : Color.white.opacity(0.16), lineWidth: 0.7)
            )
            .contentShape(RoundedRectangle(cornerRadius: compact ? 13 : 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: compact ? 13 : 15, style: .continuous))
    }
}

// MARK: - Quality Enhancement Preset & Comparison Strip

struct QualityPresetStrip: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject var optical: OpticalFlowPlayerController
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: compact ? 8 : 10) {
                    ForEach(VideoEnhancementPreset.allCases) { preset in
                        let isSelected = (coordinator.videoEnhancementPreset == preset)
                        Button {
                            coordinator.setVideoEnhancementPreset(preset)
                        } label: {
                            VStack(spacing: 2) {
                                Text(preset.rawValue)
                                    .font(.system(size: compact ? 13 : 14, weight: .bold, design: .rounded))
                                Text(preset.subtitle)
                                    .font(.system(size: compact ? 9.5 : 10.5, weight: .medium))
                                    .opacity(isSelected ? 0.85 : 0.72)
                            }
                            .foregroundStyle(isSelected ? .black : .white.opacity(0.92))
                            .padding(.horizontal, compact ? 12 : 14)
                            .padding(.vertical, compact ? 7 : 9)
                            .background(
                                RoundedRectangle(cornerRadius: compact ? 13 : 15, style: .continuous)
                                    .fill(isSelected ? (preset == .off ? .white : .purple.opacity(0.95)) : Color.white.opacity(0.11))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: compact ? 13 : 15, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? (preset == .off ? Color.white.opacity(0.9) : Color.purple.opacity(0.9)) : Color.white.opacity(0.16),
                                        lineWidth: 0.7
                                    )
                            )
                            .contentShape(RoundedRectangle(cornerRadius: compact ? 13 : 15, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            if coordinator.videoEnhancementPreset != .off {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(VideoEnhancementStrength.allCases) { strength in
                            let selected = (coordinator.videoEnhancementStrength == strength)
                            Button {
                                coordinator.setVideoEnhancementStrength(strength)
                            } label: {
                                Text(strength.rawValue)
                                    .font(.caption2.weight(selected ? .bold : .medium))
                                    .foregroundStyle(selected ? .black : .white.opacity(0.85))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule().fill(selected ? Color.cyan : Color.white.opacity(0.12))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer(minLength: 4)

                    if coordinator.currentURL != nil {
                        HStack(spacing: 6) {
                            let isSplit = (coordinator.qualityCompareMode == .split)
                            Button {
                                coordinator.setQualityCompareMode(isSplit ? .off : .split)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "rectangle.split.2x1")
                                        .font(.caption2.weight(.semibold))
                                    Text(isSplit ? "分屏中" : "分屏对比")
                                        .font(.caption2.weight(.semibold))
                                }
                                .foregroundStyle(isSplit ? .black : .white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule().fill(isSplit ? Color.cyan : Color.white.opacity(0.16))
                                )
                            }
                            .buttonStyle(.plain)

                            let isOriginal = (coordinator.qualityCompareMode == .original)
                            Button {
                                coordinator.setQualityCompareMode(isOriginal ? .off : .original)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "eye")
                                        .font(.caption2.weight(.semibold))
                                    Text(isOriginal ? "原画中" : "对比原画")
                                        .font(.caption2.weight(.semibold))
                                }
                                .foregroundStyle(isOriginal ? .black : .white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule().fill(isOriginal ? Color.yellow : Color.white.opacity(0.16))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

struct LiquidGlassPlayerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject private var optical: OpticalFlowPlayerController
    @ObservedObject private var mediaSourceStore: MediaSourceStore
    @ObservedObject private var subtitleManager: SubtitleManager
    @ObservedObject private var watchHistoryStore: WatchHistoryStore
    @ObservedObject private var preferencesStore: UserPreferencesStore

    @State private var showHUD: Bool = true
    @State private var showStatsHUD: Bool = false
    @State private var showFPSPicker: Bool = false
    @State private var showQualityPicker: Bool = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showURLPrompt: Bool = false
    @State private var streamURLInput: String = ""
    @State private var showEnhancementSheet: Bool = false
    @State private var showSubtitleSheet: Bool = false
    @State private var showPlaylistSheet: Bool = false
    @State private var showHistorySheet: Bool = false
    @State private var showChangelogSheet: Bool = false
    @State private var showDiagnosticSheet: Bool = false
    @State private var showAddMediaSourceSheet: Bool = false
    @State private var showUnifiedSettingsSheet: Bool = false
    @State private var unifiedSettingsInitialTab: PlayerSettingsTab = .video
    @State private var dismissedSkipIntro: Bool = false
    @State private var dismissedUpNext: Bool = false
    @State private var isScrubbing: Bool = false
    @State private var scrubTime: Double = 0
    @State private var isScreenLocked: Bool = false
    @State private var showUnlockPill: Bool = false
    @State private var showRemainingTime: Bool = true
    @State private var gestureFeedback: PlayerGestureFeedbackState = .none
    @State private var skipAccumulatedSeconds: Int = 0
    @State private var skipIsRight: Bool = true
    @State private var hudAutoHideTask: Task<Void, Never>?
    @State private var fpsAutoCloseTask: Task<Void, Never>?
    @State private var gestureFeedbackTask: Task<Void, Never>?
    @State private var unlockPillTask: Task<Void, Never>?

    init(coordinator: PlayerCoordinator) {
        self.coordinator = coordinator
        self._optical = ObservedObject(wrappedValue: coordinator.opticalFlowController)
        self._mediaSourceStore = ObservedObject(wrappedValue: coordinator.mediaSourceStore)
        self._subtitleManager = ObservedObject(wrappedValue: coordinator.subtitleManager)
        self._watchHistoryStore = ObservedObject(wrappedValue: coordinator.watchHistoryStore)
        self._preferencesStore = ObservedObject(wrappedValue: coordinator.preferencesStore)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if coordinator.currentURL != nil {
                OpticalFlowVideoSurface(controller: optical)
                    .ignoresSafeArea()

                PlayerGestureOverlay(
                    isLocked: isScreenLocked,
                    isGesturesEnabled: preferencesStore.gesturesEnabled,
                    skipIntervalSeconds: preferencesStore.skipIntervalSeconds,
                    isAspectFill: coordinator.isAspectFill,
                    currentTime: coordinator.activeCurrentTime,
                    duration: coordinator.activeDuration,
                    onSingleTap: {
                        if isScreenLocked {
                            triggerUnlockPill()
                            return
                        }
                        if showFPSPicker || showQualityPicker {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                showFPSPicker = false
                                showQualityPicker = false
                            }
                            fpsAutoCloseTask?.cancel()
                            scheduleHUDAutoHide()
                            return
                        }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showHUD.toggle()
                        }
                        if showHUD {
                            scheduleHUDAutoHide()
                        } else {
                            hudAutoHideTask?.cancel()
                        }
                    },
                    onTogglePlayPause: {
                        coordinator.togglePlayPause()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showHUD = true
                        }
                        if coordinator.activePaused {
                            hudAutoHideTask?.cancel()
                        } else {
                            scheduleHUDAutoHide()
                        }
                    },
                    onDoubleTapSkip: { delta in
                        coordinator.seekRelative(delta)
                        triggerSkipFeedback(delta: Int(delta))
                    },
                    onHoldSpeedChanged: { active in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if active {
                                coordinator.beginHoldFastForward()
                            } else {
                                coordinator.endHoldFastForward()
                            }
                        }
                    },
                    onScrubChanged: { target, delta in
                        isScrubbing = true
                        scrubTime = target
                        hudAutoHideTask?.cancel()
                        gestureFeedback = .scrub(target: target, duration: coordinator.activeDuration, delta: delta)
                    },
                    onScrubEnded: { target in
                        isScrubbing = false
                        coordinator.seek(to: target)
                        gestureFeedback = .none
                        scheduleHUDAutoHide()
                    },
                    onBrightnessChanged: { level in
                        if level < 0 {
                            scheduleGestureFeedbackClear()
                        } else {
                            gestureFeedbackTask?.cancel()
                            gestureFeedback = .brightness(level)
                        }
                    },
                    onVolumeChanged: { level in
                        if level < 0 {
                            scheduleGestureFeedbackClear()
                        } else {
                            gestureFeedbackTask?.cancel()
                            gestureFeedback = .volume(level)
                        }
                    },
                    onPinchZoomChanged: { targetFill in
                        coordinator.setAspectFill(targetFill)
                        gestureFeedbackTask?.cancel()
                        withAnimation(.easeOut(duration: 0.15)) {
                            gestureFeedback = .zoom(isFill: targetFill)
                        }
                        scheduleGestureFeedbackClear(delay: 0.9)
                    }
                )
                .ignoresSafeArea()
            }

            if coordinator.currentURL == nil {
                InfuseHomeShellView(
                    coordinator: coordinator,
                    showURLPrompt: $showURLPrompt,
                    showAddMediaSourceSheet: $showAddMediaSourceSheet,
                    showHistorySheet: $showHistorySheet,
                    showEnhancementSheet: $showEnhancementSheet,
                    showDiagnosticSheet: $showDiagnosticSheet,
                    showChangelogSheet: $showChangelogSheet
                ) {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .videos, photoLibrary: .shared()) {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.title3)
                                .foregroundStyle(.indigo)
                            Text("系统相册")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
                }
            } else {
                if optical.qualityCompareMode != .off {
                    VStack {
                        Button {
                            coordinator.setQualityCompareMode(.off)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: optical.qualityCompareMode == .split ? "rectangle.split.2x1" : "eye")
                                Text(optical.qualityCompareMode == .split ? "左 原画 ｜ 右 增强 · 点击退出分屏" : "全屏原画对比中 · 点击恢复增强")
                            }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(optical.qualityCompareMode == .split ? Color.cyan : Color.yellow))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 14)
                        Spacer()
                    }
                }
                if subtitleManager.isEnabled, subtitleManager.selectedTrackID != nil {
                    SubtitleOverlayView(
                        subtitleManager: subtitleManager,
                        optical: optical,
                        bottomInset: (showHUD && !isScreenLocked) ? 108.0 : 0.0
                    )
                    .allowsHitTesting(false)
                }

                PlayerGestureFeedbackOverlay(
                    feedback: gestureFeedback,
                    isHoldFastForwarding: coordinator.isHoldFastForwarding
                )

                let topBannerOffset = PlayerOverlayLayoutPolicy.topBannerPaddingTop(
                    showHUD: showHUD,
                    showStatsHUD: showStatsHUD
                )
                if let notice = coordinator.streamNoticeText, coordinator.resumeToastText == nil {
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.cyan)
                            Text(notice)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.78)))
                        .overlay(Capsule().strokeBorder(Color.cyan.opacity(0.35), lineWidth: 0.8))
                        .padding(.top, topBannerOffset)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let toast = coordinator.resumeToastText, optical.presentedFrameCount > 0 {
                    VStack {
                        HStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.cyan)
                            Text(toast)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                            Button("从头播放") {
                                coordinator.seek(to: 0)
                                coordinator.resumeToastText = nil
                            }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.cyan)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
                        .padding(.top, topBannerOffset)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
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
                    .padding(.top, showHUD ? 60 : 14)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.2), value: showHUD)
                    .transition(.opacity)
                }

                if isScreenLocked {
                    if showUnlockPill {
                        HStack {
                            Button {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                    isScreenLocked = false
                                    showUnlockPill = false
                                    showHUD = true
                                }
                                unlockPillTask?.cancel()
                                scheduleHUDAutoHide()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "lock.open.fill")
                                        .font(.caption.weight(.bold))
                                    Text("点击解锁")
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(Capsule().fill(Color.cyan))
                                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 18)
                            Spacer()
                        }
                        .transition(.opacity)
                    }
                } else {
                    if showHUD {
                        playerHUDOverlay
                            .transition(.opacity)
                    }

                    skipIntroOverlayCard
                    upNextEpisodeOverlayCard
                }
            }

            if let loadingMessage = PlayerOverlayLayoutPolicy.activeCenterLoadingMessage(
                isImportingFile: coordinator.isImportingFile,
                isResolvingHistoryResume: coordinator.isResolvingHistoryResume,
                hasActiveURL: coordinator.currentURL != nil,
                hasError: optical.errorMessage != nil,
                isLoadingPipeline: optical.isLoadingPipeline,
                presentedFrameCount: optical.presentedFrameCount,
                pipelineStatusText: optical.pipelineStatusText
            ) {
                loadingStatusPill(loadingMessage)
            }

            if let error = optical.errorMessage {
                playbackErrorBanner(error)
            }
        }
        .onAppear {
            showStatsHUD = preferencesStore.showDeveloperHUD
        }
        .onChange(of: preferencesStore.showDeveloperHUD) { _, val in
            showStatsHUD = val
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            selectedPhotoItem = nil
            coordinator.importFromPhotosItem(newItem)
        }
        .onChange(of: coordinator.currentURL) { _, newURL in
            if newURL != nil {
                isScreenLocked = false
                showUnlockPill = false
                dismissedSkipIntro = false
                dismissedUpNext = false
                gestureFeedback = .none
                showHUD = true
                scheduleHUDAutoHide()
            } else {
                isScreenLocked = false
                showUnlockPill = false
                dismissedSkipIntro = false
                dismissedUpNext = false
                gestureFeedback = .none
                hudAutoHideTask?.cancel()
            }
        }
        .onChange(of: optical.isPaused) { _, paused in
            if paused {
                hudAutoHideTask?.cancel()
                if !isScreenLocked {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showHUD = true
                    }
                }
            } else if showHUD {
                scheduleHUDAutoHide()
            }
        }
        .onChange(of: showEnhancementSheet) { _, presented in
            if !presented && showHUD {
                scheduleHUDAutoHide()
            }
        }
        .onChange(of: showDiagnosticSheet) { _, presented in
            if !presented && showHUD {
                scheduleHUDAutoHide()
            }
        }
        .onChange(of: showSubtitleSheet) { _, presented in
            if !presented && showHUD {
                scheduleHUDAutoHide()
            }
        }
        .onChange(of: showPlaylistSheet) { _, presented in
            if !presented && showHUD {
                scheduleHUDAutoHide()
            }
        }
        .onChange(of: showUnifiedSettingsSheet) { _, presented in
            if !presented && showHUD {
                scheduleHUDAutoHide()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background && coordinator.currentURL != nil {
                coordinator.saveWatchProgressNow(forceThumbnail: true)
            }
        }
        .alert("打开网络视频流", isPresented: $showURLPrompt) {
            TextField("https:// 视频地址", text: $streamURLInput)
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
            DiagnosticLogSheet(coordinator: coordinator)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showAddMediaSourceSheet) {
            AddMediaSourceSheet(store: mediaSourceStore)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showSubtitleSheet) {
            SubtitleControlSheet(coordinator: coordinator)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showPlaylistSheet) {
            EpisodePlaylistSheet(coordinator: coordinator)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showHistorySheet) {
            WatchHistorySheet(coordinator: coordinator)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showUnifiedSettingsSheet) {
            PlayerUnifiedSettingsSheet(
                coordinator: coordinator,
                initialTab: unifiedSettingsInitialTab
            ) {
                showDiagnosticSheet = true
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.ultraThinMaterial)
        }
    }

    private func scheduleHUDAutoHide() {
        hudAutoHideTask?.cancel()
        guard coordinator.currentURL != nil,
              !isScreenLocked,
              !coordinator.activePaused,
              !isScrubbing,
              !showFPSPicker,
              !showQualityPicker,
              !showEnhancementSheet,
              !showSubtitleSheet,
              !showPlaylistSheet,
              !showUnifiedSettingsSheet,
              !showDiagnosticSheet else {
            return
        }
        hudAutoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled,
                  coordinator.currentURL != nil,
                  !isScreenLocked,
                  !coordinator.activePaused,
                  !isScrubbing,
                  !showFPSPicker,
                  !showQualityPicker,
                  !showEnhancementSheet,
                  !showSubtitleSheet,
                  !showPlaylistSheet,
                  !showUnifiedSettingsSheet,
                  !showDiagnosticSheet else {
                return
            }
            withAnimation(.easeInOut(duration: 0.25)) {
                showHUD = false
            }
        }
    }

    private func triggerUnlockPill() {
        unlockPillTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            showUnlockPill = true
        }
        unlockPillTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                showUnlockPill = false
            }
        }
    }

    private func triggerSkipFeedback(delta: Int) {
        let isRight = delta >= 0
        if case .skip = gestureFeedback, skipIsRight == isRight {
            skipAccumulatedSeconds += delta
        } else {
            skipAccumulatedSeconds = delta
            skipIsRight = isRight
        }
        withAnimation(.easeOut(duration: 0.12)) {
            gestureFeedback = .skip(seconds: skipAccumulatedSeconds, isRight: isRight)
        }
        scheduleGestureFeedbackClear(delay: 0.75)
    }

    private func scheduleGestureFeedbackClear(delay: Double = 0.6) {
        gestureFeedbackTask?.cancel()
        gestureFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                gestureFeedback = .none
            }
            skipAccumulatedSeconds = 0
        }
    }

    private func scheduleFPSPickerAutoClose() {
        fpsAutoCloseTask?.cancel()
        fpsAutoCloseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.65))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                showFPSPicker = false
            }
            scheduleHUDAutoHide()
        }
    }

    // MARK: - Minimalist Infuse 8 Floating Player HUD

    private var usesLightweightHighFPSHUD: Bool {
        optical.isInterpolationEnabled
            && !optical.isPaused
            && (optical.effectiveTargetFPS == .fps96 || optical.effectiveTargetFPS == .fps120)
    }

    @ViewBuilder
    private func hudPanelSurface<Content: View>(
        cornerRadius: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if usesLightweightHighFPSHUD {
            content()
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.72))
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.24), Color.white.opacity(0.08)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.8
                                )
                        )
                )
        } else {
            content()
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }

    private var playerHUDOverlay: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.70), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 120)

                Spacer()

                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 150)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack {
                // 顶栏：关闭 + 片名/元数据 + 屏幕工具 + 可选开发者角标
                HStack(spacing: 10) {
                    Button {
                        coordinator.closeToHome()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Color.black.opacity(0.42), in: Circle())
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.7))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(optical.displayTitle.isEmpty ? (coordinator.currentURL?.lastPathComponent ?? "GlassMPV") : optical.displayTitle)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            if !optical.activeStreamLabel.isEmpty {
                                Text(optical.activeStreamLabel)
                            }
                            if coordinator.activeVideoWidth > 0 {
                                Text("· \(activeResolutionText)")
                            }
                            if optical.hdrLabel != "SDR" {
                                Text("· \(optical.hdrLabel)")
                                    .foregroundStyle(optical.isHDRActive ? .yellow : .orange)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    toolbarActionButtons
                    if preferencesStore.showDeveloperHUD {
                        topRightMetricsBadge
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                VStack(spacing: 8) {
                    if showQualityPicker {
                        hudPanelSurface(cornerRadius: 20) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(
                                        optical.isDolbyVisionContent
                                            ? "杜比视界原片自动保留原厂映射"
                                            : "Metal + MetalFX 实时画质增强（\(optical.activeQualityPipelineLabel)）",
                                        systemImage: "wand.and.stars"
                                    )
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(optical.isDolbyVisionContent ? .yellow : .secondary)
                                    Spacer()
                                    Button {
                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                            showQualityPicker = false
                                        }
                                        scheduleHUDAutoHide()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }

                                QualityPresetStrip(
                                    coordinator: coordinator,
                                    optical: optical,
                                    compact: true
                                )
                            }
                            .padding(12)
                        }
                        .frame(maxWidth: 700)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if showFPSPicker {
                        hudPanelSurface(cornerRadius: 20) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(
                                        coordinator.isLowPowerModeEnabled
                                            ? "源帧率 \(PlaybackHUDMetrics.formatSourceFPS(optical.sourceFPS)) fps · 低电量 60Hz 上限"
                                            : "源帧率 \(PlaybackHUDMetrics.formatSourceFPS(optical.sourceFPS)) fps · ProMotion 智能锁频",
                                        systemImage: coordinator.isLowPowerModeEnabled ? "battery.25" : "sparkles"
                                    )
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(coordinator.isLowPowerModeEnabled ? .yellow : .secondary)
                                    Spacer()
                                    Button {
                                        fpsAutoCloseTask?.cancel()
                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                            showFPSPicker = false
                                        }
                                        scheduleHUDAutoHide()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }

                                FrameRatePresetStrip(
                                    coordinator: coordinator,
                                    optical: optical,
                                    compact: true
                                ) {
                                    scheduleFPSPickerAutoClose()
                                }
                            }
                            .padding(12)
                        }
                        .frame(maxWidth: 700)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    hudPanelSurface(cornerRadius: 22) {
                        VStack(spacing: 10) {
                            HStack(spacing: 10) {
                                Text(formatTime(displayTime))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.9))
                                    .frame(width: 48, alignment: .leading)

                                Slider(
                                    value: Binding(
                                        get: { displayTime },
                                        set: { newVal in
                                            isScrubbing = true
                                            scrubTime = newVal
                                            hudAutoHideTask?.cancel()
                                        }
                                    ),
                                    in: 0...max(coordinator.activeDuration, 1),
                                    onEditingChanged: { editing in
                                        if !editing {
                                            coordinator.seek(to: scrubTime)
                                            isScrubbing = false
                                            scheduleHUDAutoHide()
                                        }
                                    }
                                )
                                .tint(.cyan)

                                Button {
                                    showRemainingTime.toggle()
                                    scheduleHUDAutoHide()
                                } label: {
                                    Text(trailingDurationText)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.85))
                                        .frame(width: 52, alignment: .trailing)
                                }
                                .buttonStyle(.plain)
                            }

                            HStack(spacing: 10) {
                                let fpsSummary = OpticalFlowTargetFPS.activeCapsuleSummary(
                                    isOff: coordinator.interpolationMode == .off,
                                    requested: coordinator.opticalFlowTargetFPS,
                                    effective: optical.effectiveTargetFPS,
                                    sourceFPS: optical.sourceFPS,
                                    spatial2x: coordinator.vtSpatial2x
                                )
                                let isInterpActive = (coordinator.interpolationMode == .vtOpticalFlow)
                                Button {
                                    fpsAutoCloseTask?.cancel()
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                        showQualityPicker = false
                                        showFPSPicker.toggle()
                                    }
                                    if showFPSPicker {
                                        hudAutoHideTask?.cancel()
                                    } else {
                                        scheduleHUDAutoHide()
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: coordinator.interpolationMode == .off ? "film" : "sparkles")
                                            .font(.caption2.weight(.bold))
                                        Text(fpsSummary.title)
                                            .font(.caption2.monospacedDigit().weight(.bold))
                                    }
                                    .foregroundStyle(isInterpActive ? .black : .white)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 7)
                                    .background(
                                        Capsule().fill(isInterpActive ? Color.cyan : Color.white.opacity(0.14))
                                    )
                                }
                                .buttonStyle(.plain)

                                let isQualityActive = (coordinator.videoEnhancementPreset != .off)
                                Button {
                                    fpsAutoCloseTask?.cancel()
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                        showFPSPicker = false
                                        showQualityPicker.toggle()
                                    }
                                    if showQualityPicker {
                                        hudAutoHideTask?.cancel()
                                    } else {
                                        scheduleHUDAutoHide()
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: coordinator.videoEnhancementPreset.iconName)
                                            .font(.caption2.weight(.bold))
                                        Text(coordinator.videoEnhancementPreset.shortBadge)
                                            .font(.caption2.weight(.bold))
                                    }
                                    .foregroundStyle(isQualityActive ? .white : .white.opacity(0.9))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(
                                        Capsule().fill(isQualityActive ? Color.purple.opacity(0.90) : Color.white.opacity(0.14))
                                    )
                                }
                                .buttonStyle(.plain)

                                if coordinator.currentStreamVariants.count > 1 {
                                    Menu {
                                        ForEach(coordinator.currentStreamVariants) { variant in
                                            let isCurrent = (variant.url == coordinator.currentURL)
                                            Button {
                                                coordinator.switchStreamVariant(variant)
                                                scheduleHUDAutoHide()
                                            } label: {
                                                if isCurrent {
                                                    Label(variant.label, systemImage: "checkmark")
                                                } else {
                                                    Text(variant.label)
                                                }
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: "4k.tv")
                                                .font(.caption2.weight(.bold))
                                            Text(PlayerOverlayLayoutPolicy.compactStreamVariantLabel(from: optical.activeStreamLabel))
                                                .font(.caption2.weight(.bold))
                                            Image(systemName: "chevron.up.chevron.down")
                                                .font(.system(size: 8, weight: .bold))
                                        }
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(Capsule().fill(Color.white.opacity(0.14)))
                                    }
                                }

                                Spacer(minLength: 4)

                                if coordinator.activePlaylist.count > 1 {
                                    Button {
                                        hudAutoHideTask?.cancel()
                                        showPlaylistSheet = true
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "list.bullet.rectangle")
                                                .font(.caption2.weight(.bold))
                                            Text("选集 (\((coordinator.activePlaylistIndex ?? 0) + 1)/\(coordinator.activePlaylist.count))")
                                                .font(.caption2.monospacedDigit().weight(.bold))
                                        }
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(Capsule().fill(Color.white.opacity(0.14)))
                                    }
                                    .buttonStyle(.plain)
                                }

                                let isSubActive = subtitleManager.isEnabled && subtitleManager.selectedTrackID != nil
                                Button {
                                    hudAutoHideTask?.cancel()
                                    showFPSPicker = false
                                    showQualityPicker = false
                                    unifiedSettingsInitialTab = .subtitles
                                    showUnifiedSettingsSheet = true
                                } label: {
                                    Image(systemName: isSubActive ? "captions.bubble.fill" : "captions.bubble")
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(isSubActive ? .black : .white)
                                        .frame(width: 34, height: 34)
                                        .background(Capsule().fill(isSubActive ? Color.cyan : Color.white.opacity(0.14)))
                                }
                                .buttonStyle(.plain)

                                Button {
                                    hudAutoHideTask?.cancel()
                                    showFPSPicker = false
                                    showQualityPicker = false
                                    unifiedSettingsInitialTab = .video
                                    showUnifiedSettingsSheet = true
                                } label: {
                                    Image(systemName: "gearshape.fill")
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 34, height: 34)
                                        .background(Circle().fill(Color.white.opacity(0.16)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .frame(maxWidth: 700)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            // 左侧独立防误触锁屏键
            HStack {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        isScreenLocked = true
                        showHUD = false
                        showFPSPicker = false
                        showQualityPicker = false
                    }
                    hudAutoHideTask?.cancel()
                    triggerUnlockPill()
                } label: {
                    Image(systemName: "lock.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .padding(.leading, 18)
                Spacer()
            }

            // 正中 Infuse 风格盲按播控中心（弹层打开、加载预热中或报错时自动避让防重叠）
            if PlayerOverlayLayoutPolicy.shouldShowCenterTransportControls(
                showFPSPicker: showFPSPicker,
                showQualityPicker: showQualityPicker,
                isLoadingPipeline: optical.isLoadingPipeline,
                presentedFrameCount: optical.presentedFrameCount,
                hasError: optical.errorMessage != nil
            ) {
                let skipStep = preferencesStore.skipIntervalSeconds
                HStack(spacing: 24) {
                    if coordinator.activePlaylist.count > 1 {
                        Button {
                            coordinator.playPreviousEpisode()
                            scheduleHUDAutoHide()
                        } label: {
                            Image(systemName: "backward.end.fill")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(coordinator.hasPreviousEpisode ? .white : .white.opacity(0.35))
                                .frame(width: 42, height: 42)
                                .background(Color.black.opacity(0.48), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!coordinator.hasPreviousEpisode)
                    }

                    Button {
                        coordinator.seekRelative(-Double(skipStep))
                        triggerSkipFeedback(delta: -skipStep)
                        scheduleHUDAutoHide()
                    } label: {
                        Image(systemName: "gobackward.\(skipStep)")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Color.black.opacity(0.52), in: Circle())
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)

                    Button {
                        coordinator.togglePlayPause()
                        scheduleHUDAutoHide()
                    } label: {
                        Image(systemName: coordinator.activePaused ? "play.fill" : "pause.fill")
                            .font(.title.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(width: 62, height: 62)
                            .background(Color.cyan, in: Circle())
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)

                    Button {
                        coordinator.seekRelative(Double(skipStep))
                        triggerSkipFeedback(delta: skipStep)
                        scheduleHUDAutoHide()
                    } label: {
                        Image(systemName: "goforward.\(skipStep)")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Color.black.opacity(0.52), in: Circle())
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)

                    if coordinator.activePlaylist.count > 1 {
                        Button {
                            coordinator.playNextEpisode()
                            scheduleHUDAutoHide()
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(coordinator.hasNextEpisode ? .white : .white.opacity(0.35))
                                .frame(width: 42, height: 42)
                                .background(Color.black.opacity(0.48), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!coordinator.hasNextEpisode)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var skipIntroOverlayCard: some View {
        let introSec = coordinator.currentFolderIntroSeconds
        if introSec >= 15,
           !dismissedSkipIntro,
           coordinator.activeCurrentTime >= 1.5,
           coordinator.activeCurrentTime < Double(introSec) - 2.0,
           (coordinator.activeDuration <= 0 || Double(introSec) < coordinator.activeDuration - 10.0),
           (coordinator.activePlaylist.count > 1 || coordinator.activeMediaRequest?.cloudItem != nil) {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            coordinator.skipIntro()
                            dismissedSkipIntro = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "forward.end.fill")
                                    .font(.caption.weight(.bold))
                                Text("跳过片头 · \(WatchHistoryEntry.formatClock(Double(introSec)))")
                                    .font(.caption.monospacedDigit().weight(.bold))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(Color.white.opacity(0.94)))
                        }
                        .buttonStyle(.plain)

                        Button {
                            dismissedSkipIntro = true
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 28, height: 28)
                                .background(Color.black.opacity(0.58), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                    .padding(.trailing, 20)
                    .padding(.bottom, showHUD ? 132 : 26)
                }
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var upNextEpisodeOverlayCard: some View {
        let duration = coordinator.activeDuration
        let remaining = max(0, duration - coordinator.activeCurrentTime)
        if let nextItem = coordinator.nextEpisodeItem,
           !coordinator.isLooping,
           preferencesStore.autoShowUpNextCard,
           !dismissedUpNext,
           duration > 30,
           remaining <= 15.0,
           remaining > 0.5 {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("即将播放下一集 · \(Int(ceil(remaining)))s")
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .foregroundStyle(.cyan)
                            Text(nextItem.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: 190, alignment: .leading)

                        Button {
                            coordinator.playNextEpisode()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "play.fill")
                                    .font(.caption2.weight(.bold))
                                Text("立即播放")
                                    .font(.caption.weight(.bold))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.cyan))
                        }
                        .buttonStyle(.plain)

                        Button {
                            dismissedUpNext = true
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(width: 26, height: 26)
                                .background(Color.white.opacity(0.14), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.black.opacity(0.82))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8)
                            )
                    )
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
                    .padding(.trailing, 20)
                    .padding(.bottom, showHUD ? 132 : 26)
                }
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private var trailingDurationText: String {
        if showRemainingTime && coordinator.activeDuration > 0 {
            let rem = max(0, coordinator.activeDuration - displayTime)
            return "-\(formatTime(rem))"
        }
        return formatTime(coordinator.activeDuration)
    }

    private var toolbarActionButtons: some View {
        HStack(spacing: 8) {
            Button {
                OrientationController.shared.toggleVideoOrientation()
                scheduleHUDAutoHide()
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
                coordinator.setAspectFill(!coordinator.isAspectFill)
                scheduleHUDAutoHide()
            } label: {
                Image(systemName: coordinator.isAspectFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(coordinator.isAspectFill ? .cyan : .primary)
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .glassEffect(
                coordinator.isAspectFill ? .regular.tint(.cyan).interactive() : .regular.interactive(),
                in: .circle
            )

            if preferencesStore.showDeveloperHUD {
                Button {
                    hudAutoHideTask?.cancel()
                    showDiagnosticSheet = true
                } label: {
                    Image(systemName: "waveform.path.ecg")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
            }
        }
    }

    private var topRightMetricsBadge: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showStatsHUD.toggle()
            }
            scheduleHUDAutoHide()
        } label: {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Text(activeResolutionText)
                    if optical.hdrLabel != "SDR" {
                        Text(optical.hdrLabel)
                            .foregroundStyle(optical.isHDRActive ? .yellow : .orange)
                    }
                }
                .font(.caption2.monospacedDigit().weight(.semibold))

                Text("\(coordinator.hudMetrics.interpolationBadge) · \(activeFPSText)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .glassEffect(
            showStatsHUD ? .regular.tint(.cyan).interactive() : .regular.interactive(),
            in: .capsule
        )
    }

    private func compactStatsHUD(metrics: PlaybackHUDMetrics) -> some View {
        let engineColor: Color = {
            switch metrics.engineBadge {
            case "GPU": return .cyan
            case "PASS": return .green
            default: return .blue
            }
        }()
        let isNativeRes = metrics.resolutionModeBadge.contains("原画")

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(metrics.engineBadge)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(engineColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        engineColor.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )

                Text(metrics.videoStreamSummary)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced).monospacedDigit())
                    .foregroundStyle(metrics.isHDRActive ? .yellow : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                HStack(spacing: 4) {
                    Circle()
                        .fill(thermalColor(metrics.thermalLevel))
                        .frame(width: 6, height: 6)
                    Text(metrics.thermalLevel.rawValue)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(thermalColor(metrics.thermalLevel))
                }
            }

            HStack(spacing: 6) {
                Text("FPS \(metrics.fpsSummary)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced).monospacedDigit())
                    .foregroundStyle(metrics.isStalled ? .yellow : .white.opacity(0.95))
                    .lineLimit(1)

                Text("· 丢帧 \(metrics.droppedFrames)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced).monospacedDigit())
                    .foregroundStyle(metrics.droppedFrames > 0 ? .orange : .white.opacity(0.75))
                    .lineLimit(1)
            }

            HStack(spacing: 5) {
                if !metrics.resolutionModeBadge.isEmpty {
                    Text(metrics.resolutionModeBadge)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(isNativeRes ? .green : .orange)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(
                            (isNativeRes ? Color.green : Color.orange).opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        )
                }

                Text(metrics.pipelineSummary)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            if !metrics.performanceSummary.isEmpty {
                Text(metrics.performanceSummary)
                    .font(.system(size: 10, weight: .medium, design: .monospaced).monospacedDigit())
                    .foregroundStyle(.cyan.opacity(0.90))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            if optical.videoEnhancementPreset != .off {
                Text("画质 \(optical.videoEnhancementPreset.rawValue) (\(optical.videoEnhancementStrength.rawValue))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.purple.opacity(0.95))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.64))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.8)
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

    private func playbackErrorBanner(_ message: String) -> some View {
        let alternateVariant = coordinator.currentStreamVariants.first { $0.url != coordinator.currentURL }
        let hasCloudRefresh = coordinator.activeMediaRequest?.cloudItem != nil

        return VStack(spacing: 12) {
            Label("播放遇到异常", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if alternateVariant != nil || hasCloudRefresh {
                HStack(spacing: 10) {
                    if let alt = alternateVariant {
                        Button {
                            coordinator.switchStreamVariant(alt)
                        } label: {
                            Text("切换 \(alt.label)")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.tint(.cyan).interactive(), in: .capsule)
                    }

                    if hasCloudRefresh {
                        Button {
                            coordinator.reResolveCurrentCloudStream(preferTranscode: false)
                        } label: {
                            Text("刷新直链重试")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                }
            }

            HStack(spacing: 10) {
                if coordinator.interpolationMode != .off {
                    Button {
                        coordinator.retryWithoutInterpolation()
                    } label: {
                        Text("原帧率直通重试")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        alternateVariant == nil
                            ? .regular.tint(.cyan).interactive()
                            : .regular.interactive(),
                        in: .capsule
                    )
                }

                Button {
                    showDiagnosticSheet = true
                } label: {
                    Text("运行日志")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)

                Button {
                    coordinator.closeToHome()
                } label: {
                    Text("返回")
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

    private var displayTime: Double {
        isScrubbing ? scrubTime : coordinator.activeCurrentTime
    }

    private var activeResolutionText: String {
        let m = coordinator.hudMetrics
        if m.width > 0 && m.height > 0 {
            return "\(m.width)×\(m.height)"
        }
        if coordinator.interpolationMode == .off {
            return "原帧率"
        }
        return optical.enableSpatial2xUpscale ? "ANE 2×超分" : "ANE 光流"
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

// MARK: - Optical Flow & Playback Settings Sheet

struct EnhancementControlSheet: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject private var optical: OpticalFlowPlayerController
    @Environment(\.dismiss) private var dismiss

    init(coordinator: PlayerCoordinator) {
        self.coordinator = coordinator
        self._optical = ObservedObject(wrappedValue: coordinator.opticalFlowController)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("光流补帧目标帧率（实时热切换）") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("当前模式")
                            Spacer()
                            Text(coordinator.interpolationMode == .vtOpticalFlow ? "光流 \(optical.targetSummaryBadge)" : "原帧率直通")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.cyan)
                        }

                        FrameRatePresetStrip(
                            coordinator: coordinator,
                            optical: optical,
                            compact: false
                        )

                        Text("自动匹配片源帧率与 ProMotion 物理锁频（48Hz / 60Hz / 120Hz），并随低电量模式自动封顶 60Hz；播放中点选卡片立即原地热切换，无需重建音频。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    if optical.activeBackendLabel != "--" {
                        LabeledContent("运行后端", value: "\(optical.activeBackendLabel) (\(String(format: "%.1f", optical.actualOutputFPS)) fps)")
                    }

                    if let gatedReason = coordinator.superResolutionDisabledReason {
                        Label(gatedReason, systemImage: "4k.tv.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("实时 GPU 画质增强（假 4K 去糊 + MetalFX 低清超分）") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("当前画质")
                            Spacer()
                            Text(optical.activeQualityPipelineLabel)
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.purple)
                        }

                        QualityPresetStrip(
                            coordinator: coordinator,
                            optical: optical,
                            compact: false
                        )

                        Text(coordinator.videoEnhancementPreset.detailDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("画质与播放开关") {
                    Toggle("ANE 2× 空间超分（仅 2× 档位）", isOn: Binding(
                        get: { coordinator.vtSpatial2x },
                        set: { coordinator.setVTSpatial2x($0) }
                    ))
                    .disabled(
                        coordinator.interpolationMode == .off
                            || coordinator.isSuperResolutionDisabledBy4K
                            || !coordinator.opticalFlowTargetFPS.allowsSpatial2x
                    )

                    Toggle("杜比视界 / HDR 峰值亮度 (EDR)", isOn: Binding(
                        get: { coordinator.isEDREnabled },
                        set: { coordinator.setEDREnabled($0) }
                    ))

                    Toggle("画面铺满全屏 (裁剪黑边)", isOn: Binding(
                        get: { coordinator.isAspectFill },
                        set: { coordinator.setAspectFill($0) }
                    ))

                    Toggle("播完自动循环重播", isOn: Binding(
                        get: { coordinator.isLooping },
                        set: { coordinator.setLooping($0) }
                    ))
                }
            }
            .navigationTitle("播控与画质设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
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
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject private var optical: OpticalFlowPlayerController
    @Environment(\.dismiss) private var dismiss
    @State private var copiedFeedback: Bool = false
    @State private var exportedFeedback: Bool = false
    @State private var exportErrorMessage: String?

    init(coordinator: PlayerCoordinator) {
        self.coordinator = coordinator
        self._optical = ObservedObject(wrappedValue: coordinator.opticalFlowController)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("核心运行状态") {
                    let activeW = coordinator.activeVideoWidth
                    let activeH = coordinator.activeVideoHeight
                    let activeState = optical.isPaused ? "已暂停" : "播放中"
                    let verdict = coordinator.currentInterpolationVerdict

                    LabeledContent("补帧模式", value: coordinator.interpolationMode.rawValue)
                    LabeledContent("运行阶段", value: activeState)
                    LabeledContent("补帧生效判定", value: verdict.shortLabel)
                    Text(verdict.detailText)
                        .font(.caption2)
                        .foregroundStyle(verdict.isEffective ? .green : .secondary)
                    LabeledContent("视频分辨率", value: activeW > 0 ? "\(activeW)×\(activeH)" : "暂无")
                    LabeledContent("色深 / HDR", value: "\(optical.bitDepthLabel) · \(optical.hdrLabel) (EDR=\(coordinator.isEDREnabled ? "开" : "关"))")
                    LabeledContent("帧率 (源/输出)", value: "\(String(format: "%.1f", optical.sourceFPS)) / \(String(format: "%.1f", optical.actualOutputFPS)) fps")
                    LabeledContent("设备温度状态", value: ThermalLevel(state: coordinator.thermalState).rawValue)
                    LabeledContent(
                        "解码器 / 后端",
                        value: "\(optical.videoCodec.isEmpty ? "-" : optical.videoCodec) / \(optical.activeBackendLabel) (\(optical.clockSourceLabel))"
                    )
                    LabeledContent(
                        "ANE 光流计数",
                        value: "目标 \(optical.targetSummaryBadge) · 补帧 \(optical.interpolatedFrameCount) / 跳过 \(optical.skippedInterpolationCount) / 失败 \(optical.failedInterpolationCount) / 送显 \(optical.presentedFrameCount) / \(String(format: "%.1f", optical.averageInterpolationMs))ms"
                    )
                    if let currentURL = coordinator.currentURL {
                        LabeledContent("当前片源", value: currentURL.lastPathComponent)
                    }
                    if let optErr = optical.errorMessage ?? optical.lastInterpolationError {
                        Text("最近异常：\(optErr)")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }

                Section("诊断操作") {
                    Button {
                        coordinator.retryWithoutInterpolation()
                        dismiss()
                    } label: {
                        Label("切换为原帧率硬解直通播放", systemImage: "arrow.counterclockwise")
                    }

                    Button {
                        UIPasteboard.general.string = buildFullDiagnosticReport()
                        copiedFeedback = true
                    } label: {
                        Label(
                            copiedFeedback ? "已复制完整运行日志" : "一键复制完整运行日志",
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
                            exportedFeedback ? "已生成 .txt 诊断日志" : "导出诊断日志 (.txt)",
                            systemImage: exportedFeedback ? "checkmark.circle.fill" : "square.and.arrow.up"
                        )
                    }

                    if let exportErrorMessage {
                        Text(exportErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("运行期黑匣子采样（最近 \(coordinator.runtimeTimeline.count) 条，停播保留）") {
                    if coordinator.runtimeTimeline.isEmpty {
                        Text("暂无运行期采样（播放视频后每 2 秒自动采集，返回主界面后依然保留）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(coordinator.runtimeTimeline.suffix(30).reversed())) { sample in
                            Text(sample.formatLogLine())
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }

                Section("界面交互与开关审计（最近 \(coordinator.uiAuditLogs.count) 条）") {
                    if coordinator.uiAuditLogs.isEmpty {
                        Text("暂无开关切换审计记录")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(coordinator.uiAuditLogs.suffix(30).reversed().enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }

                Section("ANE 光流核日志（最近 \(optical.diagnosticLogs.count) 条）") {
                    if optical.diagnosticLogs.isEmpty {
                        Text("暂无光流核日志（打开视频后将自动采集）")
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
            .navigationTitle("运行日志中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func buildFullDiagnosticReport() -> String {
        coordinator.exportDiagnosticReportText(includePersistedFallback: true)
    }
}

// MARK: - Infuse-Style Watch History Cards & Sheet

struct ContinueWatchingCard: View {
    let entry: WatchHistoryEntry
    let thumbnailURL: URL?
    let onPlay: () -> Void
    let onPlayFromBeginning: () -> Void
    let onToggleCompleted: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onPlay) {
            ZStack(alignment: .bottomLeading) {
                backdropView
                    .frame(width: 248, height: 140)
                    .clipped()

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.12),
                        Color.black.opacity(0.32),
                        Color.black.opacity(0.90)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Image(systemName: "play.fill")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.black.opacity(0.45), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.30), lineWidth: 0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(entry.sourceBadge)
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.55), in: Capsule())
                        Spacer()
                        Text(entry.remainingText)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(entry.isCompleted ? .green : .cyan)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.55), in: Capsule())
                    }
                    .padding(9)

                    Spacer()

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            Text(entry.timeProgressLabel)
                                .monospacedDigit()
                            Text("·")
                            Text(entry.relativeDateText())
                        }
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 7)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.22))
                            Rectangle()
                                .fill(entry.isCompleted ? Color.green : Color.cyan)
                                .frame(width: max(6, geo.size.width * entry.progress))
                        }
                    }
                    .frame(height: 3.5)
                }
            }
            .frame(width: 248, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onPlay) {
                Label("继续播放", systemImage: "play.fill")
            }
            Button(action: onPlayFromBeginning) {
                Label("从头播放", systemImage: "backward.end.fill")
            }
            Button(action: onToggleCompleted) {
                Label(entry.isCompleted ? "标为未看完" : "标为已看完", systemImage: "checkmark.circle")
            }
            Button(role: .destructive, action: onDelete) {
                Label("移除记录", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var backdropView: some View {
        if let thumbURL = thumbnailURL,
           let uiImg = UIImage(contentsOfFile: thumbURL.path) {
            Image(uiImage: uiImg)
                .resizable()
                .scaledToFill()
        } else if let artStr = entry.artworkURLString,
                  let artURL = URL(string: artStr) {
            AsyncImage(url: artURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    fallbackBackdrop
                }
            }
        } else {
            fallbackBackdrop
        }
    }

    private var fallbackBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [Color.cyan.opacity(0.26), Color.indigo.opacity(0.32), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "play.rectangle.fill")
                .font(.title)
                .foregroundStyle(.white.opacity(0.25))
        }
    }
}

struct WatchHistorySheet: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject private var watchHistoryStore: WatchHistoryStore
    @Environment(\.dismiss) private var dismiss

    init(coordinator: PlayerCoordinator) {
        self.coordinator = coordinator
        self._watchHistoryStore = ObservedObject(wrappedValue: coordinator.watchHistoryStore)
    }

    var body: some View {
        NavigationStack {
            List {
                if watchHistoryStore.entries.isEmpty {
                    ContentUnavailableView(
                        "暂无观看记录",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("播放本地视频或云盘影片后将自动记录进度与剧照")
                    )
                } else {
                    ForEach(watchHistoryStore.entries) { entry in
                        Button {
                            dismiss()
                            coordinator.resumeFromHistory(entry)
                        } label: {
                            HStack(spacing: 12) {
                                historyThumb(entry)
                                    .frame(width: 96, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    HStack(spacing: 6) {
                                        Text(entry.sourceBadge)
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.cyan)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.cyan.opacity(0.15), in: Capsule())

                                        Text(entry.remainingText)
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(entry.isCompleted ? .green : .secondary)

                                        Text("· \(entry.relativeDateText())")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    HStack(spacing: 8) {
                                        GeometryReader { geo in
                                            ZStack(alignment: .leading) {
                                                Capsule().fill(Color.white.opacity(0.14))
                                                Capsule()
                                                    .fill(entry.isCompleted ? Color.green : Color.cyan)
                                                    .frame(width: max(4, geo.size.width * entry.progress))
                                            }
                                        }
                                        .frame(height: 3.5)

                                        Text(entry.timeProgressLabel)
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                watchHistoryStore.remove(id: entry.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                watchHistoryStore.markCompleted(id: entry.id, completed: !entry.isCompleted)
                            } label: {
                                Label(entry.isCompleted ? "标为未看" : "标为已看", systemImage: "checkmark")
                            }
                            .tint(.green)
                        }
                        .contextMenu {
                            Button {
                                dismiss()
                                coordinator.resumeFromHistory(entry)
                            } label: {
                                Label("断点续播", systemImage: "play.fill")
                            }
                            Button {
                                dismiss()
                                coordinator.resumeFromHistory(entry, fromBeginning: true)
                            } label: {
                                Label("从头开始", systemImage: "backward.end.fill")
                            }
                            Button(role: .destructive) {
                                watchHistoryStore.remove(id: entry.id)
                            } label: {
                                Label("删除记录", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("观看记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !watchHistoryStore.entries.isEmpty {
                        Button("清空", role: .destructive) {
                            watchHistoryStore.clearAll()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func historyThumb(_ entry: WatchHistoryEntry) -> some View {
        if let thumbURL = watchHistoryStore.thumbnailURL(for: entry),
           let uiImg = UIImage(contentsOfFile: thumbURL.path) {
            Image(uiImage: uiImg)
                .resizable()
                .scaledToFill()
        } else if let artStr = entry.artworkURLString, let artURL = URL(string: artStr) {
            AsyncImage(url: artURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    placeholderRect
                }
            }
        } else {
            placeholderRect
        }
    }

    private var placeholderRect: some View {
        ZStack {
            Color.indigo.opacity(0.22)
            Image(systemName: "film.fill")
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}

// MARK: - Native Subtitle Overlay & Control Sheet

private struct SubtitleOverlayView: View {
    @ObservedObject var subtitleManager: SubtitleManager
    @ObservedObject var optical: OpticalFlowPlayerController
    let bottomInset: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { _ in
            let lines = subtitleManager.displayLines(at: optical.currentTime)
            if !lines.isEmpty {
                VStack {
                    Spacer()
                    Text(lines.joined(separator: "\n"))
                        .font(.system(size: subtitleManager.style.fontSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(foregroundColor(for: subtitleManager.style.colorPreset))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .shadow(color: .black.opacity(0.85), radius: 2.5, x: 0, y: 1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.black.opacity(subtitleManager.style.backgroundOpacity))
                        )
                        .padding(.horizontal, 24)
                        .padding(.bottom, subtitleManager.style.bottomPadding + bottomInset)
                }
            }
        }
    }

    private func foregroundColor(for preset: SubtitleColorPreset) -> Color {
        switch preset {
        case .white: return .white
        case .yellow: return Color(red: 1.0, green: 0.92, blue: 0.45)
        case .cyan: return .cyan
        }
    }
}

struct SubtitleSettingsSections: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject var subtitleManager: SubtitleManager
    let onDismissForFilePicker: () -> Void

    var body: some View {
        Section("字幕轨道") {
            Toggle("显示字幕", isOn: $subtitleManager.isEnabled)

            if subtitleManager.isLoadingTrack {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在加载并解析字幕...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let status = subtitleManager.statusMessage {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.cyan)
            }

            if subtitleManager.availableTracks.isEmpty {
                Text("未发现内嵌或同目录字幕，可点击下方按钮导入本地 .srt / .ass / .vtt 字幕")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    subtitleManager.selectTrack(nil)
                } label: {
                    HStack {
                        Text("关闭字幕")
                        Spacer()
                        if subtitleManager.selectedTrackID == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.cyan)
                        }
                    }
                }

                ForEach(subtitleManager.availableTracks) { track in
                    Button {
                        let storeRef = coordinator.mediaSourceStore
                        subtitleManager.selectTrack(track) { accountID in
                            storeRef.secret(for: accountID)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Text(track.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if subtitleManager.selectedTrackID == track.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.cyan)
                            }
                        }
                    }
                }
            }

            Button {
                onDismissForFilePicker()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    coordinator.presentSubtitleFilePicker()
                }
            } label: {
                Label("导入外挂字幕 (.srt / .ass / .vtt)", systemImage: "doc.badge.plus")
                    .foregroundStyle(.cyan)
            }
        }

        Section("样式与同步微调") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("字号大小")
                    Spacer()
                    Text("\(Int(subtitleManager.style.fontSize)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $subtitleManager.style.fontSize, in: 14...34, step: 1)
                    .tint(.cyan)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("底部边距")
                    Spacer()
                    Text("\(Int(subtitleManager.style.bottomPadding)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $subtitleManager.style.bottomPadding, in: 10...90, step: 2)
                    .tint(.cyan)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("背景不透明度")
                    Spacer()
                    Text("\(Int((subtitleManager.style.backgroundOpacity * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $subtitleManager.style.backgroundOpacity, in: 0...0.85, step: 0.05)
                    .tint(.cyan)
            }

            Picker("字体颜色", selection: $subtitleManager.style.colorPreset) {
                ForEach(SubtitleColorPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("时间偏移")
                Spacer()
                Button("-0.25s") {
                    subtitleManager.style.timeOffsetSeconds -= 0.25
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text(String(format: "%+.2fs", subtitleManager.style.timeOffsetSeconds))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 56)

                Button("+0.25s") {
                    subtitleManager.style.timeOffsetSeconds += 0.25
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if abs(subtitleManager.style.timeOffsetSeconds) > 0.01 {
                    Button("归零") {
                        subtitleManager.style.timeOffsetSeconds = 0
                    }
                    .font(.caption2)
                }
            }
        }
    }
}

struct SubtitleControlSheet: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject private var subtitleManager: SubtitleManager
    @Environment(\.dismiss) private var dismiss

    init(coordinator: PlayerCoordinator) {
        self.coordinator = coordinator
        self._subtitleManager = ObservedObject(wrappedValue: coordinator.subtitleManager)
    }

    var body: some View {
        NavigationStack {
            List {
                SubtitleSettingsSections(
                    coordinator: coordinator,
                    subtitleManager: subtitleManager,
                    onDismissForFilePicker: { dismiss() }
                )
            }
            .navigationTitle("字幕设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

struct EpisodePlaylistSheet: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject private var watchHistoryStore: WatchHistoryStore
    @Environment(\.dismiss) private var dismiss

    init(coordinator: PlayerCoordinator) {
        self.coordinator = coordinator
        self._watchHistoryStore = ObservedObject(wrappedValue: coordinator.watchHistoryStore)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(coordinator.activePlaylist.enumerated()), id: \.element.id) { index, item in
                    let isCurrent = (index == coordinator.activePlaylistIndex)
                    let history = coordinator.activeMediaRequest?.accountID.flatMap {
                        watchHistoryStore.entry(forCloudItemID: item.id, accountID: $0)
                    }
                    Button {
                        dismiss()
                        if !isCurrent {
                            coordinator.playEpisode(at: index)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(isCurrent ? .black : .secondary)
                                .frame(width: 26, height: 26)
                                .background(
                                    isCurrent ? Color.cyan : Color.white.opacity(0.10),
                                    in: Circle()
                                )

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                    .font(.subheadline.weight(isCurrent ? .bold : .medium))
                                    .foregroundStyle(isCurrent ? .cyan : .primary)
                                    .lineLimit(2)

                                HStack(spacing: 6) {
                                    if !item.subtitle.isEmpty {
                                        Text(item.subtitle)
                                    }
                                    if let history {
                                        Text("· \(history.remainingText)")
                                            .foregroundStyle(history.isCompleted ? .green : .cyan)
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if isCurrent {
                                Image(systemName: "waveform")
                                    .foregroundStyle(.cyan)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("剧集选集 (\(coordinator.activePlaylist.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
