import AVFoundation
import Combine
import CoreMedia
import Foundation

private final class LegibleOutputBridge: NSObject, AVPlayerItemLegibleOutputPushDelegate, @unchecked Sendable {
    private let onLines: @Sendable ([String]) -> Void

    init(onLines: @escaping @Sendable ([String]) -> Void) {
        self.onLines = onLines
        super.init()
    }

    func legibleOutput(
        _ output: AVPlayerItemLegibleOutput,
        didOutputAttributedStrings strings: [NSAttributedString],
        nativeSampleBuffers nativeSamples: [Any],
        forItemTime itemTime: CMTime
    ) {
        let lines = strings
            .map { $0.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        onLines(lines)
    }
}

@MainActor
final class SubtitleManager: ObservableObject {
    @Published var isEnabled: Bool = true
    @Published var availableTracks: [SubtitleTrackOption] = []
    @Published var selectedTrackID: String?
    @Published var style: SubtitleStyleSettings {
        didSet {
            persistStyle()
        }
    }
    @Published var isLoadingTrack: Bool = false
    @Published var statusMessage: String?
    @Published private(set) var embeddedLiveLines: [String] = []

    private(set) var loadedCues: [SubtitleCue] = []

    private let styleDefaultsKey = "glassmpv.subtitle.style.v1"
    private let styleDefaults: UserDefaults
    private weak var activePlayerItem: AVPlayerItem?
    private var activeLocalURL: URL?
    private var activeLegibleGroup: AVMediaSelectionGroup?
    private var activeLegibleOutput: AVPlayerItemLegibleOutput?
    private var legibleBridge: LegibleOutputBridge?
    private var loadGeneration: UInt64 = 0

    init(defaults: UserDefaults = .standard) {
        self.styleDefaults = defaults
        if let data = defaults.data(forKey: styleDefaultsKey),
           let decoded = try? JSONDecoder().decode(SubtitleStyleSettings.self, from: data) {
            self.style = decoded
        } else {
            self.style = .default
        }
    }

    private func persistStyle() {
        if let encoded = try? JSONEncoder().encode(style) {
            styleDefaults.set(encoded, forKey: styleDefaultsKey)
        }
    }

    var activeTrack: SubtitleTrackOption? {
        guard let selectedTrackID else { return nil }
        return availableTracks.first { $0.id == selectedTrackID }
    }

    func resetForNewMedia() {
        loadGeneration &+= 1
        detachLegibleOutput()
        activePlayerItem = nil
        activeLocalURL = nil
        activeLegibleGroup = nil
        availableTracks.removeAll()
        selectedTrackID = nil
        loadedCues.removeAll()
        embeddedLiveLines.removeAll()
        isLoadingTrack = false
        statusMessage = nil
    }

    func attachCloudCandidates(
        _ candidates: [CloudSubtitleCandidate],
        preferredTitle: String,
        cloudAccountSecretProvider: ((UUID) -> String)? = nil
    ) {
        guard !candidates.isEmpty else { return }
        var appended: [SubtitleTrackOption] = []
        for candidate in candidates {
            let trackID = "cloud:\(candidate.id)"
            if availableTracks.contains(where: { $0.id == trackID }) {
                continue
            }
            let opt = SubtitleTrackOption(
                id: trackID,
                displayName: candidate.name,
                detail: candidate.fileExtension.uppercased(),
                source: .externalCloud(candidate: candidate)
            )
            availableTracks.append(opt)
            appended.append(opt)
        }
        guard !appended.isEmpty, selectedTrackID == nil else { return }

        let targetStem = normalizedStem(preferredTitle)
        let exactMatch = appended.first { opt in
            let stem = normalizedStem(opt.displayName)
            return !targetStem.isEmpty && (stem == targetStem || stem.hasPrefix(targetStem) || targetStem.hasPrefix(stem))
        }
        if let match = exactMatch ?? (appended.count == 1 ? appended.first : nil) {
            selectTrack(match, cloudAccountSecretProvider: cloudAccountSecretProvider)
        }
    }

