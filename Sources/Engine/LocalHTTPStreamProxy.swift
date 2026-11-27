import Foundation
import Network

/// 纯原生基于 Network.framework (NWListener) 的本地 HTTP Range / HLS 反向代理。
/// 解决 iOS `AVURLAsset` 在 302 重定向与 `.m3u8` 分片请求期间丢失 `Cookie / Referer / User-Agent` 导致的 403 问题，
/// 并自动捕获响应头 `Set-Cookie`（如夸克 `__puus` 滚动续期）回写上层存储。
final class LocalHTTPStreamProxy: @unchecked Sendable {
    static let shared = LocalHTTPStreamProxy()

    struct ProxyRoute: @unchecked Sendable {
        let upstreamURL: URL
        var headers: [String: String]
        let isHLS: Bool
        let onCookieUpdate: (@Sendable (String) -> Void)?
        let onLog: (@Sendable (String) -> Void)?
    }

    private let lock = NSLock()
    private let networkQueue = DispatchQueue(label: "com.glassmpv.localproxy", qos: .userInitiated)
    private var listener: NWListener?
    private var listeningPort: UInt16 = 0
    private var routes: [String: ProxyRoute] = [:]
    private var routeNormalLogCounts: [String: Int] = [:]

    private init() {}

    func ensureStarted() throws -> UInt16 {
        lock.lock()
        if listener != nil, listeningPort > 0 {
            let port = listeningPort
            lock.unlock()
            return port
        }
        lock.unlock()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        let newListener = try NWListener(using: params)
        let readySemaphore = DispatchSemaphore(value: 0)

        final class ListenerStartResult: @unchecked Sendable {
            var error: Error?
            var didSignal = false
        }
        let startResult = ListenerStartResult()

        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let port = newListener.port?.rawValue ?? 0
                self.lock.lock()
                self.listeningPort = port
                let shouldSignal = !startResult.didSignal
                startResult.didSignal = true
                self.lock.unlock()
                if shouldSignal {
                    readySemaphore.signal()
                }
            case .failed(let err):
                self.lock.lock()
                self.listener = nil
                self.listeningPort = 0
                let shouldSignal = !startResult.didSignal
                startResult.error = err
                startResult.didSignal = true
                self.lock.unlock()
                if shouldSignal {
                    readySemaphore.signal()
                }
            case .cancelled:
                self.lock.lock()
                self.listener = nil
                self.listeningPort = 0
                self.lock.unlock()
            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        lock.lock()
        self.listener = newListener
        lock.unlock()
        newListener.start(queue: networkQueue)

        _ = readySemaphore.wait(timeout: .now() + 2.5)
        lock.lock()
        let port = listeningPort
        let err = startResult.error
        lock.unlock()
        if let err {
            throw err
        }
        guard port > 0 else {
            throw NSError(domain: "GlassMPV.LocalProxy", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "本地流媒体代理端口启动超时"
            ])
        }
        return port
    }

    func registerStream(
        url: URL,
        headers: [String: String],
        isHLS: Bool = false,
        onCookieUpdate: (@Sendable (String) -> Void)? = nil,
        onLog: (@Sendable (String) -> Void)? = nil
    ) -> URL {
        do {
            let port = try ensureStarted()
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let safeExt = url.pathExtension.isEmpty ? (isHLS ? "m3u8" : "mp4") : url.pathExtension
            lock.lock()
            if routes.count > 512 {
                routes.removeAll()
                routeNormalLogCounts.removeAll()
            }
            routes[token] = ProxyRoute(
                upstreamURL: url,
                headers: headers,
                isHLS: isHLS || safeExt.lowercased() == "m3u8",
                onCookieUpdate: onCookieUpdate,
                onLog: onLog
            )
            lock.unlock()
            return URL(string: "http://127.0.0.1:\(port)/stream/\(token)/media.\(safeExt)") ?? url
        } catch {
            return url
        }
    }

    func registerSubResource(
        url: URL,
        inheritingFrom route: ProxyRoute,
        port: UInt16
    ) -> URL {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let ext = url.pathExtension.isEmpty ? "ts" : url.pathExtension
        lock.lock()
        if routes.count > 1024 {
            let keepKeys = Set(routes.keys.prefix(256))
            routes = routes.filter { keepKeys.contains($0.key) }
            routeNormalLogCounts = routeNormalLogCounts.filter { keepKeys.contains($0.key) }
        }
        routes[token] = ProxyRoute(
            upstreamURL: url,
            headers: route.headers,
            isHLS: ext.lowercased() == "m3u8",
            onCookieUpdate: route.onCookieUpdate,
            onLog: route.onLog
        )
        lock.unlock()
        return URL(string: "http://127.0.0.1:\(port)/sub/\(token)/seg.\(ext)") ?? url
    }

    func resetRoutes() {
        lock.lock()
        routes.removeAll()
        routeNormalLogCounts.removeAll()
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let active = listener
        listener = nil
        listeningPort = 0
        routes.removeAll()
        routeNormalLogCounts.removeAll()
        lock.unlock()
        active?.cancel()
    }

    private func route(forPath path: String) -> (token: String, route: ProxyRoute)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, (parts[0] == "stream" || parts[0] == "sub") else {
            return nil
        }
        let token = parts[1]
        lock.lock()
        let found = routes[token]
        lock.unlock()
        return found.map { (token, $0) }
    }

    private func updateCookie(_ newCookie: String, forToken token: String) {
        lock.lock()
        if var existing = routes[token] {
            existing.headers["Cookie"] = newCookie
            routes[token] = existing
        }
        lock.unlock()
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: networkQueue)
        receiveHTTPHeader(on: connection, accumulated: Data())
    }

    private func receiveHTTPHeader(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data {
                buffer.append(data)
            }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: 0..<range.lowerBound)
                let headText = String(data: headerData, encoding: .utf8) ?? ""
                self.dispatchHTTPRequest(headText: headText, connection: connection)
                return
            }
            if isComplete || buffer.count >= 65536 {
                connection.cancel()
                return
            }
            self.receiveHTTPHeader(on: connection, accumulated: buffer)
        }
    }

    private func dispatchHTTPRequest(headText: String, connection: NWConnection) {
        guard let parsed = Self.parseHTTPRequestHead(headText),
              let (token, matchedRoute) = route(forPath: parsed.path) else {
            sendSimpleResponse(connection: connection, status: "404 Not Found", body: Data("Not Found".utf8))
            return
        }

        lock.lock()
        let activePort = listeningPort
        lock.unlock()

        var upstreamReq = URLRequest(url: matchedRoute.upstreamURL, timeoutInterval: 12)
        upstreamReq.httpMethod = parsed.method == "HEAD" ? "HEAD" : "GET"
        for (k, v) in matchedRoute.headers {
            upstreamReq.setValue(v, forHTTPHeaderField: k)
        }
        if let rangeHeader = parsed.rangeHeader {
            upstreamReq.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }

        let upstreamHost = matchedRoute.upstreamURL.host ?? "upstream"
        let reqStartTime = CFAbsoluteTimeGetCurrent()
        let isManifest = matchedRoute.isHLS
            || matchedRoute.upstreamURL.pathExtension.lowercased() == "m3u8"
            || matchedRoute.upstreamURL.absoluteString.lowercased().contains(".m3u8")
        if isManifest {
            let redirectDelegate = RedirectHeaderPreservingDelegate(
                headers: matchedRoute.headers,
                rangeHeader: parsed.rangeHeader
            )
            let session = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)
            let task = session.dataTask(with: upstreamReq) { [weak self] data, response, error in
                defer { session.finishTasksAndInvalidate() }
                guard let self else {
                    connection.cancel()
                    return
                }
                let elapsedMs = Int(((CFAbsoluteTimeGetCurrent() - reqStartTime) * 1000).rounded())
                if let error {
                    let nsErr = error as NSError
                    let status = Self.httpErrorStatus(for: error)
                    self.emitRouteLog(
                        token: token,
                        route: matchedRoute,
                        important: true,
                        message: "[proxy][error] HLS \(upstreamHost) 失败: \(nsErr.domain)(\(nsErr.code)) \(error.localizedDescription) (\(elapsedMs)ms)"
                    )
                    self.sendSimpleResponse(
                        connection: connection,
                        status: status,
                        body: Data(error.localizedDescription.utf8)
                    )
                    return
                }
                guard let http = response as? HTTPURLResponse, let data else {
                    self.emitRouteLog(
                        token: token,
                        route: matchedRoute,
                        important: true,
                        message: "[proxy][error] HLS \(upstreamHost) 无 HTTP 响应 (\(elapsedMs)ms)"
                    )
                    self.sendSimpleResponse(connection: connection, status: "502 Bad Gateway", body: Data())
                    return
                }
                self.captureRefreshedCookies(from: http, route: matchedRoute, token: token)
                guard (200...299).contains(http.statusCode) else {
                    self.emitRouteLog(
                        token: token,
                        route: matchedRoute,
                        important: true,
                        message: "[proxy][error] HLS \(upstreamHost) HTTP \(http.statusCode) (\(elapsedMs)ms)"
                    )
                    self.sendSimpleResponse(
                        connection: connection,
                        status: "\(http.statusCode) Error",
                        body: data
                    )
                    return
                }

                self.emitRouteLog(
                    token: token,
                    route: matchedRoute,
                    important: false,
                    message: "[proxy] HLS \(upstreamHost) -> HTTP \(http.statusCode) (\(elapsedMs)ms)"
                )
                let rawManifest = String(data: data, encoding: .utf8) ?? ""
                let baseURL = http.url ?? matchedRoute.upstreamURL
                let rewritten = Self.rewriteHLSManifest(rawManifest, baseURL: baseURL) { childURL in
                    self.registerSubResource(url: childURL, inheritingFrom: matchedRoute, port: activePort)
                }
                let outData = Data(rewritten.utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl; charset=utf-8\r\nContent-Length: \(outData.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                var packet = Data(head.utf8)
                packet.append(outData)
                connection.send(content: packet, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
            task.resume()
            return
        }

        let streamRelay = UpstreamStreamRelay(
            connection: connection,
            headers: matchedRoute.headers,
            rangeHeader: parsed.rangeHeader,
            requestMethod: parsed.method,
            upstreamHost: upstreamHost,
            enableMP4HEV1Patch: parsed.method != "HEAD",
            onResponse: { [weak self] http in
                self?.captureRefreshedCookies(from: http, route: matchedRoute, token: token)
            },
            onLog: { [weak self] important, msg in
                self?.emitRouteLog(token: token, route: matchedRoute, important: important, message: msg)
            }
        )
        streamRelay.start(with: upstreamReq)
    }

    private func captureRefreshedCookies(from http: HTTPURLResponse, route: ProxyRoute, token: String) {
        guard let url = http.url ?? URL(string: "https://pan.quark.cn/"),
              let existingCookie = route.headers["Cookie"],
              !existingCookie.isEmpty else {
            return
        }
        let headerFields = http.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
            if let k = pair.key as? String, let v = pair.value as? String {
                acc[k] = v
            }
        }
        let parsedCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        guard !parsedCookies.isEmpty else { return }
        let setCookiePairs = parsedCookies.map { "\($0.name)=\($0.value)" }
        let merged = Self.mergeSetCookieHeaders(setCookiePairs, into: existingCookie)
        if merged != existingCookie {
            updateCookie(merged, forToken: token)
            route.onCookieUpdate?(merged)
        }
    }

    private func emitRouteLog(token: String, route: ProxyRoute, important: Bool, message: String) {
        guard let onLog = route.onLog else { return }
        if !important {
            lock.lock()
            let count = routeNormalLogCounts[token, default: 0]
            if count >= 2 {
                lock.unlock()
                return
            }
            routeNormalLogCounts[token] = count + 1
            lock.unlock()
        }
        onLog(message)
    }

    private func sendSimpleResponse(connection: NWConnection, status: String, body: Data) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func httpErrorStatus(for error: Error) -> String {
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorTimedOut {
            return "504 Gateway Timeout"
        }
        return "502 Bad Gateway"
    }

    // MARK: - Pure Testable Helpers

    static func parseHTTPRequestHead(_ raw: String) -> (method: String, path: String, rangeHeader: String?)? {
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return nil }
        let tokens = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 2 else { return nil }
        let method = String(tokens[0]).uppercased()
        let rawTarget = String(tokens[1])
        let pathOnly = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawTarget
        var rangeHeader: String?
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                if name == "range" {
                    rangeHeader = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }
        return (method: method, path: pathOnly, rangeHeader: rangeHeader)
    }

    static func mergeSetCookieHeaders(_ setCookies: [String], into existingCookie: String) -> String {
        var order: [String] = []
        var map: [String: String] = [:]

        func insertPair(_ rawPair: String) {
            let firstSegment = rawPair.split(separator: ";", maxSplits: 1).first.map(String.init) ?? rawPair
            guard let eq = firstSegment.firstIndex(of: "=") else { return }
            let key = firstSegment[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = firstSegment[firstSegment.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            if map[key] == nil {
                order.append(key)
            }
            map[key] = value
        }

        for part in existingCookie.split(separator: ";") {
            insertPair(String(part))
        }
        for setCookie in setCookies {
            insertPair(setCookie)
        }
        return order.compactMap { k in map[k].map { "\(k)=\($0)" } }.joined(separator: "; ")
    }

    static func rewriteHLSManifest(
        _ manifest: String,
        baseURL: URL,
        rewriteURL: (URL) -> URL
    ) -> String {
        let lines = manifest.components(separatedBy: .newlines)
        let rewritten = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            if trimmed.hasPrefix("#") {
                return rewriteURIAttributes(inTagLine: line, baseURL: baseURL, rewriteURL: rewriteURL)
            }
            guard let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else {
                return line
            }
            return rewriteURL(resolved).absoluteString
        }
        return rewritten.joined(separator: "\n")
    }

    private static func rewriteURIAttributes(
        inTagLine line: String,
        baseURL: URL,
        rewriteURL: (URL) -> URL
    ) -> String {
        guard let searchStart = line.range(of: "URI=\"") else {
            return line
        }
        let afterOpen = searchStart.upperBound
        guard let closeQuote = line[afterOpen...].firstIndex(of: "\"") else {
            return line
        }
        let rawURI = String(line[afterOpen..<closeQuote])
        guard let resolved = URL(string: rawURI, relativeTo: baseURL)?.absoluteURL else {
            return line
        }
        let replaced = rewriteURL(resolved).absoluteString
        var updated = line
        updated.replaceSubrange(afterOpen..<closeQuote, with: replaced)
        return updated
    }

    /// 将 ISO BMFF MP4 `stsd` 容器内的 `hev1` SampleEntry 类型字节无损原地改写为 Apple `AVPlayer` 支持的 `hvc1`。
    /// 严格校验 Box 长度、保留字段、`data_reference_index`、合理分辨率、`depth=0x0018`、`pre_defined=0xFFFF` 与子 Box `hvcC`，
    /// 避免误伤 `mdat` 媒体负载中的偶然字节序列。
    static func patchHEV1ToHVC1(in data: inout Data) -> Int {
        let start = data.startIndex
        let end = data.endIndex
        guard end - start >= 90 else { return 0 }
        var patched = 0
        var i = start + 4
        while i + 86 <= end {
            if data[i] == 0x68 && data[i + 1] == 0x65 && data[i + 2] == 0x76 && data[i + 3] == 0x31 {
                let boxSize = (UInt32(data[i - 4]) << 24)
                    | (UInt32(data[i - 3]) << 16)
                    | (UInt32(data[i - 2]) << 8)
                    | UInt32(data[i - 1])
                if boxSize >= 94 && boxSize <= 65536 {
                    let reservedZero = data[i + 4] == 0 && data[i + 5] == 0 && data[i + 6] == 0
                        && data[i + 7] == 0 && data[i + 8] == 0 && data[i + 9] == 0
                    let dataRefIdx = (UInt16(data[i + 10]) << 8) | UInt16(data[i + 11])
                    let width = (UInt16(data[i + 28]) << 8) | UInt16(data[i + 29])
                    let height = (UInt16(data[i + 30]) << 8) | UInt16(data[i + 31])
                    let depth = (UInt16(data[i + 78]) << 8) | UInt16(data[i + 79])
                    let preDefined = (UInt16(data[i + 80]) << 8) | UInt16(data[i + 81])
                    if reservedZero,
                       (1...255).contains(dataRefIdx),
                       (16...16384).contains(width),
                       (16...16384).contains(height),
                       depth == 0x0018,
                       preDefined == 0xFFFF {
                        let boxEnd = min(end, min(i + 240, i - 4 + Int(boxSize)))
                        var hasHVCC = false
                        if i + 82 + 4 <= boxEnd {
                            var j = i + 82
                            while j + 4 <= boxEnd {
                                if data[j] == 0x68 && data[j + 1] == 0x76 && data[j + 2] == 0x63 && data[j + 3] == 0x43 {
                                    hasHVCC = true
                                    break
                                }
                                j += 1
                            }
                        }
                        if hasHVCC {
                            data[i + 1] = 0x76
                            data[i + 2] = 0x63
                            patched += 1
                            i += 86
                            continue
                        }
                    }
                }
            }
            i += 1
        }
        return patched
    }
}

struct MP4HEV1StreamPatcher: Sendable {
    private var tail = Data()
    private let overlapSize: Int = 256

    mutating func processChunk(_ chunk: Data) -> Data {
        guard !chunk.isEmpty else { return Data() }
        tail.append(chunk)
        _ = LocalHTTPStreamProxy.patchHEV1ToHVC1(in: &tail)
        guard tail.count > overlapSize else {
            return Data()
        }
        let emitCount = tail.count - overlapSize
        let out = Data(tail.prefix(emitCount))
        tail = Data(tail.suffix(overlapSize))
        return out
    }

    mutating func flush() -> Data {
        guard !tail.isEmpty else { return Data() }
        _ = LocalHTTPStreamProxy.patchHEV1ToHVC1(in: &tail)
        let out = tail
        tail.removeAll(keepingCapacity: false)
        return out
    }
}

private final class RedirectHeaderPreservingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let headers: [String: String]
    private let rangeHeader: String?

    init(headers: [String: String], rangeHeader: String?) {
        self.headers = headers
        self.rangeHeader = rangeHeader
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var next = request
        for (k, v) in headers {
            next.setValue(v, forHTTPHeaderField: k)
        }
        if let rangeHeader {
            next.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }
        completionHandler(next)
    }
}

