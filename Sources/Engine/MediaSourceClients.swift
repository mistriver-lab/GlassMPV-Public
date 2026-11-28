import Foundation
import Security

enum MediaSourceClientError: LocalizedError, Sendable {
    case invalidURL(String)
    case invalidCredentials(String)
    case serverError(String)
    case emptyStream(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let msg),
             .invalidCredentials(let msg),
             .serverError(let msg),
             .emptyStream(let msg):
            return msg
        }
    }
}

enum MediaSourceKeychainStore {
    private static let serviceName = "com.glassmpv.player.mediasources"

    static func saveSecret(_ secret: String, for accountID: UUID) {
        let accountKey = accountID.uuidString
        guard let data = secret.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountKey
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func loadSecret(for accountID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteSecret(for accountID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class MediaSourceStore: ObservableObject {
    @Published private(set) var accounts: [MediaSourceAccount] = []

    private let defaults: UserDefaults
    private let storageKey: String
    private let useKeychain: Bool
    private var inMemorySecrets: [UUID: String] = [:]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "glassmpv.mediaSources.v1",
        useKeychain: Bool = true
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.useKeychain = useKeychain
        load()
    }

    func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([MediaSourceAccount].self, from: data) else {
            accounts = []
            return
        }
        accounts = decoded
    }

    func addOrUpdate(account: MediaSourceAccount, secret: String) {
        var next = accounts
        if let idx = next.firstIndex(where: { $0.id == account.id }) {
            next[idx] = account
        } else {
            next.append(account)
        }
        accounts = next
        persistAccounts()
        if !secret.isEmpty {
            inMemorySecrets[account.id] = secret
            if useKeychain {
                MediaSourceKeychainStore.saveSecret(secret, for: account.id)
            }
        }
    }

    func delete(accountID: UUID) {
        accounts.removeAll { $0.id == accountID }
        persistAccounts()
        inMemorySecrets.removeValue(forKey: accountID)
        if useKeychain {
            MediaSourceKeychainStore.deleteSecret(for: accountID)
        }
    }

    func secret(for accountID: UUID) -> String {
        if let cached = inMemorySecrets[accountID] {
            return cached
        }
        if useKeychain, let stored = MediaSourceKeychainStore.loadSecret(for: accountID) {
            inMemorySecrets[accountID] = stored
            return stored
        }
        return ""
    }

    private func persistAccounts() {
        if let encoded = try? JSONEncoder().encode(accounts) {
            defaults.set(encoded, forKey: storageKey)
        }
    }
}

// MARK: - Quark Cloud Drive Client

enum QuarkQRPollState: Equatable, Sendable {
    case pending
    case expired
    case authorized(serviceTicket: String)
}

private final class QuarkCookieRefreshBox: @unchecked Sendable {
    private let lock = NSLock()
    private var latestCookie: String

    init(_ initial: String) {
        self.latestCookie = initial
    }

    func update(_ newCookie: String) {
        lock.lock()
        latestCookie = newCookie
        lock.unlock()
    }

    func snapshot() -> String {
        lock.lock()
        let v = latestCookie
        lock.unlock()
        return v
    }
}

enum QuarkDriveClient: Sendable {
    static let baseAPIHost = "https://drive-pc.quark.cn"
    static let qrCASHost = "https://uop.quark.cn"
    static let qrClientID = "532"
    static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"

    static func requestHeaders(cookie: String) -> [String: String] {
        [
            "Cookie": cookie.trimmingCharacters(in: .whitespacesAndNewlines),
            "Referer": "https://pan.quark.cn/",
            "Origin": "https://pan.quark.cn",
            "User-Agent": defaultUserAgent,
            "Accept": "application/json, text/plain, */*"
        ]
    }

    static func mediaHeaders(cookie: String) -> [String: String] {
        [
            "Cookie": cookie.trimmingCharacters(in: .whitespacesAndNewlines),
            "Referer": "https://pan.quark.cn/",
            "User-Agent": defaultUserAgent,
            "Accept": "*/*"
        ]
    }

    static func extractRefreshedCookie(from response: URLResponse, currentCookie: String) -> String? {
        guard let http = response as? HTTPURLResponse,
              let url = http.url ?? URL(string: "https://pan.quark.cn/") else {
            return nil
        }
        let fields = http.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
            if let k = pair.key as? String, let v = pair.value as? String {
                acc[k] = v
            }
        }
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !parsed.isEmpty else { return nil }
        let pairs = parsed.map { "\($0.name)=\($0.value)" }
        let merged = LocalHTTPStreamProxy.mergeSetCookieHeaders(pairs, into: currentCookie)
        return merged == currentCookie ? nil : merged
    }

    static func listDirectory(
        parentFid: String = "0",
        page: Int = 1,
        cookie: String,
        session: URLSession = .shared,
        onCookieRefresh: (@Sendable (String) -> Void)? = nil
    ) async throws -> [CloudMediaItem] {
        let trimmedCookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCookie.isEmpty else {
            throw MediaSourceClientError.invalidCredentials("请先登录夸克网盘并提取有效 Cookie。")
        }
        var comps = URLComponents(string: "\(baseAPIHost)/1/clouddrive/file/sort")
        comps?.queryItems = [
            URLQueryItem(name: "pr", value: "ucpro"),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "uc_param_str", value: ""),
            URLQueryItem(name: "pdir_fid", value: parentFid),
            URLQueryItem(name: "_page", value: "\(max(1, page))"),
            URLQueryItem(name: "_size", value: "100"),
            URLQueryItem(name: "_fetch_total", value: "1"),
            URLQueryItem(name: "_fetch_sub_dirs", value: "0"),
            URLQueryItem(name: "_sort", value: "file_type:asc,file_name:asc")
        ]
        guard let url = comps?.url else {
            throw MediaSourceClientError.invalidURL("夸克目录接口 URL 构造失败")
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "GET"
        for (k, v) in requestHeaders(cookie: trimmedCookie) {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let (data, resp) = try await session.data(for: req)
        if let refreshed = extractRefreshedCookie(from: resp, currentCookie: trimmedCookie) {
            onCookieRefresh?(refreshed)
        }
        try validateHTTPResponse(resp, data: data, serviceName: "夸克网盘")
        return try parseFileListJSON(data)
    }

    static func buildQRLoginURL(token: String) -> URL {
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        let raw = "https://su.quark.cn/4_eMHBJ?token=\(encoded)&client_id=\(qrClientID)&ssb=weblogin&uc_param_str=&uc_biz_str=S%3Acustom%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401%7COPT%3ABACK_BTN_STYLE%400"
        return URL(string: raw) ?? URL(string: "https://su.quark.cn/4_eMHBJ")!
    }

    static func parseQRTokenJSON(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaSourceClientError.serverError("夸克二维码接口响应不是合法 JSON")
        }
        let status = root["status"] as? Int ?? -1
        guard status == 2000000 else {
            let msg = (root["message"] as? String) ?? "状态码 \(status)"
            throw MediaSourceClientError.serverError("获取夸克登录二维码失败: \(msg)")
        }
        let dataDict = root["data"] as? [String: Any] ?? [:]
        let members = dataDict["members"] as? [String: Any] ?? [:]
        guard let token = members["token"] as? String, !token.isEmpty else {
            throw MediaSourceClientError.serverError("夸克二维码接口未返回有效 token")
        }
        return token
    }

    static func parseQRPollJSON(_ data: Data) throws -> QuarkQRPollState {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaSourceClientError.serverError("夸克扫码状态响应不是合法 JSON")
        }
        let status = root["status"] as? Int ?? -1
        if status == 2000000 {
            let dataDict = root["data"] as? [String: Any] ?? [:]
            let members = dataDict["members"] as? [String: Any] ?? [:]
            if let st = members["service_ticket"] as? String, !st.isEmpty {
                return .authorized(serviceTicket: st)
            }
            return .pending
        }
        let msg = ((root["message"] as? String) ?? "").lowercased()
        if status == 50004002 || msg.contains("expire") || msg.contains("过期") || msg.contains("失效") {
            return .expired
        }
        return .pending
    }