    func discoverLocalSidecarSubtitles(for videoURL: URL) {
        guard videoURL.isFileURL else { return }
        let videoStem = videoURL.deletingPathExtension().lastPathComponent
        let dirURL = videoURL.deletingLastPathComponent()
        let exts = ["srt", "ass", "ssa", "vtt"]
        var found: [SubtitleTrackOption] = []

        for ext in exts {
            let candidateURL = dirURL.appendingPathComponent(videoStem).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidateURL.path) {
                let trackID = "local:\(candidateURL.path)"
                if !availableTracks.contains(where: { $0.id == trackID }) {
                    found.append(
                        SubtitleTrackOption(
                            id: trackID,
                            displayName: candidateURL.lastPathComponent,
                            detail: ext.uppercased(),
                            source: .externalLocal(url: candidateURL, displayName: candidateURL.lastPathComponent)
                        )
                    )
                }
            }
        }
        guard !found.isEmpty else { return }
        availableTracks.append(contentsOf: found)
        if selectedTrackID == nil, let first = found.first {
            selectTrack(first)
        }
    }

    func inspectRemoteAsset(_ asset: AVAsset, playerItem: AVPlayerItem) {
        activePlayerItem = playerItem
        let currentGen = loadGeneration
        Task { @MainActor [weak self] in
            guard let self, self.loadGeneration == currentGen else { return }
            guard let group = try? await asset.loadMediaSelectionGroup(for: .legible) else {
                return
            }
            guard self.loadGeneration == currentGen else { return }
            self.activeLegibleGroup = group
            var newlyAdded: [SubtitleTrackOption] = []
            for (idx, option) in group.options.enumerated() {
                let lang = option.locale?.identifier ?? option.extendedLanguageTag ?? "und"
                let title = option.displayName.isEmpty ? "内嵌字幕 \(idx + 1)" : option.displayName
                let trackID = "embedded:remote:\(idx):\(title)"
                if !self.availableTracks.contains(where: { $0.id == trackID }) {
                    let track = SubtitleTrackOption(
                        id: trackID,
                        displayName: title,
                        detail: "内嵌 · \(lang)",
                        source: .embedded(optionIndex: idx, languageCode: lang, displayName: title)
                    )
                    self.availableTracks.append(track)
                    newlyAdded.append(track)
                }
            }
            if self.selectedTrackID == nil, let firstEmbedded = newlyAdded.first {
                self.selectTrack(firstEmbedded)
            }
        }
    }

    func inspectLocalAsset(_ asset: AVAsset, url: URL) {
        activeLocalURL = url
        discoverLocalSidecarSubtitles(for: url)
        let currentGen = loadGeneration
        Task { @MainActor [weak self] in
            guard let self, self.loadGeneration == currentGen else { return }
            let group = try? await asset.loadMediaSelectionGroup(for: .legible)
            let subtitleTracks = (try? await asset.loadTracks(withMediaType: .subtitle)) ?? []
            let textTracks = (try? await asset.loadTracks(withMediaType: .text)) ?? []
            guard self.loadGeneration == currentGen else { return }

            if let group, !group.options.isEmpty {
                self.activeLegibleGroup = group
                for (idx, option) in group.options.enumerated() {
                    let lang = option.locale?.identifier ?? option.extendedLanguageTag ?? "und"
                    let title = option.displayName.isEmpty ? "内嵌字幕 \(idx + 1)" : option.displayName
                    let trackID = "embedded:local:\(idx):\(title)"
                    if !self.availableTracks.contains(where: { $0.id == trackID }) {
                        self.availableTracks.append(
                            SubtitleTrackOption(
                                id: trackID,
                                displayName: title,
                                detail: "内嵌 · \(lang)",
                                source: .embedded(optionIndex: idx, languageCode: lang, displayName: title)
                            )
                        )
                    }
                }
            } else {
                let allTracks = subtitleTracks + textTracks
                for (idx, tr) in allTracks.enumerated() {
                    let lang = (try? await tr.load(.languageCode)) ?? "und"
                    let title = "内嵌字幕 \(idx + 1) (\(lang))"
                    let trackID = "embedded:local:\(idx):\(title)"
                    if !self.availableTracks.contains(where: { $0.id == trackID }) {
                        self.availableTracks.append(
                            SubtitleTrackOption(
                                id: trackID,
                                displayName: title,
                                detail: "内嵌 · \(lang)",
                                source: .embedded(optionIndex: idx, languageCode: lang, displayName: title)
                            )
                        )
                    }
                }
            }

            if self.selectedTrackID == nil,
               let firstEmbedded = self.availableTracks.first(where: {
                   if case .embedded = $0.source { return true }
                   return false
               }) {
                self.selectTrack(firstEmbedded)
            }
        }
    }

