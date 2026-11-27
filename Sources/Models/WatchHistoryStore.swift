import CoreImage
import CoreVideo
import Foundation
import ImageIO

enum WatchHistorySourceKind: String, Codable, Hashable, Sendable {
    case local = "local"
    case quark = "quark"
    case emby = "emby"
    case webdav = "webdav"
    case streamURL = "streamURL"

    var badgeText: String {
        switch self {
        case .local: return "本地"
        case .quark: return "夸克"
        case .emby: return "Emby"
        case .webdav: return "WebDAV"
        case .streamURL: return "网络流"
        }
    }
}

struct WatchHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var title: String
    var subtitle: String
    var sourceKind: WatchHistorySourceKind
    var sourceBadge: String
    var accountID: UUID?
    var cloudItemID: String?
    var cloudItemName: String?
    var cloudItemExtension: String?
    var cloudMediaSourceID: String?
    var cloudContainer: String?
    var localFilePath: String?
    var streamURLString: String?
    var artworkURLString: String?
    var thumbnailFilename: String?
    var positionSeconds: Double
    var durationSeconds: Double
    var lastWatchedAt: Date
    var isCompleted: Bool

    var progress: Double {
        guard durationSeconds.isFinite, durationSeconds > 1.0,
              positionSeconds.isFinite, positionSeconds >= 0 else {
            return isCompleted ? 1.0 : 0.0
        }
        return min(1.0, max(0.0, positionSeconds / durationSeconds))
    }

    var remainingSeconds: Double {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return 0 }
        return max(0, durationSeconds - positionSeconds)
    }

    var remainingText: String {
        if isCompleted {
            return "已看完"
        }
        guard durationSeconds > 1.0 else {
            return "已看 \(Self.formatClock(positionSeconds))"
        }
        let rem = Int(remainingSeconds.rounded())
        if rem < 60 {
            return "剩余 \(max(1, rem)) 秒"
        }
        let mins = rem / 60
        if mins >= 60 {
            let h = mins / 60
            let m = mins % 60
            return m > 0 ? "剩余 \(h) 小时 \(m) 分钟" : "剩余 \(h) 小时"
        }
        return "剩余 \(mins) 分钟"
    }

    var timeProgressLabel: String {
        if durationSeconds > 1.0 {
            return "\(Self.formatClock(positionSeconds)) / \(Self.formatClock(durationSeconds))"
        }
        return Self.formatClock(positionSeconds)
    }

    func relativeDateText(now: Date = Date()) -> String {
        let delta = max(0, now.timeIntervalSince(lastWatchedAt))
        if delta < 60 {
            return "刚刚"
        }
        if delta < 3600 {
            return "\(Int(delta / 60)) 分钟前"
        }
        if delta < 86_400 {
            return "\(Int(delta / 3600)) 小时前"
        }
        if delta < 172_800 {
            return "昨天"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: lastWatchedAt)
    }

    static func formatClock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func makeEntryID(
        sourceKind: WatchHistorySourceKind,
        accountID: UUID? = nil,
        cloudItemID: String? = nil,
        localURL: URL? = nil,
        streamURL: URL? = nil
    ) -> String {
        if let cloudItemID, !cloudItemID.isEmpty {
            let accPart = accountID?.uuidString ?? "default"
            return "\(sourceKind.rawValue)::\(accPart)::\(cloudItemID)"
        }
        if let localURL, localURL.isFileURL {
            return "local::\(localURL.lastPathComponent)::\(localURL.path.hashValue)"
        }
        if let streamURL {
            return "stream::\(streamURL.absoluteString)"
        }
        return "\(sourceKind.rawValue)::\(UUID().uuidString)"
    }
}

@MainActor
final class WatchHistoryStore: ObservableObject {
    @Published private(set) var entries: [WatchHistoryEntry] = []