    static func requestQRLoginToken(session: URLSession = .shared) async throws -> (token: String, qrURL: URL) {
        var comps = URLComponents(string: "\(qrCASHost)/cas/ajax/getTokenForQrcodeLogin")
        comps?.queryItems = [
            URLQueryItem(name: "client_id", value: qrClientID),
            URLQueryItem(name: "v", value: "1.2"),
            URLQueryItem(name: "request_id", value: UUID().uuidString)
        ]
        guard let url = comps?.url else {
            throw MediaSourceClientError.invalidURL("夸克二维码接口 URL 构造失败")
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        let (data, resp) = try await session.data(for: req)
        try validateHTTPResponse(resp, data: data, serviceName: "夸克二维码申请")
        let token = try parseQRTokenJSON(data)
        return (token: token, qrURL: buildQRLoginURL(token: token))
    }

    static func pollQRLoginTicket(token: String, session: URLSession = .shared) async throws -> QuarkQRPollState {
        var comps = URLComponents(string: "\(qrCASHost)/cas/ajax/getServiceTicketByQrcodeToken")
        comps?.queryItems = [
            URLQueryItem(name: "client_id", value: qrClientID),
            URLQueryItem(name: "v", value: "1.2"),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "request_id", value: UUID().uuidString)
        ]
        guard let url = comps?.url else {
            throw MediaSourceClientError.invalidURL("夸克扫码状态 URL 构造失败")
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        let (data, resp) = try await session.data(for: req)
        try validateHTTPResponse(resp, data: data, serviceName: "夸克扫码轮询")
        return try parseQRPollJSON(data)
    }

    static func bootstrapSessionCookie(
        from rawCookie: String,
        session: URLSession = .shared
    ) async throws -> (itemCount: Int, cookie: String) {
        let trimmed = rawCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MediaSourceClientError.invalidCredentials("夸克网盘 Cookie 为空，请先完成登录。")
        }
        let box = QuarkCookieRefreshBox(trimmed)
        let items = try await listDirectory(
            parentFid: "0",
            page: 1,
            cookie: trimmed,
            session: session,
            onCookieRefresh: { updated in
                box.update(updated)
            }
        )
        return (itemCount: items.count, cookie: box.snapshot())
    }

