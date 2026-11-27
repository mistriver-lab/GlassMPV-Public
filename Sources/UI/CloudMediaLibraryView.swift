import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import WebKit

// MARK: - Embedded Quark QR + WebView Login & Cookie Extractor

private enum QuarkQRCodeRenderer {
    private static let ciContext = CIContext()

    static func makeQRCodeImage(from text: String, size: CGFloat = 240) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scale = max(4.0, floor(size / max(1.0, outputImage.extent.width)))
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        let rawQR = UIImage(cgImage: cgImage)

        let pad: CGFloat = 24
        let totalSize = CGSize(width: rawQR.size.width + pad * 2, height: rawQR.size.height + pad * 2)
        let renderer = UIGraphicsImageRenderer(size: totalSize)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: totalSize))
            rawQR.draw(at: CGPoint(x: pad, y: pad))
        }
    }
}

@MainActor
private final class QuarkPhotoSaver: NSObject {
    private var completion: ((Error?) -> Void)?

    func save(_ image: UIImage, completion: @escaping (Error?) -> Void) {
        self.completion = completion
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(handleSave(_:didFinishWithError:contextInfo:)), nil)
    }

    @objc private func handleSave(
        _ image: UIImage,
        didFinishWithError error: Error?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        let cb = completion
        completion = nil
        cb?(error)
    }
}

@MainActor
private struct QuarkLoginWebContainer: UIViewRepresentable {
    let url: URL
    let reloadTrigger: Int
    let preferDesktopMode: Bool
    let onPageFinished: () -> Void

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var lastReloadTrigger: Int = 0
        var lastDesktopMode: Bool = false
        var onPageFinished: () -> Void

        init(onPageFinished: @escaping () -> Void) {
            self.onPageFinished = onPageFinished
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let targetURL = navigationAction.request.url,
                  let scheme = targetURL.scheme?.lowercased() else {
                return .allow
            }
            if scheme == "http" || scheme == "https" || scheme == "about" || scheme == "blob" || scheme == "data" {
                return .allow
            }
            _ = await UIApplication.shared.open(targetURL)
            return .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onPageFinished()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageFinished: onPageFinished)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.preferredContentMode = preferDesktopMode ? .desktop : .mobile
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.lastDesktopMode = preferDesktopMode
        applyUserAgent(to: webView, desktop: preferDesktopMode)
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.onPageFinished = onPageFinished
        if context.coordinator.lastDesktopMode != preferDesktopMode {
            context.coordinator.lastDesktopMode = preferDesktopMode
            uiView.configuration.defaultWebpagePreferences.preferredContentMode = preferDesktopMode ? .desktop : .mobile
            applyUserAgent(to: uiView, desktop: preferDesktopMode)
            uiView.reload()
            return
        }
        if context.coordinator.lastReloadTrigger != reloadTrigger {
            context.coordinator.lastReloadTrigger = reloadTrigger
            uiView.reload()
        }
    }

    private func applyUserAgent(to webView: WKWebView, desktop: Bool) {
        if desktop {
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        } else {
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        }
    }
}

private enum QuarkLoginTab: String, CaseIterable, Identifiable {
    case qrScan = "夸克 App 扫码"
    case mobileWeb = "网页/手机登录"
    var id: Self { self }
}

