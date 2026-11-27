import SwiftUI
import UIKit
import WebKit

// MARK: - Embedded Quark WebView Login & Cookie Extractor

@MainActor
private struct QuarkLoginWebContainer: UIViewRepresentable {
    let url: URL
    let reloadTrigger: Int

    final class Coordinator: NSObject {
        var lastReloadTrigger: Int = 0
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = QuarkDriveClient.defaultUserAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.lastReloadTrigger != reloadTrigger {
            context.coordinator.lastReloadTrigger = reloadTrigger
            uiView.reload()
        }
    }
}

struct QuarkWebLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onExtractedCookie: (String) -> Void

    @State private var reloadTrigger = 0
    @State private var isExtracting = false
    @State private var statusHint: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let statusHint {
                    Text(statusHint)
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.65))
                }

                QuarkLoginWebContainer(
                    url: URL(string: "https://pan.quark.cn/")!,
                    reloadTrigger: reloadTrigger
                )

                VStack(spacing: 8) {
                    Text("请在上方完成夸克网盘账号登录（支持扫码或手机验证码），看到网盘文件列表后点击下方按钮")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        extractCookies()
                    } label: {
                        HStack(spacing: 6) {
                            if isExtracting {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "checkmark.shield.fill")
                            }
                            Text(isExtracting ? "正在读取 Cookie..." : "已完成登录 · 提取夸克 Cookie")
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(isExtracting)
                }
                .padding(14)
                .background(.ultraThinMaterial)
            }
            .navigationTitle("登录夸克网盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        reloadTrigger += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private func extractCookies() {
        isExtracting = true
        statusHint = nil
        Task { @MainActor in
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            let quarkCookies = cookies.filter {
                let d = $0.domain.lowercased()
                return d.contains("quark.cn") || d.contains("uc.cn")
            }
            let cookieString = quarkCookies
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")

            isExtracting = false
            if quarkCookies.isEmpty || cookieString.isEmpty {
                statusHint = "尚未检测到夸克登录态 Cookie，请先完成账号登录后再试。"
                return
            }
            onExtractedCookie(cookieString)
            dismiss()
        }
    }
}

// MARK: - Add Media Source Sheet (Quark / Emby / WebDAV)

