import Foundation

enum MediaSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case quark = "quark"
    case emby = "emby"
    case webdav = "webdav"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .quark: return "夸克网盘"
        case .emby: return "Emby"
        case .webdav: return "WebDAV / Alist"
        }
    }

    var shortBadge: String {
        switch self {
        case .quark: return "夸克"
        case .emby: return "Emby"
        case .webdav: return "WebDAV"
        }
    }

    var iconName: String {
        switch self {
        case .quark: return "cloud.fill"
        case .emby: return "film.stack"
        case .webdav: return "externaldrive.connected.to.line.below"
        }
    }

    var accentName: String {
        switch self {
        case .quark: return "cyan"
        case .emby: return "green"
        case .webdav: return "indigo"
        }
    }
}

struct MediaSourceAccount: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var kind: MediaSourceKind
    var name: String
    var baseURL: String
    var username: String
    var userId: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: MediaSourceKind,
        name: String,
        baseURL: String = "",
        username: String = "",
        userId: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.username = username
        self.userId = userId
        self.createdAt = createdAt
    }
}

struct CloudMediaItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isDirectory: Bool
    let sizeBytes: Int64?
    let durationSeconds: Double?
    let fileExtension: String
    let subtitle: String
    let artworkURL: URL?
    let artworkHeaders: [String: String]
    let sourceKind: MediaSourceKind
    let embyItemType: String?
    let mediaSourceId: String?
    let container: String?
    let directURL: URL?

    static let supportedVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "ts", "m2ts",
        "avi", "flv", "webm", "rmvb", "mpg", "mpeg", "wmv"
    ]

    static let nativeAVFoundationExtensions: Set<String> = [
        "mp4", "mov", "m4v", "ts", "m3u8"
    ]

    init(
        id: String,
        name: String,
        isDirectory: Bool,
        sizeBytes: Int64? = nil,
        durationSeconds: Double? = nil,
        fileExtension: String = "",
        subtitle: String = "",
        artworkURL: URL? = nil,
        artworkHeaders: [String: String] = [:],
        sourceKind: MediaSourceKind,
        embyItemType: String? = nil,
        mediaSourceId: String? = nil,
        container: String? = nil,
        directURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.fileExtension = fileExtension.lowercased()
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.artworkHeaders = artworkHeaders
        self.sourceKind = sourceKind
        self.embyItemType = embyItemType
        self.mediaSourceId = mediaSourceId
        self.container = container
        self.directURL = directURL
    }

    var formattedSizeString: String {
        guard let sizeBytes, sizeBytes > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        return formatter.string(fromByteCount: sizeBytes)
    }

    var formattedDurationString: String {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return "" }
        let total = Int(durationSeconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

struct StreamVariantOption: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let url: URL
    let headers: [String: String]
    let isHLS: Bool
}

struct ResolvedPlaybackStream: Sendable, Equatable {
    let url: URL
    let headers: [String: String]
    let title: String
    let qualityLabel: String
    let isHLS: Bool
    let alternatives: [StreamVariantOption]
}

struct PlaybackMediaRequest: Sendable, Equatable {
    let url: URL
    let headers: [String: String]
    let displayTitle: String
    let sourceLabel: String
    let alternatives: [StreamVariantOption]
}