    static func exchangeServiceTicketForCookie(serviceTicket: String) async throws -> String {
        let encodedST = serviceTicket.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? serviceTicket
        guard let url = URL(string: "https://pan.quark.cn/account/info?st=\(encodedST)&lw=scan") else {
            throw MediaSourceClientError.invalidURL("夸克票据兑换 URL 无效")
        }

        let config = URLSessionConfiguration.ephemeral
        let cookieStorage = HTTPCookieStorage()
        config.httpCookieStorage = cookieStorage
        config.httpShouldSetCookies = true
        let isolatedSession = URLSession(configuration: config)
        defer { isolatedSession.finishTasksAndInvalidate() }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        req.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        let (data, resp) = try await isolatedSession.data(for: req)
        try validateHTTPResponse(resp, data: data, serviceName: "夸克扫码换取 Cookie")

        var merged = ""
        if let stored = cookieStorage.cookies {
            let pairs = stored
                .filter {
                    let d = $0.domain.lowercased()
                    return d.contains("quark.cn") || d.contains("uc.cn")
                }
                .map { "\($0.name)=\($0.value)" }
            if !pairs.isEmpty {
                merged = LocalHTTPStreamProxy.mergeSetCookieHeaders(pairs, into: merged)
            }
        }
        if let refreshed = extractRefreshedCookie(from: resp, currentCookie: merged) {
            merged = refreshed
        }
        guard !merged.isEmpty else {
            throw MediaSourceClientError.invalidCredentials("扫码成功但未收到夸克 Cookie，请尝试网页手机号登录。")
        }

        let bootstrapped = try await bootstrapSessionCookie(from: merged, session: isolatedSession)
        return bootstrapped.cookie
    }

    static func verifyAccount(cookie: String, session: URLSession = .shared) async throws -> (itemCount: Int, refreshedCookie: String) {
        let result = try await bootstrapSessionCookie(from: cookie, session: session)
        return (itemCount: result.itemCount, refreshedCookie: result.cookie)
    }

    static func resolvePlaybackStream(
        item: CloudMediaItem,
        cookie: String,
        preferTranscode: Bool = false,
        session: URLSession = .shared,
        onCookieRefresh: (@Sendable (String) -> Void)? = nil
    ) async throws -> ResolvedPlaybackStream {
        let trimmedCookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCookie.isEmpty else {
            throw MediaSourceClientError.invalidCredentials("夸克网盘 Cookie 为空，请重新登录。")
        }
        let apiHeaders = requestHeaders(cookie: trimmedCookie)
        let cookieBox = QuarkCookieRefreshBox(trimmedCookie)
        let combinedRefresh: @Sendable (String) -> Void = { refreshed in
            cookieBox.update(refreshed)
            onCookieRefresh?(refreshed)
        }

        async let downloadResult: URL? = try? fetchDownloadURL(
            fid: item.id,
            headers: apiHeaders,
            session: session,
            onCookieRefresh: combinedRefresh
        )
        async let variantsResult: [StreamVariantOption] = (try? fetchPlayVariants(
            fid: item.id,
            headers: apiHeaders,
            session: session,
            onCookieRefresh: combinedRefresh
        )) ?? []

        let downloadURL = await downloadResult
        let rawVariants = await variantsResult
        let freshMediaHeaders = mediaHeaders(cookie: cookieBox.snapshot())
        let cloudVariants = rawVariants.map { variant in
            StreamVariantOption(
                id: variant.id,
                label: variant.label,
                url: variant.url,
                headers: freshMediaHeaders,
                isHLS: variant.isHLS
            )
        }

        return try selectBestStream(
            item: item,
            downloadURL: downloadURL,
            cloudVariants: cloudVariants,
            headers: freshMediaHeaders,
            preferTranscode: preferTranscode
        )
    }