struct AddMediaSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: MediaSourceStore

    @State private var selectedKind: MediaSourceKind = .quark
    @State private var displayName: String = ""

    // Quark
    @State private var quarkCookie: String = ""
    @State private var showQuarkWebLogin: Bool = false

    // Emby
    @State private var embyServerURL: String = ""
    @State private var embyUsername: String = ""
    @State private var embyPassword: String = ""
    @State private var embyUseTokenMode: Bool = false
    @State private var embyManualToken: String = ""
    @State private var embyManualUserId: String = ""

    // WebDAV / Alist
    @State private var webdavURL: String = ""
    @State private var webdavUsername: String = ""
    @State private var webdavPassword: String = ""

    @State private var isVerifying: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("片源类型") {
                    Picker("片源类型", selection: $selectedKind) {
                        ForEach(MediaSourceKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("显示名称（可选，如 客厅 Emby / 我的夸克）", text: $displayName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                switch selectedKind {
                case .quark:
                    Section {
                        Button {
                            showQuarkWebLogin = true
                        } label: {
                            Label("内置网页一键扫码/登录夸克并提取 Cookie", systemImage: "safari.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.cyan)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("或手动粘贴夸克 Cookie")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $quarkCookie)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 90)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    } header: {
                        Text("夸克网盘鉴权")
                    } footer: {
                        Text("支持根目录及子文件夹浏览，自动拉取原画直链（可随时切换夸克 4K/1080P 云端转码流）。Cookie 加密存储在系统 Keychain。")
                    }

                case .emby:
                    Section {
                        TextField("服务器地址 (如 http://192.168.1.10:8096)", text: $embyServerURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Toggle("使用 API Key / 令牌直接登录", isOn: $embyUseTokenMode)

                        if embyUseTokenMode {
                            SecureField("Emby AccessToken / API Key", text: $embyManualToken)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("User Id（可选，留空自动拉取媒体库）", text: $embyManualUserId)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            TextField("用户名", text: $embyUsername)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            SecureField("密码（无密码可留空）", text: $embyPassword)
                        }
                    } header: {
                        Text("Emby 服务器连接")
                    } footer: {
                        Text("支持局域网 HTTP 与公网 HTTPS。MP4/MOV 优先原画直链，MKV/AVI 自动匹配无损 HLS 封装以驱动 ANE 补帧与 Metal 画质增强。")
                    }

                case .webdav:
                    Section {
                        TextField("WebDAV / Alist 地址 (如 http://192.168.1.10:5244/dav)", text: $webdavURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("用户名（可选）", text: $webdavUsername)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("密码（可选）", text: $webdavPassword)
                    } header: {
                        Text("WebDAV / Alist 配置")
                    } footer: {
                        Text("若您本地或 NAS 上已运行 Alist，可将 Alist 的 /dav 地址直接挂载于此。")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("添加云端片源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        verifyAndSave()
                    } label: {
                        if isVerifying {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("验证并保存").fontWeight(.semibold)
                        }
                    }
                    .disabled(isVerifying)
                }
            }
            .sheet(isPresented: $showQuarkWebLogin) {
                QuarkWebLoginSheet { extracted in
                    quarkCookie = extracted
                    errorMessage = nil
                }
            }
        }
    }

    private func verifyAndSave() {
        errorMessage = nil
        isVerifying = true

        Task { @MainActor in
            do {
                switch selectedKind {
                case .quark:
                    let cookie = quarkCookie.trimmingCharacters(in: .whitespacesAndNewlines)
                    _ = try await QuarkDriveClient.verifyAccount(cookie: cookie)
                    let finalName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let account = MediaSourceAccount(
                        kind: .quark,
                        name: finalName.isEmpty ? "夸克网盘" : finalName,
                        baseURL: QuarkDriveClient.baseAPIHost
                    )
                    store.addOrUpdate(account: account, secret: cookie)
                    dismiss()

                case .emby:
                    guard let normalizedURL = EmbyClient.normalizedBaseURL(embyServerURL) else {
                        throw MediaSourceClientError.invalidURL("请输入有效的 Emby 服务器地址，例如 http://192.168.1.10:8096")
                    }
                    let finalToken: String
                    let finalUserId: String
                    let detectedName: String
                    if embyUseTokenMode {
                        finalToken = embyManualToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        finalUserId = embyManualUserId.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !finalToken.isEmpty else {
                            throw MediaSourceClientError.invalidCredentials("请输入 Emby AccessToken / API Key")
                        }
                        let tempAcc = MediaSourceAccount(
                            kind: .emby,
                            name: "Emby",
                            baseURL: normalizedURL.absoluteString,
                            userId: finalUserId
                        )
                        _ = try await EmbyClient.listLibraries(account: tempAcc, token: finalToken)
                        detectedName = normalizedURL.host ?? "Emby"
                    } else {
                        let auth = try await EmbyClient.authenticate(
                            serverURL: normalizedURL.absoluteString,
                            username: embyUsername,
                            password: embyPassword
                        )
                        finalToken = auth.accessToken
                        finalUserId = auth.userId
                        detectedName = auth.serverName
                    }
                    let finalName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let account = MediaSourceAccount(
                        kind: .emby,
                        name: finalName.isEmpty ? "Emby · \(detectedName)" : finalName,
                        baseURL: normalizedURL.absoluteString,
                        username: embyUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                        userId: finalUserId
                    )
                    store.addOrUpdate(account: account, secret: finalToken)
                    dismiss()

                case .webdav:
                    var urlText = webdavURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !urlText.lowercased().hasPrefix("http://") && !urlText.lowercased().hasPrefix("https://") {
                        urlText = "http://" + urlText
                    }
                    if !urlText.hasSuffix("/") {
                        urlText += "/"
                    }
                    guard let parsedURL = URL(string: urlText) else {
                        throw MediaSourceClientError.invalidURL("WebDAV 地址格式无效")
                    }
                    let user = webdavUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                    _ = try await WebDAVClient.listDirectory(url: parsedURL, username: user, password: webdavPassword)
                    let finalName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let account = MediaSourceAccount(
                        kind: .webdav,
                        name: finalName.isEmpty ? (parsedURL.host ?? "WebDAV") : finalName,
                        baseURL: parsedURL.absoluteString,
                        username: user
                    )
                    store.addOrUpdate(account: account, secret: webdavPassword)
                    dismiss()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isVerifying = false
        }
    }
}

// MARK: - Cloud Source Browser Sheet

private struct CloudFolderCrumb: Identifiable, Hashable {
    let id: String
    let title: String
    let folderKey: String
}

struct CloudSourceBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    let account: MediaSourceAccount
    @ObservedObject var store: MediaSourceStore
    let onPlay: (PlaybackMediaRequest) -> Void
    let onDownloadLocal: (URL) -> Void

    @State private var crumbs: [CloudFolderCrumb]
    @State private var items: [CloudMediaItem] = []
    @State private var searchText: String = ""
    @State private var isLoading: Bool = false
    @State private var busyMessage: String?
    @State private var errorMessage: String?

    init(
        account: MediaSourceAccount,
        store: MediaSourceStore,
        onPlay: @escaping (PlaybackMediaRequest) -> Void,
        onDownloadLocal: @escaping (URL) -> Void
    ) {
        self.account = account
        self.store = store
        self.onPlay = onPlay
        self.onDownloadLocal = onDownloadLocal

        let rootKey: String
        switch account.kind {
        case .quark: rootKey = "0"
        case .emby: rootKey = ""
        case .webdav: rootKey = account.baseURL
        }
        _crumbs = State(initialValue: [CloudFolderCrumb(id: rootKey, title: account.name, folderKey: rootKey)])
    }

    private var currentCrumb: CloudFolderCrumb {
        crumbs.last ?? CloudFolderCrumb(id: "root", title: account.name, folderKey: "")
    }

    private var filteredItems: [CloudMediaItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if crumbs.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                                Button {
                                    navigateToCrumb(at: index)
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(crumb.title)
                                            .font(.caption.weight(index == crumbs.count - 1 ? .bold : .medium))
                                        if index < crumbs.count - 1 {
                                            Image(systemName: "chevron.right")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .background(.ultraThinMaterial)
                }

                List {
                    if let errorMessage {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("加载失败", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if filteredItems.isEmpty && !isLoading && errorMessage == nil {
                        ContentUnavailableView(
                            searchText.isEmpty ? "当前目录暂无支持视频" : "无匹配结果",
                            systemImage: account.kind.iconName,
                            description: Text("支持 mp4 / mov / mkv / ts / avi 等主流封装")
                        )
                    } else {
                        ForEach(filteredItems) { item in
                            CloudMediaRowView(
                                item: item,
                                onTap: { handleItemTap(item) },
                                onPlayPreferringAlt: { handleItemTap(item, preferAlternate: true) },
                                onCacheOffline: { cacheItemOffline(item) }
                            )
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await loadCurrentDirectory()
                }
            }
            .overlay {
                if let busyMessage {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(busyMessage)
                            .font(.caption.weight(.medium))
                    }
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else if isLoading && items.isEmpty {
                    ProgressView("正在读取目录...")
                }
            }
            .searchable(text: $searchText, prompt: "搜索当前目录影片...")
            .navigationTitle(currentCrumb.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if crumbs.count > 1 {
                        Button {
                            navigateToCrumb(at: crumbs.count - 2)
                        } label: {
                            Label("上一级", systemImage: "chevron.left")
                        }
                    } else {
                        Button("关闭") { dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .task(id: currentCrumb.folderKey) {
                await loadCurrentDirectory()
            }
        }
    }

    private func navigateToCrumb(at index: Int) {
        guard index >= 0 && index < crumbs.count else { return }
        crumbs = Array(crumbs.prefix(index + 1))
    }

    private func loadCurrentDirectory() async {
        isLoading = true
        errorMessage = nil
        let secret = store.secret(for: account.id)
        let key = currentCrumb.folderKey
        do {
            let fetched: [CloudMediaItem]
            switch account.kind {
            case .quark:
                fetched = try await QuarkDriveClient.listDirectory(parentFid: key, cookie: secret)
            case .emby:
                if key.isEmpty {
                    fetched = try await EmbyClient.listLibraries(account: account, token: secret)
                } else {
                    fetched = try await EmbyClient.listItems(account: account, token: secret, parentId: key)
                }
            case .webdav:
                let urlString = key.isEmpty ? account.baseURL : key
                guard let url = URL(string: urlString) else {
                    throw MediaSourceClientError.invalidURL("WebDAV 路径无效")
                }
                fetched = try await WebDAVClient.listDirectory(url: url, username: account.username, password: secret)
            }
            items = fetched
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func handleItemTap(_ item: CloudMediaItem, preferAlternate: Bool = false) {
        if item.isDirectory {
            let nextKey = item.id
            guard crumbs.last?.folderKey != nextKey else { return }
            crumbs.append(CloudFolderCrumb(id: nextKey, title: item.name, folderKey: nextKey))
            return
        }

        busyMessage = "正在解析播放直链..."
        errorMessage = nil
        let secret = store.secret(for: account.id)

        Task { @MainActor in
            do {
                let resolved = try await resolveStream(for: item, secret: secret, preferAlternate: preferAlternate)
                let request = PlaybackMediaRequest(
                    url: resolved.url,
                    headers: resolved.headers,
                    displayTitle: resolved.title,
                    sourceLabel: "\(account.kind.shortBadge) · \(resolved.qualityLabel)",
                    alternatives: resolved.alternatives
                )
                busyMessage = nil
                dismiss()
                onPlay(request)
            } catch {
                busyMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cacheItemOffline(_ item: CloudMediaItem) {
        guard !item.isDirectory else { return }
        busyMessage = "正在高速缓存《\(item.name)》到本地..."
        errorMessage = nil
        let secret = store.secret(for: account.id)

        Task { @MainActor in
            do {
                let resolved = try await resolveStream(for: item, secret: secret, preferAlternate: false)
                let targetStream: ResolvedPlaybackStream
                if resolved.isHLS, let directAlt = resolved.alternatives.first(where: { !$0.isHLS }) {
                    targetStream = ResolvedPlaybackStream(
                        url: directAlt.url,
                        headers: directAlt.headers,
                        title: resolved.title,
                        qualityLabel: directAlt.label,
                        isHLS: false,
                        alternatives: resolved.alternatives
                    )
                } else {
                    targetStream = resolved
                }
                let localURL = try await CloudOfflineDownloader.downloadToSandbox(
                    stream: targetStream,
                    suggestedFilename: item.name
                )
                busyMessage = nil
                dismiss()
                onDownloadLocal(localURL)
            } catch {
                busyMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func resolveStream(
        for item: CloudMediaItem,
        secret: String,
        preferAlternate: Bool
    ) async throws -> ResolvedPlaybackStream {
        switch account.kind {
        case .quark:
            return try await QuarkDriveClient.resolvePlaybackStream(
                item: item,
                cookie: secret,
                preferTranscode: preferAlternate
            )
        case .emby:
            guard let baseURL = EmbyClient.normalizedBaseURL(account.baseURL) else {
                throw MediaSourceClientError.invalidURL("Emby 地址无效")
            }
            return try EmbyClient.buildPlaybackStream(
                item: item,
                baseURL: baseURL,
                token: secret,
                preferHLS: preferAlternate
            )
        case .webdav:
            return try WebDAVClient.buildPlaybackStream(
                item: item,
                username: account.username,
                password: secret
            )
        }
    }
}

private struct CloudMediaRowView: View {
    let item: CloudMediaItem
    let onTap: () -> Void
    let onPlayPreferringAlt: () -> Void
    let onCacheOffline: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                    }
                    let dur = item.formattedDurationString
                    if !dur.isEmpty {
                        Text("· \(dur)")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    Button {
                        onTap()
                    } label: {
                        Label("智能默认流播放", systemImage: "play.fill")
                    }
                    Button {
                        onPlayPreferringAlt()
                    } label: {
                        Label("备选转码流 (4K/HLS) 播放", systemImage: "sparkles.tv")
                    }
                    Button {
                        onCacheOffline()
                    } label: {
                        Label("缓存到本地离线精播", systemImage: "arrow.down.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.cyan)
                        .padding(4)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let artURL = item.artworkURL {
            AsyncImage(url: artURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    placeholderIcon
                }
            }
            .frame(width: 44, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            placeholderIcon
                .frame(width: 44, height: item.isDirectory ? 44 : 52)
        }
    }

    private var placeholderIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(item.isDirectory ? Color.cyan.opacity(0.16) : Color.indigo.opacity(0.16))
            Image(systemName: item.isDirectory ? "folder.fill" : "play.rectangle.fill")
                .font(.title3)
                .foregroundStyle(item.isDirectory ? .cyan : .indigo)
        }
    }
}