    func loadExternalSubtitleFile(url: URL) {
        let ext = url.pathExtension.lowercased()
        let trackID = "local:\(url.path)"
        let opt = SubtitleTrackOption(
            id: trackID,
            displayName: url.lastPathComponent,
            detail: ext.isEmpty ? "外挂字幕" : ext.uppercased(),
            source: .externalLocal(url: url, displayName: url.lastPathComponent)
        )
        if !availableTracks.contains(where: { $0.id == trackID }) {
            availableTracks.insert(opt, at: 0)
        }
        isEnabled = true
        selectTrack(opt)
    }

    func selectTrack(
        _ track: SubtitleTrackOption?,
        cloudAccountSecretProvider: ((UUID) -> String)? = nil
    ) {
        loadGeneration &+= 1
        let gen = loadGeneration
        statusMessage = nil

        guard let track else {
            selectedTrackID = nil
            loadedCues.removeAll()
            embeddedLiveLines.removeAll()
            detachLegibleOutput()
            if let item = activePlayerItem, let group = activeLegibleGroup {
                item.select(nil, in: group)
            }
            return
        }

        selectedTrackID = track.id
        isEnabled = true

        switch track.source {
        case .embedded(let optionIndex, _, _):
            loadedCues.removeAll()
            embeddedLiveLines.removeAll()
            if let item = activePlayerItem, let group = activeLegibleGroup,
               optionIndex >= 0, optionIndex < group.options.count {
                attachLegibleOutputIfNeeded(to: item)
                item.select(group.options[optionIndex], in: group)
                statusMessage = "已启用内嵌字幕：\(track.displayName)"
            } else if let localURL = activeLocalURL {
                detachLegibleOutput()
                isLoadingTrack = true
                Task.detached(priority: .userInitiated) { [weak self] in
                    let cues = await Self.extractCuesFromLocalAsset(url: localURL, optionIndex: optionIndex)
                    await MainActor.run {
                        guard let self, self.loadGeneration == gen else { return }
                        self.isLoadingTrack = false
                        self.loadedCues = cues
                        self.statusMessage = cues.isEmpty
                            ? "内嵌字幕轨暂无可解析文本（可尝试外挂 SRT/ASS）"
                            : "已加载内嵌字幕（\(cues.count) 条）"
                    }
                }
            }

        case .externalLocal(let url, let name):
            detachLegibleOutput()
            embeddedLiveLines.removeAll()
            isLoadingTrack = true
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let data = try Data(contentsOf: url)
                    let cues = SubtitleParser.parse(data: data, fileExtension: url.pathExtension)
                    await MainActor.run {
                        guard let self, self.loadGeneration == gen else { return }
                        self.isLoadingTrack = false
                        self.loadedCues = cues
                        self.statusMessage = cues.isEmpty
                            ? "未解析到有效字幕条目（\(name)）"
                            : "已加载 \(name)（\(cues.count) 条）"
                    }
                } catch {
                    await MainActor.run {
                        guard let self, self.loadGeneration == gen else { return }
                        self.isLoadingTrack = false
                        self.loadedCues = []
                        self.statusMessage = "读取字幕失败：\(error.localizedDescription)"
                    }
                }
            }

        case .externalCloud(let candidate):
            detachLegibleOutput()
            embeddedLiveLines.removeAll()
            isLoadingTrack = true
            let secret = candidate.accountID.flatMap { cloudAccountSecretProvider?($0) } ?? ""
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let targetURL: URL
                    var headers = candidate.headers
                    if let existingURL = candidate.directURL {
                        targetURL = existingURL
                    } else if candidate.sourceKind == .quark {
                        guard !secret.isEmpty else {
                            throw MediaSourceClientError.invalidCredentials("缺少夸克凭证，无法下载字幕")
                        }
                        headers = QuarkDriveClient.requestHeaders(cookie: secret)
                        targetURL = try await QuarkDriveClient.fetchDownloadURL(fid: candidate.id, cookie: secret)
                    } else {
                        throw MediaSourceClientError.invalidURL("字幕地址无效")
                    }