    static func parseFileListJSON(_ data: Data) throws -> [CloudMediaItem] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaSourceClientError.serverError("夸克网盘响应不是合法 JSON")
        }
        if let code = root["code"] as? Int, code != 0 {
            let msg = (root["message"] as? String) ?? "错误码 \(code)"
            if code == 41001 || code == 401 || msg.contains("登录") {
                throw MediaSourceClientError.invalidCredentials("夸克登录状态已失效（\(msg)），请重新扫码提取 Cookie。")
            }
            throw MediaSourceClientError.serverError("夸克接口返回错误: \(msg)")
        }
        let dataDict = root["data"] as? [String: Any] ?? [:]
        let rawList = dataDict["list"] as? [[String: Any]] ?? []

        var parsed: [CloudMediaItem] = []
        parsed.reserveCapacity(rawList.count)

        for entry in rawList {
            guard let fid = entry["fid"] as? String,
                  let fileName = entry["file_name"] as? String else {
                continue
            }
            let isDir = (entry["dir"] as? Bool) ?? ((entry["file_type"] as? Int) == 0)
            let ext = (fileName as NSString).pathExtension.lowercased()
            let isSupportedFile = CloudMediaItem.supportedVideoExtensions.contains(ext)
                || CloudMediaItem.supportedSubtitleExtensions.contains(ext)
            if !isDir && !isSupportedFile {
                continue
            }
            let sizeBytes: Int64?
            if let num = entry["size"] as? Int64 {
                sizeBytes = num
            } else if let num = entry["size"] as? Int {
                sizeBytes = Int64(num)
            } else if let num = entry["size"] as? Double {
                sizeBytes = Int64(num)
            } else {
                sizeBytes = nil
            }
            let durationSec = entry["video_duration"] as? Double
            let maxRes = entry["video_max_resolution"] as? String
            let previewStr = entry["preview_url"] as? String
            let previewURL = previewStr.flatMap { URL(string: $0) }

            let tempItem = CloudMediaItem(
                id: fid,
                name: fileName,
                isDirectory: isDir,
                sizeBytes: sizeBytes,
                durationSeconds: durationSec,
                fileExtension: ext,
                sourceKind: .quark
            )
            var subtitleParts: [String] = []
            if isDir {
                subtitleParts.append("文件夹")
            } else {
                if !ext.isEmpty { subtitleParts.append(ext.uppercased()) }
                if let maxRes, !maxRes.isEmpty { subtitleParts.append(maxRes.uppercased()) }
                let sizeStr = tempItem.formattedSizeString
                if !sizeStr.isEmpty { subtitleParts.append(sizeStr) }
            }

            parsed.append(CloudMediaItem(
                id: fid,
                name: fileName,
                isDirectory: isDir,
                sizeBytes: sizeBytes,
                durationSeconds: durationSec,
                fileExtension: ext,
                subtitle: subtitleParts.joined(separator: " · "),
                artworkURL: previewURL,
                sourceKind: .quark
            ))
        }

        return parsed.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func parseDownloadURLJSON(_ data: Data) throws -> URL {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaSourceClientError.serverError("夸克下载接口响应解析失败")
        }
        if let code = root["code"] as? Int, code != 0 {
            let msg = (root["message"] as? String) ?? "错误码 \(code)"
            throw MediaSourceClientError.serverError("获取夸克直链失败: \(msg)")
        }
        if let arr = root["data"] as? [[String: Any]],
           let first = arr.first,
           let urlStr = first["download_url"] as? String,
           let url = URL(string: urlStr) {
            return url
        }
        if let dict = root["data"] as? [String: Any],
           let urlStr = dict["download_url"] as? String,
           let url = URL(string: urlStr) {
            return url
        }
        throw MediaSourceClientError.emptyStream("夸克未返回有效的 download_url")
    }

    static func parsePlayVariantsJSON(
        _ data: Data,
        headers: [String: String]
    ) -> [StreamVariantOption] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = root["data"] as? [String: Any],
              let videoList = dataDict["video_list"] as? [[String: Any]] else {
            return []
        }

        let orderRank: [String: Int] = [
            "4k": 6,
            "2k": 5,
            "super": 4,
            "high": 3,
            "normal": 2,
            "low": 1
        ]
        let displayNames: [String: String] = [
            "4k": "夸克 4K",
            "2k": "夸克 2K",
            "super": "夸克 1080P+",
            "high": "夸克 1080P",
            "normal": "夸克 720P",
            "low": "夸克 流畅"
        ]

        var options: [(rank: Int, option: StreamVariantOption)] = []
        for entry in videoList {
            let resolution = ((entry["resolution"] as? String) ?? "high").lowercased()
            let videoInfo = entry["video_info"] as? [String: Any]
            let urlStr = (videoInfo?["url"] as? String) ?? (entry["url"] as? String)
            guard let urlStr, let url = URL(string: urlStr) else { continue }
            let formatHint = ((videoInfo?["format"] as? String) ?? (entry["format"] as? String) ?? "").lowercased()
            let urlLower = url.absoluteString.lowercased()
            let extLower = url.pathExtension.lowercased()
            let variantIsHLS: Bool
            if formatHint.contains("m3u8") || formatHint.contains("hls") || extLower == "m3u8" || urlLower.contains(".m3u8") {
                variantIsHLS = true
            } else {
                variantIsHLS = false
            }
            let label = displayNames[resolution] ?? "夸克 \(resolution.uppercased())"
            let rank = orderRank[resolution] ?? 0
            options.append((
                rank: rank,
                option: StreamVariantOption(
                    id: "quark-\(resolution)",
                    label: label,
                    url: url,
                    headers: headers,
                    isHLS: variantIsHLS
                )
            ))
        }
        return options.sorted { $0.rank > $1.rank }.map(\.option)
    }

    static func selectBestStream(
        item: CloudMediaItem,
        downloadURL: URL?,
        cloudVariants: [StreamVariantOption],
        headers: [String: String],
        preferTranscode: Bool = false
    ) throws -> ResolvedPlaybackStream {
        var allOptions: [StreamVariantOption] = []
        if let downloadURL {
            allOptions.append(StreamVariantOption(
                id: "quark-original",
                label: "原画直链",
                url: downloadURL,
                headers: headers,
                isHLS: false
            ))
        }
        allOptions.append(contentsOf: cloudVariants)

        let supportsNativeDirect = CloudMediaItem.nativeAVFoundationExtensions.contains(item.fileExtension)
        if supportsNativeDirect && !preferTranscode, let downloadURL {
            return ResolvedPlaybackStream(
                url: downloadURL,
                headers: headers,
                title: item.name,
                qualityLabel: "原画直链",
                isHLS: false,
                alternatives: allOptions
            )
        }
        if let bestTranscode = cloudVariants.first {
            return ResolvedPlaybackStream(
                url: bestTranscode.url,
                headers: headers,
                title: item.name,
                qualityLabel: bestTranscode.label,
                isHLS: bestTranscode.isHLS,
                alternatives: allOptions
            )
        }
        if let downloadURL {
            return ResolvedPlaybackStream(
                url: downloadURL,
                headers: headers,
                title: item.name,
                qualityLabel: "原画直链",
                isHLS: false,
                alternatives: allOptions
            )
        }
        throw MediaSourceClientError.emptyStream("未能获取《\(item.name)》的可播放地址，请检查 Cookie 是否过期。")
    }

    static func fetchDownloadURL(
        fid: String,
        cookie: String,
        session: URLSession = .shared,
        onCookieRefresh: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        let headers = requestHeaders(cookie: cookie)
        return try await fetchDownloadURL(
            fid: fid,
            headers: headers,
            session: session,
            onCookieRefresh: onCookieRefresh
        )
    }

    private static func fetchDownloadURL(
        fid: String,
        headers: [String: String],
        session: URLSession,
        onCookieRefresh: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        guard let url = URL(string: "\(baseAPIHost)/1/clouddrive/file/download?pr=ucpro&fr=pc&uc_param_str=") else {
            throw MediaSourceClientError.invalidURL("夸克下载接口 URL 无效")
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["fids": [fid]])

        let (data, resp) = try await session.data(for: req)
        if let currentCookie = headers["Cookie"],
           let refreshed = extractRefreshedCookie(from: resp, currentCookie: currentCookie) {
            onCookieRefresh?(refreshed)
        }
        try validateHTTPResponse(resp, data: data, serviceName: "夸克直链")
        return try parseDownloadURLJSON(data)
    }

    private static func fetchPlayVariants(
        fid: String,
        headers: [String: String],
        session: URLSession,
        onCookieRefresh: (@Sendable (String) -> Void)? = nil
    ) async throws -> [StreamVariantOption] {
        guard let url = URL(string: "\(baseAPIHost)/1/clouddrive/file/v2/play?pr=ucpro&fr=pc&uc_param_str=") else {
            throw MediaSourceClientError.invalidURL("夸克在线播放接口 URL 无效")
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "fid": fid,
            "resolutions": "normal,low,high,super,2k,4k",
            "supports": "m3u8,fmp4"
        ])

        let (data, resp) = try await session.data(for: req)
        if let currentCookie = headers["Cookie"],
           let refreshed = extractRefreshedCookie(from: resp, currentCookie: currentCookie) {
            onCookieRefresh?(refreshed)
        }
        try validateHTTPResponse(resp, data: data, serviceName: "夸克云转码")
        return parsePlayVariantsJSON(data, headers: headers)
    }
}

