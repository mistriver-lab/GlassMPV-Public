import Foundation

struct PinnedFolder: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let accountID: UUID
    let sourceKind: MediaSourceKind
    let accountName: String
    let folderKey: String
    let folderTitle: String
    let pinnedAt: Date

    static func makeID(accountID: UUID, folderKey: String) -> String {
        "\(accountID.uuidString)::\(folderKey)"
    }

    init(
        accountID: UUID,
        sourceKind: MediaSourceKind,
        accountName: String,
        folderKey: String,
        folderTitle: String,
        pinnedAt: Date = Date()
    ) {
        self.id = Self.makeID(accountID: accountID, folderKey: folderKey)
        self.accountID = accountID
        self.sourceKind = sourceKind
        self.accountName = accountName
        self.folderKey = folderKey
        self.folderTitle = folderTitle
        self.pinnedAt = pinnedAt
    }
}

@MainActor
final class UserPreferencesStore: ObservableObject {
    @Published var continuousPlayback: Bool {
        didSet { defaults.set(continuousPlayback, forKey: Keys.continuousPlayback) }
    }
    @Published var gesturesEnabled: Bool {
        didSet { defaults.set(gesturesEnabled, forKey: Keys.gesturesEnabled) }
    }
    @Published var skipIntervalSeconds: Int {
        didSet {
            let clamped = Self.sanitizedSkipInterval(skipIntervalSeconds)
            if clamped != skipIntervalSeconds {
                skipIntervalSeconds = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.skipIntervalSeconds)
        }
    }
    @Published var defaultSkipIntroSeconds: Int {
        didSet {
            let clamped = max(0, min(600, defaultSkipIntroSeconds))
            if clamped != defaultSkipIntroSeconds {
                defaultSkipIntroSeconds = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.defaultSkipIntroSeconds)
        }
    }
    @Published var autoShowUpNextCard: Bool {
        didSet { defaults.set(autoShowUpNextCard, forKey: Keys.autoShowUpNextCard) }
    }
    @Published var defaultAspectFill: Bool {
        didSet { defaults.set(defaultAspectFill, forKey: Keys.defaultAspectFill) }
    }
    @Published var showDeveloperHUD: Bool {
        didSet { defaults.set(showDeveloperHUD, forKey: Keys.showDeveloperHUD) }
    }
    @Published private(set) var pinnedFolders: [PinnedFolder]
    @Published private(set) var folderIntroDurations: [String: Int]

    private let defaults: UserDefaults

    private enum Keys {
        static let continuousPlayback = "glassmpv.pref.continuousPlayback"
        static let gesturesEnabled = "glassmpv.pref.gesturesEnabled"
        static let skipIntervalSeconds = "glassmpv.pref.skipIntervalSeconds"
        static let defaultSkipIntroSeconds = "glassmpv.pref.defaultSkipIntroSeconds"
        static let autoShowUpNextCard = "glassmpv.pref.autoShowUpNextCard"
        static let defaultAspectFill = "glassmpv.pref.defaultAspectFill"
        static let showDeveloperHUD = "glassmpv.pref.showDeveloperHUD"
        static let pinnedFolders = "glassmpv.pref.pinnedFolders.v1"
        static let folderIntroDurations = "glassmpv.pref.folderIntroDurations.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Keys.continuousPlayback) != nil {
            self.continuousPlayback = defaults.bool(forKey: Keys.continuousPlayback)
        } else {
            self.continuousPlayback = true
        }
        if defaults.object(forKey: Keys.gesturesEnabled) != nil {
            self.gesturesEnabled = defaults.bool(forKey: Keys.gesturesEnabled)
        } else {
            self.gesturesEnabled = true
        }
        let storedSkip = defaults.object(forKey: Keys.skipIntervalSeconds) as? Int ?? 10
        self.skipIntervalSeconds = Self.sanitizedSkipInterval(storedSkip)
        let storedIntro = defaults.object(forKey: Keys.defaultSkipIntroSeconds) as? Int ?? 85
        self.defaultSkipIntroSeconds = max(0, min(600, storedIntro))
        if defaults.object(forKey: Keys.autoShowUpNextCard) != nil {
            self.autoShowUpNextCard = defaults.bool(forKey: Keys.autoShowUpNextCard)
        } else {
            self.autoShowUpNextCard = true
        }
        self.defaultAspectFill = defaults.bool(forKey: Keys.defaultAspectFill)
        self.showDeveloperHUD = defaults.bool(forKey: Keys.showDeveloperHUD)

        if let data = defaults.data(forKey: Keys.pinnedFolders),
           let decoded = try? JSONDecoder().decode([PinnedFolder].self, from: data) {
            self.pinnedFolders = decoded
        } else {
            self.pinnedFolders = []
        }

        if let data = defaults.data(forKey: Keys.folderIntroDurations),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.folderIntroDurations = decoded
        } else {
            self.folderIntroDurations = [:]
        }
    }

    static func sanitizedSkipInterval(_ raw: Int) -> Int {
        switch raw {
        case ...12: return 10
        case 13...22: return 15
        default: return 30
        }
    }

    func isPinned(accountID: UUID, folderKey: String) -> Bool {
        let id = PinnedFolder.makeID(accountID: accountID, folderKey: folderKey)
        return pinnedFolders.contains { $0.id == id }
    }

    func togglePin(account: MediaSourceAccount, folderKey: String, folderTitle: String) {
        let id = PinnedFolder.makeID(accountID: account.id, folderKey: folderKey)
        if let idx = pinnedFolders.firstIndex(where: { $0.id == id }) {
            pinnedFolders.remove(at: idx)
        } else {
            let entry = PinnedFolder(
                accountID: account.id,
                sourceKind: account.kind,
                accountName: account.name,
                folderKey: folderKey,
                folderTitle: folderTitle
            )
            pinnedFolders.insert(entry, at: 0)
        }
        persistPinnedFolders()
    }

    func removePin(id: String) {
        pinnedFolders.removeAll { $0.id == id }
        persistPinnedFolders()
    }

    func removePins(forAccountID accountID: UUID) {
        let before = pinnedFolders.count
        pinnedFolders.removeAll { $0.accountID == accountID }
        if pinnedFolders.count != before {
            persistPinnedFolders()
        }
    }

    func introDuration(forFolderKey folderKey: String?) -> Int {
        if let folderKey, !folderKey.isEmpty,
           let custom = folderIntroDurations[folderKey], custom >= 15 {
            return custom
        }
        return defaultSkipIntroSeconds
    }

    func hasCustomIntroDuration(forFolderKey folderKey: String?) -> Bool {
        guard let folderKey, !folderKey.isEmpty else { return false }
        return (folderIntroDurations[folderKey] ?? 0) >= 15
    }

    func setIntroDuration(_ seconds: Int, forFolderKey folderKey: String) {
        guard !folderKey.isEmpty else { return }
        let clamped = max(15, min(600, seconds))
        folderIntroDurations[folderKey] = clamped
        persistFolderIntros()
    }

    func clearIntroDuration(forFolderKey folderKey: String) {
        guard !folderKey.isEmpty else { return }
        folderIntroDurations.removeValue(forKey: folderKey)
        persistFolderIntros()
    }

    private func persistPinnedFolders() {
        if let encoded = try? JSONEncoder().encode(pinnedFolders) {
            defaults.set(encoded, forKey: Keys.pinnedFolders)
        }
    }

    private func persistFolderIntros() {
        if let encoded = try? JSONEncoder().encode(folderIntroDurations) {
            defaults.set(encoded, forKey: Keys.folderIntroDurations)
        }
    }
}