    private let storageDirectory: URL
    private let historyFileURL: URL
    private let thumbnailsDirectory: URL
    private let maxEntries = 80
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(storageDirectory: URL? = nil) {
        let baseDir: URL
        if let storageDirectory {
            baseDir = storageDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            baseDir = appSupport.appendingPathComponent("GlassMPV/WatchHistory", isDirectory: true)
        }
        self.storageDirectory = baseDir
        self.historyFileURL = baseDir.appendingPathComponent("watch_history.json")
        self.thumbnailsDirectory = baseDir.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        load()
    }

    var continueWatchingEntries: [WatchHistoryEntry] {
        entries
            .filter { !$0.isCompleted && ($0.positionSeconds >= 3.0 || $0.durationSeconds > 1.0) }
            .sorted { $0.lastWatchedAt > $1.lastWatchedAt }
            .prefix(12)
            .map { $0 }
    }

    func load() {
        guard let data = try? Data(contentsOf: historyFileURL) else {
            entries = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([WatchHistoryEntry].self, from: data) {
            entries = decoded.sorted { $0.lastWatchedAt > $1.lastWatchedAt }
        } else {
            entries = []
        }
    }

    @discardableResult
    func upsertProgress(
        id: String,
        title: String,
        subtitle: String = "",
        sourceKind: WatchHistorySourceKind,
        sourceBadge: String? = nil,
        accountID: UUID? = nil,
        cloudItem: CloudMediaItem? = nil,
        localURL: URL? = nil,
        streamURL: URL? = nil,
        artworkURL: URL? = nil,
        positionSeconds: Double,
        durationSeconds: Double,
        watchedAt: Date = Date()
    ) -> WatchHistoryEntry {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = cleanTitle.isEmpty ? "未命名影片" : cleanTitle
        let safePos = positionSeconds.isFinite ? max(0, positionSeconds) : 0
        let safeDur = durationSeconds.isFinite ? max(0, durationSeconds) : 0

        var next = entries
        let existingIndex = next.firstIndex(where: { $0.id == id })
        var entry = existingIndex.map { next[$0] } ?? WatchHistoryEntry(
            id: id,
            title: resolvedTitle,
            subtitle: subtitle,
            sourceKind: sourceKind,
            sourceBadge: sourceBadge ?? sourceKind.badgeText,
            accountID: accountID,
            cloudItemID: cloudItem?.id,
            cloudItemName: cloudItem?.name,
            cloudItemExtension: cloudItem?.fileExtension,
            cloudMediaSourceID: cloudItem?.mediaSourceId,
            cloudContainer: cloudItem?.container,
            localFilePath: localURL?.isFileURL == true ? localURL?.path : nil,
            streamURLString: streamURL?.absoluteString,
            artworkURLString: artworkURL?.absoluteString ?? cloudItem?.artworkURL?.absoluteString,
            thumbnailFilename: nil,
            positionSeconds: safePos,
            durationSeconds: safeDur,
            lastWatchedAt: watchedAt,
            isCompleted: false
        )

        entry.title = resolvedTitle
        if !subtitle.isEmpty {
            entry.subtitle = subtitle
        }
        if let sourceBadge, !sourceBadge.isEmpty {
            entry.sourceBadge = sourceBadge
        }
        if let accountID {
            entry.accountID = accountID
        }
        if let cloudItem {
            entry.cloudItemID = cloudItem.id
            entry.cloudItemName = cloudItem.name
            entry.cloudItemExtension = cloudItem.fileExtension
            entry.cloudMediaSourceID = cloudItem.mediaSourceId
            entry.cloudContainer = cloudItem.container
            if let art = cloudItem.artworkURL {
                entry.artworkURLString = art.absoluteString
            }
        }
        if let localURL, localURL.isFileURL {
            entry.localFilePath = localURL.path
        }
        if let streamURL {
            entry.streamURLString = streamURL.absoluteString
        }
        if let artworkURL {
            entry.artworkURLString = artworkURL.absoluteString
        }
        entry.positionSeconds = safePos
        if safeDur > 0 {
            entry.durationSeconds = safeDur
        }
        entry.lastWatchedAt = watchedAt

        let ratio = entry.durationSeconds > 1 ? (entry.positionSeconds / entry.durationSeconds) : 0
        if entry.durationSeconds >= 60 && ratio >= 0.94 {
            entry.isCompleted = true
        } else if ratio < 0.90 {
            entry.isCompleted = false
        }

        if let existingIndex {
            next[existingIndex] = entry
        } else {
            next.append(entry)
        }
        next.sort { $0.lastWatchedAt > $1.lastWatchedAt }
        if next.count > maxEntries {
            let dropped = Array(next.dropFirst(maxEntries))
            next = Array(next.prefix(maxEntries))
            for item in dropped {
                removeThumbnailFile(named: item.thumbnailFilename)
            }
        }
        entries = next
        persist()
        return entry
    }

    func entry(forID id: String) -> WatchHistoryEntry? {
        entries.first { $0.id == id }
    }

    func entry(forCloudItemID itemID: String, accountID: UUID) -> WatchHistoryEntry? {
        entries.first { $0.cloudItemID == itemID && $0.accountID == accountID }
    }

    func entry(forLocalURL url: URL) -> WatchHistoryEntry? {
        guard url.isFileURL else { return nil }
        return entries.first { $0.localFilePath == url.path }
    }

    func thumbnailURL(for entry: WatchHistoryEntry) -> URL? {
        guard let filename = entry.thumbnailFilename, !filename.isEmpty else { return nil }
        let url = thumbnailsDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func saveThumbnailJPEG(_ data: Data, for entryID: String) {
        guard !data.isEmpty, let idx = entries.firstIndex(where: { $0.id == entryID }) else { return }
        let safeName = "thumb_\(abs(entryID.hashValue))_\(Int(Date().timeIntervalSince1970)).jpg"
        let dest = thumbnailsDirectory.appendingPathComponent(safeName)
        do {
            try data.write(to: dest, options: .atomic)
            let oldName = entries[idx].thumbnailFilename
            var updated = entries
            updated[idx].thumbnailFilename = safeName
            entries = updated
            if let oldName, oldName != safeName {
                removeThumbnailFile(named: oldName)
            }
            persist()
        } catch {
            // 缩略图写入失败不影响观看记录主流程
        }
    }

    func markCompleted(id: String, completed: Bool) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        var updated = entries
        updated[idx].isCompleted = completed
        if !completed && updated[idx].durationSeconds > 1 {
            let ratio = updated[idx].positionSeconds / updated[idx].durationSeconds
            if ratio >= 0.94 {
                updated[idx].positionSeconds = 0
            }
        }
        entries = updated
        persist()
    }

    func resetProgress(id: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        var updated = entries
        updated[idx].positionSeconds = 0
        updated[idx].isCompleted = false
        entries = updated
        persist()
    }

    func remove(id: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let removed = entries[idx]
        removeThumbnailFile(named: removed.thumbnailFilename)
        var updated = entries
        updated.remove(at: idx)
        entries = updated
        persist()
    }

    func clearAll() {
        for item in entries {
            removeThumbnailFile(named: item.thumbnailFilename)
        }
        entries = []
        persist()
    }

    nonisolated static func renderJPEGThumbnail(from pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent
        guard extent.width > 16, extent.height > 16 else { return nil }
        let targetWidth: CGFloat = 480.0
        let scale = min(1.0, targetWidth / extent.width)
        let scaled = scale < 0.99
            ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : ciImage
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImageWithJPEG(cgImage: cgImage, compressionQuality: 0.72)
    }

    private nonisolated static func UIImageWithJPEG(cgImage: CGImage, compressionQuality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private func removeThumbnailFile(named filename: String?) {
        guard let filename, !filename.isEmpty else { return }
        let url = thumbnailsDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: historyFileURL, options: .atomic)
        }
    }
}