// MARK: - Emby REST Client

enum EmbyClient: Sendable {
    static func normalizedBaseURL(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "http://" + trimmed
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.lowercased().hasSuffix("/emby") {
            trimmed.removeLast(5)
        }
        return URL(string: trimmed)
    }

    static func authorizationHeader(deviceId: String = "GlassMPV-iOS", token: String? = nil) -> String {
        var header = "Emby Client=\"GlassMPV\", Device=\"iPhone\", DeviceId=\"\(deviceId)\", Version=\"0.1.0-beta.1\""
        if let token, !token.isEmpty {
            header += ", Token=\"\(token)\""
        }
        return header
    }

    static func requestHeaders(token: String, deviceId: String = "GlassMPV-iOS") -> [String: String] {
        [
            "X-Emby-Token": token,
            "X-Emby-Authorization": authorizationHeader(deviceId: deviceId, token: token),
            "Accept": "application/json"
        ]
    }

    static func authenticate(
        serverURL: String,
        username: String,
        password: String,
        session: URLSession = .shared
    ) async throws -> (userId: String, accessToken: String, serverName: String) {
        guard let baseURL = normalizedBaseURL(serverURL) else {
            throw MediaSourceClientError.invalidURL("Emby 服务器地址无效")
        }
        let bodyData = try JSONSerialization.data(withJSONObject: [
            "Username": username.trimmingCharacters(in: .whitespacesAndNewlines),
            "Pw": password
        ])

        let endpoints = [
            baseURL.appendingPathComponent("emby/Users/AuthenticateByName"),
            baseURL.appendingPathComponent("Users/AuthenticateByName")
        ]

        var lastError: Error?
        for endpoint in endpoints {
            var req = URLRequest(url: endpoint, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(authorizationHeader(), forHTTPHeaderField: "X-Emby-Authorization")
            req.httpBody = bodyData

            do {
                let (data, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
                    continue
                }
                try validateHTTPResponse(resp, data: data, serviceName: "Emby")
                return try parseAuthJSON(data)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? MediaSourceClientError.serverError("Emby 登录失败")
    }

    static func parseAuthJSON(_ data: Data) throws -> (userId: String, accessToken: String, serverName: String) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["AccessToken"] as? String,
              let userDict = root["User"] as? [String: Any],
              let userId = userDict["Id"] as? String else {
            throw MediaSourceClientError.invalidCredentials("Emby 登录响应缺少 AccessToken 或 User.Id")
        }
        let serverName = (userDict["Name"] as? String) ?? "Emby 媒体库"
        return (userId: userId, accessToken: token, serverName: serverName)
    }

    static func listLibraries(
        account: MediaSourceAccount,
        token: String,
        session: URLSession = .shared
    ) async throws -> [CloudMediaItem] {
        guard let baseURL = normalizedBaseURL(account.baseURL) else {
            throw MediaSourceClientError.invalidURL("Emby 服务器地址无效")
        }
        let path = account.userId.isEmpty
            ? "emby/Library/MediaFolders"
            : "emby/Users/\(account.userId)/Views"
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url, timeoutInterval: 20)
        for (k, v) in requestHeaders(token: token) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, resp) = try await session.data(for: req)
        try validateHTTPResponse(resp, data: data, serviceName: "Emby")
        return try parseItemsJSON(data, baseURL: baseURL, token: token)
    }