private final class ProxyUpstreamSessionPool: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = ProxyUpstreamSessionPool()

    private let lock = NSLock()
    private var relays: [Int: UpstreamStreamRelay] = [:]
    private var session: URLSession!

    private override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 1800
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func startTask(with request: URLRequest, relay: UpstreamStreamRelay) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        lock.lock()
        relays[task.taskIdentifier] = relay
        lock.unlock()
        task.resume()
        return task
    }

    func removeTask(withIdentifier taskId: Int) {
        lock.lock()
        relays.removeValue(forKey: taskId)
        lock.unlock()
    }

    private func relay(for task: URLSessionTask) -> UpstreamStreamRelay? {
        lock.lock()
        let found = relays[task.taskIdentifier]
        lock.unlock()
        return found
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let relay = relay(for: task) {
            relay.handleRedirect(newRequest: request, completionHandler: completionHandler)
        } else {
            completionHandler(request)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let relay = relay(for: dataTask) {
            relay.handleResponse(response, completionHandler: completionHandler)
        } else {
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        relay(for: dataTask)?.handleData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let relay = relays.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        relay?.handleCompletion(error: error)
    }
}

private final class UpstreamStreamRelay: @unchecked Sendable {
    private let connection: NWConnection
    private let headers: [String: String]
    private let rangeHeader: String?
    private let requestMethod: String
    private let upstreamHost: String
    private let enableMP4HEV1Patch: Bool
    private let onResponse: @Sendable (HTTPURLResponse) -> Void
    private let onLog: @Sendable (Bool, String) -> Void
    private let lock = NSLock()
    private let startTimestamp = CFAbsoluteTimeGetCurrent()
    private var dataTask: URLSessionDataTask?
    private var didFinish = false
    private var didSendHeaders = false
    private var shouldPatchMP4Stream = false
    private var mp4Patcher = MP4HEV1StreamPatcher()

    init(
        connection: NWConnection,
        headers: [String: String],
        rangeHeader: String?,
        requestMethod: String = "GET",
        upstreamHost: String = "upstream",
        enableMP4HEV1Patch: Bool = true,
        onResponse: @escaping @Sendable (HTTPURLResponse) -> Void,
        onLog: @escaping @Sendable (Bool, String) -> Void
    ) {
        self.connection = connection
        self.headers = headers
        self.rangeHeader = rangeHeader
        self.requestMethod = requestMethod
        self.upstreamHost = upstreamHost
        self.enableMP4HEV1Patch = enableMP4HEV1Patch
        self.onResponse = onResponse
        self.onLog = onLog
    }

    func start(with request: URLRequest) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.cancelAll()
            } else if case .failed = state {
                self?.cancelAll()
            }
        }
        let task = ProxyUpstreamSessionPool.shared.startTask(with: request, relay: self)
        lock.lock()
        if didFinish {
            lock.unlock()
            ProxyUpstreamSessionPool.shared.removeTask(withIdentifier: task.taskIdentifier)
            task.cancel()
            return
        }
        self.dataTask = task
        lock.unlock()
    }

    private func cancelAll() {
        lock.lock()
        let task = dataTask
        didFinish = true
        dataTask = nil
        lock.unlock()
        if let task {
            ProxyUpstreamSessionPool.shared.removeTask(withIdentifier: task.taskIdentifier)
            task.cancel()
        }
    }

    func handleRedirect(
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var next = request
        for (k, v) in headers {
            next.setValue(v, forHTTPHeaderField: k)
        }
        if let rangeHeader {
            next.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }
        completionHandler(next)
    }

    func handleResponse(
        _ response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            connection.cancel()
            return
        }
        onResponse(http)
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        let isMP4OrBinary = !contentType.lowercased().contains("mpegurl") && !contentType.lowercased().contains("text/")
        lock.lock()
        shouldPatchMP4Stream = enableMP4HEV1Patch && (200...299).contains(http.statusCode) && isMP4OrBinary
        didSendHeaders = true
        lock.unlock()

        let elapsedMs = Int(((CFAbsoluteTimeGetCurrent() - startTimestamp) * 1000).rounded())
        let isImportant = http.statusCode >= 400
        let rangeDesc = rangeHeader ?? "full"
        onLog(isImportant, "[proxy] \(requestMethod) \(upstreamHost) -> HTTP \(http.statusCode) (\(elapsedMs)ms, range=\(rangeDesc))")

        var headerLines = ["HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))"]
        headerLines.append("Content-Type: \(contentType)")
        if let len = http.value(forHTTPHeaderField: "Content-Length") {
            headerLines.append("Content-Length: \(len)")
        }
        if let range = http.value(forHTTPHeaderField: "Content-Range") {
            headerLines.append("Content-Range: \(range)")
        }
        headerLines.append("Accept-Ranges: bytes")
        headerLines.append("Connection: close")
        let headPacket = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        connection.send(content: headPacket, completion: .contentProcessed { _ in })
        completionHandler(.allow)
    }

    func handleData(_ data: Data) {
        guard !data.isEmpty else { return }
        let outgoing: Data
        lock.lock()
        if shouldPatchMP4Stream {
            outgoing = mp4Patcher.processChunk(data)
        } else {
            outgoing = data
        }
        lock.unlock()
        guard !outgoing.isEmpty else { return }
        connection.send(content: outgoing, completion: .contentProcessed { _ in })
    }

    func handleCompletion(error: Error?) {
        lock.lock()
        let alreadyFinished = didFinish
        let sentHeaders = didSendHeaders
        didFinish = true
        self.dataTask = nil
        let trailing = shouldPatchMP4Stream ? mp4Patcher.flush() : Data()
        lock.unlock()
        guard !alreadyFinished else { return }

        if let error, !sentHeaders {
            let elapsedMs = Int(((CFAbsoluteTimeGetCurrent() - startTimestamp) * 1000).rounded())
            let nsErr = error as NSError
            if !(nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled) {
                onLog(true, "[proxy][error] \(upstreamHost) 请求失败: \(nsErr.domain)(\(nsErr.code)) \(error.localizedDescription) (\(elapsedMs)ms)")
            }
            let status = LocalHTTPStreamProxy.httpErrorStatus(for: error)
            let body = Data(error.localizedDescription.utf8)
            let head = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var packet = Data(head.utf8)
            packet.append(body)
            connection.send(content: packet, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
            return
        }

        if let error {
            let elapsedMs = Int(((CFAbsoluteTimeGetCurrent() - startTimestamp) * 1000).rounded())
            let nsErr = error as NSError
            if !(nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled) {
                onLog(true, "[proxy][warn] \(upstreamHost) 传输中断: \(nsErr.domain)(\(nsErr.code)) \(error.localizedDescription) (\(elapsedMs)ms)")
            }
        }

        if !trailing.isEmpty {
            connection.send(content: trailing, completion: .contentProcessed { _ in })
        }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }
}