struct QuarkWebLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let onExtractedCookie: (String) -> Void

    @State private var selectedTab: QuarkLoginTab = .qrScan
    @State private var qrToken: String = ""
    @State private var qrURL: URL?
    @State private var qrImage: UIImage?
    @State private var qrStatusText: String = "正在申请夸克安全登录二维码..."
    @State private var isLoadingQR: Bool = false
    @State private var qrExpired: Bool = false
    @State private var photoSaver: QuarkPhotoSaver?

    @State private var reloadTrigger = 0
    @State private var preferDesktopMode = false
    @State private var isExtracting = false
    @State private var statusHint: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("登录方式", selection: $selectedTab) {
                    ForEach(QuarkLoginTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                if let statusHint {
                    Text(statusHint)
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.65))
                }

                if selectedTab == .qrScan {
                    qrScanContent
                } else {
                    webLoginContent
                }
            }
            .navigationTitle("登录夸克网盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if selectedTab == .qrScan {
                        Button {
                            Task { await loadFreshQR() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    } else {
                        HStack(spacing: 12) {
                            Button(preferDesktopMode ? "手机版" : "桌面版") {
                                preferDesktopMode.toggle()
                            }
                            .font(.caption.weight(.semibold))
                            Button {
                                reloadTrigger += 1
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }
                }
            }
            .task(id: selectedTab) {
                guard selectedTab == .qrScan else { return }
                await loadFreshQR()
                await pollQRStatusLoop()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active && selectedTab == .qrScan && !qrToken.isEmpty && !qrExpired {
                    Task { await checkQRStatusOnce() }
                }
            }
        }
    }

    private var qrScanContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 10) {
                    if let qrImage {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 210, height: 210)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                            )
                            .opacity(qrExpired ? 0.35 : 1.0)
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 210, height: 210)
                            .overlay {
                                ProgressView()
                            }
                    }

                    Text(qrStatusText)
                        .font(.caption)
                        .foregroundStyle(qrExpired ? .orange : .secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)

                VStack(spacing: 10) {
                    Button {
                        saveQRAndOpenQuarkApp()
                    } label: {
                        Label("保存二维码并打开夸克 App", systemImage: "qrcode.viewfinder")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(qrImage == nil || isLoadingQR || isExtracting)

                    HStack(spacing: 10) {
                        Button {
                            saveQRToPhotos(openQuarkAfter: false)
                        } label: {
                            Label("仅存相册", systemImage: "square.and.arrow.down")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                        }
                        .buttonStyle(.bordered)
                        .disabled(qrImage == nil || isLoadingQR)

                        Button {
                            Task { await loadFreshQR() }
                        } label: {
                            Label("刷新二维码", systemImage: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isLoadingQR)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label("单台手机推荐操作步骤：", systemImage: "iphone.and.arrow.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                    Text("1. 点击上方蓝色按钮将二维码存入相册并自动打开「夸克 App」。\n2. 在夸克 App 点击右上角/搜索栏「扫一扫」→ 右下角「相册」，选取刚才保存的二维码并点击「确认登录」。\n3. 切回 GlassMPV，程序会自动完成 Cookie（含 __puus）兑换并保存片源。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(16)
        }
    }

    private var webLoginContent: some View {
        VStack(spacing: 0) {
            QuarkLoginWebContainer(
                url: URL(string: "https://pan.quark.cn/")!,
                reloadTrigger: reloadTrigger,
                preferDesktopMode: preferDesktopMode,
                onPageFinished: {
                    autoCheckWebViewCookiesIfReady()
                }
            )

            VStack(spacing: 8) {
                Text("支持手机号验证码或跳转授权，看到「全部文件」列表后会自动提取 Cookie（或点击下方按钮手动提取）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    extractCookies(silentIfMissing: false)
                } label: {
                    HStack(spacing: 6) {
                        if isExtracting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.shield.fill")
                        }
                        Text(isExtracting ? "正在验证并补全 Cookie..." : "已完成登录 · 提取夸克 Cookie")
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
    }

    @MainActor
    private func loadFreshQR() async {
        isLoadingQR = true
        qrExpired = false
        statusHint = nil
        qrStatusText = "正在申请夸克安全登录二维码..."
        do {
            let result = try await QuarkDriveClient.requestQRLoginToken()
            qrToken = result.token
            qrURL = result.qrURL
            qrImage = QuarkQRCodeRenderer.makeQRCodeImage(from: result.qrURL.absoluteString, size: 240)
            qrStatusText = "二维码已就绪，请用夸克 App 扫一扫确认登录（自动等待回执中...）"
        } catch {
            qrStatusText = "二维码申请失败：\(error.localizedDescription)"
        }
        isLoadingQR = false
    }

    @MainActor
    private func pollQRStatusLoop() async {
        while !Task.isCancelled && selectedTab == .qrScan {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, selectedTab == .qrScan else { break }
            if !qrToken.isEmpty && !qrExpired && !isExtracting {
                await checkQRStatusOnce()
            }
        }
    }

    @MainActor
    private func checkQRStatusOnce() async {
        guard !qrToken.isEmpty, !qrExpired, !isExtracting else { return }
        do {
            let state = try await QuarkDriveClient.pollQRLoginTicket(token: qrToken)
            switch state {
            case .pending:
                break
            case .expired:
                qrExpired = true
                qrStatusText = "二维码已过期，请点击「刷新二维码」重新生成。"
            case .authorized(let st):
                isExtracting = true
                qrStatusText = "扫码授权成功！正在兑换并校验夸克 Cookie..."
                let cookie = try await QuarkDriveClient.exchangeServiceTicketForCookie(serviceTicket: st)
                isExtracting = false
                onExtractedCookie(cookie)
                dismiss()
            }
        } catch {
            isExtracting = false
            statusHint = "扫码兑换遇到问题：\(error.localizedDescription)"
        }
    }

    private func saveQRAndOpenQuarkApp() {
        saveQRToPhotos(openQuarkAfter: true)
    }

    private func saveQRToPhotos(openQuarkAfter: Bool) {
        guard let qrImage else { return }
        statusHint = nil
        let saver = QuarkPhotoSaver()
        photoSaver = saver
        saver.save(qrImage) { error in
            Task { @MainActor in
                if let error {
                    statusHint = "保存相册失败（请确认已允许写入照片权限）：\(error.localizedDescription)"
                } else {
                    statusHint = openQuarkAfter
                        ? "二维码已保存至相册！正在打开夸克 App，请在「扫一扫 → 相册」中扫码确认后返回。"
                        : "二维码已保存到系统相册，可用夸克 App 扫一扫相册选图。"
                }
                if openQuarkAfter, let schemeURL = URL(string: "quark://") {
                    UIApplication.shared.open(schemeURL) { opened in
                        if !opened {
                            Task { @MainActor in
                                statusHint = "二维码已存相册，但未检测到夸克 App，请手动打开夸克或在上方切到「网页/手机登录」。"
                            }
                        }
                    }
                }
            }
        }
    }

    private func autoCheckWebViewCookiesIfReady() {
        guard selectedTab == .mobileWeb, !isExtracting else { return }
        extractCookies(silentIfMissing: true)
    }

    private func extractCookies(silentIfMissing: Bool) {
        if !silentIfMissing {
            isExtracting = true
            statusHint = nil
        }
        Task { @MainActor in
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            let quarkCookies = cookies.filter {
                let d = $0.domain.lowercased()
                return d.contains("quark.cn") || d.contains("uc.cn")
            }
            let cookieString = quarkCookies
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")

            let hasSessionCookie = quarkCookies.contains { cookie in
                let name = cookie.name.lowercased()
                return (name == "__puus" || name == "__pus") && !cookie.value.isEmpty
            }
            guard !quarkCookies.isEmpty, !cookieString.isEmpty, hasSessionCookie else {
                if !silentIfMissing {
                    isExtracting = false
                    statusHint = quarkCookies.isEmpty
                        ? "尚未检测到夸克登录态 Cookie，请先完成账号登录后再试。"
                        : "未检测到核心凭证 __puus/__pus，请确认网页已进入「全部文件」列表页后再点击提取。"
                }
                return
            }

            isExtracting = true
            do {
                let bootstrapped = try await QuarkDriveClient.bootstrapSessionCookie(from: cookieString)
                isExtracting = false
                onExtractedCookie(bootstrapped.cookie)
                dismiss()
            } catch {
                isExtracting = false
                if !silentIfMissing {
                    statusHint = "Cookie 校验失败：\(error.localizedDescription)"
                }
            }
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
                    verifyAndSave()
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
                    let verified = try await QuarkDriveClient.verifyAccount(cookie: cookie)
                    let finalName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let account = MediaSourceAccount(
                        kind: .quark,
                        name: finalName.isEmpty ? "夸克网盘" : finalName,
                        baseURL: QuarkDriveClient.baseAPIHost
                    )
                    store.addOrUpdate(account: account, secret: verified.refreshedCookie)
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
                let storeRef = store
                let accRef = account
                fetched = try await QuarkDriveClient.listDirectory(
                    parentFid: key,
                    cookie: secret,
                    onCookieRefresh: { refreshed in
                        Task { @MainActor in
                            storeRef.addOrUpdate(account: accRef, secret: refreshed)
                        }
                    }
                )
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
                    alternatives: resolved.alternatives,
                    accountID: account.id
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
            let storeRef = store
            let accRef = account
            return try await QuarkDriveClient.resolvePlaybackStream(
                item: item,
                cookie: secret,
                preferTranscode: preferAlternate,
                onCookieRefresh: { refreshed in
                    Task { @MainActor in
                        storeRef.addOrUpdate(account: accRef, secret: refreshed)
                    }
                }
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