    static func listItems(
        account: MediaSourceAccount,
        token: String,
        parentId: String,
        session: URLSession = .shared
    ) async throws -> [CloudMediaItem] {
        guard let baseURL = normalizedBaseURL(account.baseURL) else {
            throw MediaSourceClientError.invalidURL("Emby 服务器地址无效")
        }
        let basePath = account.userId.isEmpty
            ? "emby/Items"
            : "emby/Users/\(account.userId)/Items"
        var comps = URLComponents(url: baseURL.appendingPathComponent(basePath), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "ParentId", value: parentId),
            URLQueryItem(name: "SortBy", value: "IsFolder,SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Fields", value: "MediaSources,Overview,RunTimeTicks,Path,Container")
        ]
        guard let url = comps?.url else {
            throw MediaSourceClientError.invalidURL("Emby 列表 URL 构造失败")
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        for (k, v) in requestHeaders(token: token) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, resp) = try await session.data(for: req)
        try validateHTTPResponse(resp, data: data, serviceName: "Emby")
        return try parseItemsJSON(data, baseURL: baseURL, token: token)
    }

    static func parseItemsJSON(
        _ data: Data,
        baseURL: URL,
        token: String
    ) throws -> [CloudMediaItem] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaSourceClientError.serverError("Emby 列表响应不是合法 JSON")
        }
        let rawItems = root["Items"] as? [[String: Any]] ?? []
        let folderTypes: Set<String> = ["CollectionFolder", "Folder", "Series", "Season", "BoxSet"]
        var parsed: [CloudMediaItem] = []
        parsed.reserveCapacity(rawItems.count)

        for entry in rawItems {
            guard let id = entry["Id"] as? String,
                  let name = entry["Name"] as? String else {
                continue
            }
            let itemType = (entry["Type"] as? String) ?? ""
            let isFolder = (entry["IsFolder"] as? Bool) ?? folderTypes.contains(itemType)
            let mediaType = (entry["MediaType"] as? String) ?? ""
            if !isFolder && !mediaType.isEmpty && mediaType.lowercased() != "video" {
                continue
            }
            let mediaSources = entry["MediaSources"] as? [[String: Any]]
            let firstSource = mediaSources?.first
            let msId = (firstSource?["Id"] as? String) ?? id
            let container = ((entry["Container"] as? String) ?? (firstSource?["Container"] as? String) ?? "mp4").lowercased()
            let ticks = (entry["RunTimeTicks"] as? Double)
                ?? (entry["RunTimeTicks"] as? Int64).map(Double.init)
                ?? (entry["RunTimeTicks"] as? Int).map(Double.init)
            let durationSec = ticks.map { $0 / 10_000_000.0 }
            let sizeBytes: Int64? = (firstSource?["Size"] as? Int64)
                ?? (firstSource?["Size"] as? Int).map(Int64.init)
                ?? (firstSource?["Size"] as? Double).map(Int64.init)

            var subtitleParts: [String] = []
            if let ep = entry["IndexNumber"] as? Int, itemType == "Episode" {
                if let seasonNum = entry["ParentIndexNumber"] as? Int {
                    subtitleParts.append("S\(seasonNum)E\(ep)")
                } else {
                    subtitleParts.append("第\(ep)集")
                }
            } else if let year = entry["ProductionYear"] as? Int {
                subtitleParts.append("\(year)")
            }
            if isFolder {
                if subtitleParts.isEmpty { subtitleParts.append(itemType.isEmpty ? "目录" : itemType) }
            } else {
                subtitleParts.append(container.uppercased())
            }

            var artComps = URLComponents(
                url: baseURL.appendingPathComponent("emby/Items/\(id)/Images/Primary"),
                resolvingAgainstBaseURL: false
            )
            artComps?.queryItems = [
                URLQueryItem(name: "maxWidth", value: "400"),
                URLQueryItem(name: "api_key", value: token)
            ]

            var embySubCandidates: [CloudSubtitleCandidate] = []
            if let mediaStreams = firstSource?["MediaStreams"] as? [[String: Any]] {
                for stream in mediaStreams {
                    let sType = (stream["Type"] as? String) ?? ""
                    guard sType.caseInsensitiveCompare("Subtitle") == .orderedSame,
                          let streamIndex = stream["Index"] as? Int else {
                        continue
                    }
                    let isText = (stream["IsTextSubtitleStream"] as? Bool) ?? true
                    guard isText else { continue }
                    let lang = (stream["Language"] as? String) ?? ""
                    let displayTitle = (stream["DisplayTitle"] as? String)
                        ?? (stream["Title"] as? String)
                        ?? (lang.isEmpty ? "字幕 #\(streamIndex)" : lang.uppercased())
                    var subComps = URLComponents(
                        url: baseURL.appendingPathComponent("emby/Videos/\(id)/\(msId)/Subtitles/\(streamIndex)/Stream.vtt"),
                        resolvingAgainstBaseURL: false
                    )
                    subComps?.queryItems = [
                        URLQueryItem(name: "api_key", value: token)
                    ]
                    if let subURL = subComps?.url {
                        embySubCandidates.append(
                            CloudSubtitleCandidate(
                                id: "emby-\(id)-\(msId)-\(streamIndex)",
                                name: displayTitle,
                                fileExtension: "vtt",
                                sourceKind: .emby,
                                directURL: subURL,
                                headers: requestHeaders(token: token),
                                embySubtitleStreamIndex: streamIndex,
                                mediaSourceId: msId,
                                itemId: id
                            )
                        )
                    }
                }
            }

            parsed.append(CloudMediaItem(
                id: id,
                name: name,
                isDirectory: isFolder,
                sizeBytes: sizeBytes,
                durationSeconds: durationSec,
                fileExtension: container,
                subtitle: subtitleParts.joined(separator: " · "),
                artworkURL: artComps?.url,
                artworkHeaders: requestHeaders(token: token),
                sourceKind: .emby,
                embyItemType: itemType,
                mediaSourceId: msId,
                container: container,
                embeddedSubtitleCandidates: embySubCandidates
            ))
        }
        return parsed
    }

    static func buildPlaybackStream(
        item: CloudMediaItem,
        baseURL: URL,
        token: String,
        deviceId: String = "GlassMPV-iOS",
        preferHLS: Bool = false
    ) throws -> ResolvedPlaybackStream {
        let headers = requestHeaders(token: token, deviceId: deviceId)
        let msId = item.mediaSourceId ?? item.id
        let ext = (item.container ?? item.fileExtension).isEmpty ? "mp4" : (item.container ?? item.fileExtension)

        var directComps = URLComponents(
            url: baseURL.appendingPathComponent("emby/Videos/\(item.id)/stream.\(ext)"),
            resolvingAgainstBaseURL: false
        )
        directComps?.queryItems = [
            URLQueryItem(name: "Static", value: "true"),
            URLQueryItem(name: "MediaSourceId", value: msId),
            URLQueryItem(name: "api_key", value: token)
        ]

        var hlsComps = URLComponents(
            url: baseURL.appendingPathComponent("emby/Videos/\(item.id)/master.m3u8"),
            resolvingAgainstBaseURL: false
        )
        hlsComps?.queryItems = [
            URLQueryItem(name: "MediaSourceId", value: msId),
            URLQueryItem(name: "DeviceId", value: deviceId),
            URLQueryItem(name: "VideoCodec", value: "hevc,h264"),
            URLQueryItem(name: "AudioCodec", value: "aac,ac3,eac3,mp3"),
            URLQueryItem(name: "MaxStreamingBitrate", value: "140000000"),
            URLQueryItem(name: "TranscodingMaxAudioChannels", value: "6"),
            URLQueryItem(name: "SegmentContainer", value: "mp4"),
            URLQueryItem(name: "api_key", value: token)
        ]

        guard let directURL = directComps?.url, let hlsURL = hlsComps?.url else {
            throw MediaSourceClientError.invalidURL("Emby 播放流 URL 构造失败")
        }

        let directOpt = StreamVariantOption(
            id: "emby-direct",
            label: "Emby 原画直链",
            url: directURL,
            headers: headers,
            isHLS: false
        )
        let hlsOpt = StreamVariantOption(
            id: "emby-hls",
            label: "Emby 无损 HLS",
            url: hlsURL,
            headers: headers,
            isHLS: true
        )
        let variants = [directOpt, hlsOpt]

        let isNativeContainer = CloudMediaItem.nativeAVFoundationExtensions.contains(ext.lowercased())
        if isNativeContainer && !preferHLS {
            return ResolvedPlaybackStream(
                url: directURL,
                headers: headers,
                title: item.name,
                qualityLabel: directOpt.label,
                isHLS: false,
                alternatives: variants
            )
        }
        return ResolvedPlaybackStream(
            url: hlsURL,
            headers: headers,
            title: item.name,
            qualityLabel: hlsOpt.label,
            isHLS: true,
            alternatives: variants
        )
    }
}