                    var req = URLRequest(url: targetURL, timeoutInterval: 20)
                    for (k, v) in headers {
                        req.setValue(v, forHTTPHeaderField: k)
                    }
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        throw MediaSourceClientError.serverError("字幕下载失败 HTTP \(http.statusCode)")
                    }
                    let cues = SubtitleParser.parse(data: data, fileExtension: candidate.fileExtension)
                    await MainActor.run {
                        guard let self, self.loadGeneration == gen else { return }
                        self.isLoadingTrack = false
                        self.loadedCues = cues
                        self.statusMessage = cues.isEmpty
                            ? "云端字幕解析为空（\(candidate.name)）"
                            : "已加载云端字幕 \(candidate.name)（\(cues.count) 条）"
                    }
                } catch {
                    await MainActor.run {
                        guard let self, self.loadGeneration == gen else { return }
                        self.isLoadingTrack = false
                        self.loadedCues = []
                        self.statusMessage = "云端字幕加载失败：\(error.localizedDescription)"
                    }
                }
            }
        }
    }

    func displayLines(at mediaTime: Double) -> [String] {
        guard isEnabled, selectedTrackID != nil else { return [] }
        if let activeTrack, case .embedded = activeTrack.source, activePlayerItem != nil {
            return embeddedLiveLines
        }
        let cues = SubtitleParser.activeCues(
            in: loadedCues,
            at: mediaTime,
            offset: style.timeOffsetSeconds
        )
        return cues.map(\.text)
    }

    private func attachLegibleOutputIfNeeded(to item: AVPlayerItem) {
        if let existing = activeLegibleOutput, item.outputs.contains(existing) {
            return
        }
        detachLegibleOutput()
        let output = AVPlayerItemLegibleOutput(mediaSubtypesForNativeRepresentation: [])
        output.suppressesPlayerRendering = true
        let bridge = LegibleOutputBridge { [weak self] lines in
            Task { @MainActor [weak self] in
                self?.embeddedLiveLines = lines
            }
        }
        output.setDelegate(bridge, queue: DispatchQueue.main)
        item.add(output)
        self.activeLegibleOutput = output
        self.legibleBridge = bridge
    }

    private func detachLegibleOutput() {
        if let output = activeLegibleOutput {
            activePlayerItem?.remove(output)
        }
        activeLegibleOutput = nil
        legibleBridge = nil
    }

    private func normalizedStem(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension.lowercased()
        let parts = base.split(separator: ".").map(String.init)
        if parts.count >= 2, let last = parts.last, last.count <= 8 {
            // 剥离如 .zh / .chs / .eng / .sc 等语言后缀做前缀比对
            return parts.dropLast().joined(separator: ".")
        }
        return base
    }

    private nonisolated static func extractCuesFromLocalAsset(url: URL, optionIndex: Int) async -> [SubtitleCue] {
        let asset = AVURLAsset(url: url)
        let subtitleTracks = (try? await asset.loadTracks(withMediaType: .subtitle)) ?? []
        let textTracks = (try? await asset.loadTracks(withMediaType: .text)) ?? []
        let tracks = subtitleTracks + textTracks
        guard !tracks.isEmpty else { return [] }
        let safeIndex = min(max(0, optionIndex), tracks.count - 1)
        let targetTrack = tracks[safeIndex]

        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: targetTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var cues: [SubtitleCue] = []
        var nextID = 0
        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { break }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let dur = CMSampleBufferGetDuration(sample)
            guard pts.isValid, pts.seconds.isFinite else { continue }
            let start = max(0, pts.seconds)
            let durationSec = (dur.isValid && dur.seconds.isFinite && dur.seconds > 0.05) ? dur.seconds : 3.0
            if let text = extractReadableText(from: sample), !text.isEmpty {
                cues.append(SubtitleCue(id: nextID, startTime: start, endTime: start + durationSec, text: text))
                nextID += 1
            }
        }
        return cues
    }

    private nonisolated static func extractReadableText(from sample: CMSampleBuffer) -> String? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 2, length < 64 * 1024 else { return nil }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let addr = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: addr)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        // tx3g/3GPP timed text 前 2 字节为大端 UTF-8 长度
        let bytes = [UInt8](data)
        if bytes.count >= 2 {
            let declaredLen = (Int(bytes[0]) << 8) | Int(bytes[1])
            if declaredLen > 0 && declaredLen <= bytes.count - 2 {
                let slice = Data(bytes[2..<(2 + declaredLen)])
                if let text = String(data: slice, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    return text
                }
            }
        }
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines)),
           !text.isEmpty {
            return text
        }
        return nil
    }
}