// MARK: - WebDAV / Alist Client

enum WebDAVClient: Sendable {
    static func basicAuthHeader(username: String, password: String) -> String? {
        guard !username.isEmpty || !password.isEmpty else { return nil }
        let raw = "\(username):\(password)"
        guard let data = raw.data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }

    static func listDirectory(
        url: URL,
        username: String,
        password: String,
        session: URLSession = .shared
    ) async throws -> [CloudMediaItem] {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "PROPFIND"
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let auth = basicAuthHeader(username: username, password: password) {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:"><D:prop><D:displayname/><D:getcontentlength/><D:resourcetype/></D:prop></D:propfind>
        """
        req.httpBody = body.data(using: .utf8)

        let (data, resp) = try await session.data(for: req)
        try validateHTTPResponse(resp, data: data, serviceName: "WebDAV")
        return parsePropfindXML(data, baseURL: url)
    }

    static func parsePropfindXML(_ data: Data, baseURL: URL) -> [CloudMediaItem] {
        let delegate = PropfindXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()

        let normalizedBasePath = normalizedPathString(baseURL.path)
        var items: [CloudMediaItem] = []

        for entry in delegate.entries {
            guard let resolvedURL = resolveHref(entry.href, relativeTo: baseURL) else { continue }
            let entryPath = normalizedPathString(resolvedURL.path)
            if entryPath == normalizedBasePath {
                continue
            }
            let decodedName = entry.displayName.isEmpty
                ? (resolvedURL.lastPathComponent.removingPercentEncoding ?? resolvedURL.lastPathComponent)
                : entry.displayName
            guard !decodedName.isEmpty else { continue }

            let ext = (decodedName as NSString).pathExtension.lowercased()
            let isDir = entry.isCollection || entry.href.hasSuffix("/")
            let isSupportedFile = CloudMediaItem.supportedVideoExtensions.contains(ext)
                || CloudMediaItem.supportedSubtitleExtensions.contains(ext)
            if !isDir && !isSupportedFile {
                continue
            }
            let tempItem = CloudMediaItem(
                id: resolvedURL.absoluteString,
                name: decodedName,
                isDirectory: isDir,
                sizeBytes: entry.sizeBytes,
                fileExtension: ext,
                sourceKind: .webdav,
                directURL: resolvedURL
            )
            let subtitle = isDir
                ? "文件夹"
                : [ext.uppercased(), tempItem.formattedSizeString].filter { !$0.isEmpty }.joined(separator: " · ")

            items.append(CloudMediaItem(
                id: resolvedURL.absoluteString,
                name: decodedName,
                isDirectory: isDir,
                sizeBytes: entry.sizeBytes,
                fileExtension: ext,
                subtitle: subtitle,
                sourceKind: .webdav,
                directURL: resolvedURL
            ))
        }

        return items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func buildPlaybackStream(
        item: CloudMediaItem,
        username: String,
        password: String
    ) throws -> ResolvedPlaybackStream {
        guard let url = item.directURL else {
            throw MediaSourceClientError.invalidURL("WebDAV 文件地址无效")
        }
        var headers: [String: String] = [:]
        if let auth = basicAuthHeader(username: username, password: password) {
            headers["Authorization"] = auth
        }
        let opt = StreamVariantOption(
            id: "webdav-direct",
            label: "WebDAV 原画",
            url: url,
            headers: headers,
            isHLS: false
        )
        return ResolvedPlaybackStream(
            url: url,
            headers: headers,
            title: item.name,
            qualityLabel: opt.label,
            isHLS: false,
            alternatives: [opt]
        )
    }

    private static func normalizedPathString(_ path: String) -> String {
        var result = path.removingPercentEncoding ?? path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private static func resolveHref(_ href: String, relativeTo baseURL: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }

    private final class PropfindXMLDelegate: NSObject, XMLParserDelegate {
        struct Entry {
            var href: String = ""
            var displayName: String = ""
            var isCollection: Bool = false
            var sizeBytes: Int64?
        }

        var entries: [Entry] = []
        private var currentEntry: Entry?
        private var currentText: String = ""
        private var inResourceType = false

        private func localName(_ elementName: String) -> String {
            if let colon = elementName.lastIndex(of: ":") {
                return String(elementName[elementName.index(after: colon)...]).lowercased()
            }
            return elementName.lowercased()
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let tag = localName(elementName)
            currentText = ""
            if tag == "response" {
                currentEntry = Entry()
            } else if tag == "resourcetype" {
                inResourceType = true
            } else if tag == "collection" && inResourceType {
                currentEntry?.isCollection = true
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let tag = localName(elementName)
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if tag == "href" {
                currentEntry?.href = text
            } else if tag == "displayname" {
                if !text.isEmpty {
                    currentEntry?.displayName = text
                }
            } else if tag == "getcontentlength" {
                if let size = Int64(text) {
                    currentEntry?.sizeBytes = size
                }
            } else if tag == "resourcetype" {
                inResourceType = false
            } else if tag == "response" {
                if let entry = currentEntry, !entry.href.isEmpty {
                    entries.append(entry)
                }
                currentEntry = nil
            }
            currentText = ""
        }
    }
}

// MARK: - Cloud Offline Downloader

enum CloudOfflineDownloader: Sendable {
    static func downloadToSandbox(
        stream: ResolvedPlaybackStream,
        suggestedFilename: String,
        session: URLSession = .shared
    ) async throws -> URL {
        if stream.isHLS || stream.url.pathExtension.lowercased() == "m3u8" {
            throw MediaSourceClientError.serverError("HLS 分片流暂不支持单文件离线缓存，请切换到「原画直链」后缓存。")
        }
        var req = URLRequest(url: stream.url, timeoutInterval: 120)
        for (k, v) in stream.headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (tempURL, resp) = try await session.download(for: req)
        try validateHTTPResponse(resp, data: nil, serviceName: "离线缓存")

        try FileManager.default.createDirectory(
            at: LocalMediaImporter.importsDirectory,
            withIntermediateDirectories: true
        )
        let ext = (suggestedFilename as NSString).pathExtension
        let safeExt = ext.isEmpty ? "mp4" : ext
        let baseName = ((suggestedFilename as NSString).deletingPathExtension)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let safeName = baseName.isEmpty ? "cloud_video" : baseName
        let destURL = LocalMediaImporter.importsDirectory.appendingPathComponent("\(safeName)_\(Int(Date().timeIntervalSince1970)).\(safeExt)")
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        return destURL
    }
}

private func validateHTTPResponse(_ response: URLResponse, data: Data?, serviceName: String) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200...299).contains(http.statusCode) else {
        if http.statusCode == 401 || http.statusCode == 403 {
            throw MediaSourceClientError.invalidCredentials("\(serviceName) 鉴权失败（HTTP \(http.statusCode)），请检查账号或 Cookie。")
        }
        let bodySnippet = data.flatMap { String(data: $0.prefix(160), encoding: .utf8) } ?? ""
        throw MediaSourceClientError.serverError("\(serviceName) 请求失败（HTTP \(http.statusCode)）\(bodySnippet.isEmpty ? "" : ": \(bodySnippet)")")
    }
}
