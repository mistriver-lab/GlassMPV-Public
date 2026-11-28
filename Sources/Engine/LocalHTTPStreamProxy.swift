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
    private var chunkCaches: [String: ProxyRouteChunkCache] = [:]
    private var chunkCacheOrder: [String] = []

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
            let urlLower = url.absoluteString.lowercased()
            let rawExt = url.pathExtension
            let urlLooksLikeM3U8 = (rawExt.lowercased() == "m3u8" || urlLower.contains(".m3u8"))
            let resolvedIsHLS = isHLS || urlLooksLikeM3U8
            let safeExt: String
            if urlLooksLikeM3U8 {
                safeExt = "m3u8"
            } else if isHLS && rawExt.isEmpty {
                // 扩展名缺失但标记 HLS 的入口不强行拼接 .m3u8 后缀，避免上游实为 fmp4/mp4 时触发 AVPlayer -1002
                safeExt = "stream"
            } else if rawExt.isEmpty || rawExt.lowercased() == "m3u8" {
                safeExt = "mp4"
            } else {
                safeExt = rawExt
            }
            var evictedCaches: [ProxyRouteChunkCache] = []
            lock.lock()
            if routes.count > 512 {
                routes.removeAll()
                routeNormalLogCounts.removeAll()
            }
            let route = ProxyRoute(
                upstreamURL: url,
                headers: headers,
                isHLS: resolvedIsHLS,
                onCookieUpdate: onCookieUpdate,
                onLog: onLog
            )
            routes[token] = route
            if !resolvedIsHLS {
                let cacheKey = url.absoluteString
                if let existing = chunkCaches[cacheKey] {
                    existing.updateHeaders(headers)
                    chunkCacheOrder.removeAll { $0 == cacheKey }
                    chunkCacheOrder.append(cacheKey)
                } else {
                    chunkCaches[cacheKey] = ProxyRouteChunkCache(
                        upstreamURL: url,
                        headers: headers,
                        onCookieResponse: { [weak self] http in
                            self?.captureRefreshedCookies(from: http, route: route, token: token)
                        },
                        onLog: { [weak self] important, msg in
                            self?.emitRouteLog(token: token, route: route, important: important, message: msg)
                        }
                    )
                    chunkCacheOrder.append(cacheKey)
                    while chunkCacheOrder.count > 2 {
                        let oldestKey = chunkCacheOrder.removeFirst()
                        if let removed = chunkCaches.removeValue(forKey: oldestKey) {
                            evictedCaches.append(removed)
                        }
                    }
                }
            }
            lock.unlock()
            for cache in evictedCaches {
                cache.invalidate()
            }
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

    func cancelActiveChunkCaches() {
        lock.lock()
        let caches = Array(chunkCaches.values)
        chunkCaches.removeAll()
        chunkCacheOrder.removeAll()
        lock.unlock()
        for cache in caches {
            cache.invalidate()
        }
    }

    func resetRoutes() {
        lock.lock()
        routes.removeAll()
        routeNormalLogCounts.removeAll()
        let caches = Array(chunkCaches.values)
        chunkCaches.removeAll()
        chunkCacheOrder.removeAll()
        lock.unlock()
        for cache in caches {
            cache.invalidate()
        }
    }

    func stop() {
        lock.lock()
        let active = listener
        listener = nil
        listeningPort = 0
        routes.removeAll()
        routeNormalLogCounts.removeAll()
        let caches = Array(chunkCaches.values)
        chunkCaches.removeAll()
        chunkCacheOrder.removeAll()
        lock.unlock()
        for cache in caches {
            cache.invalidate()
        }
        active?.cancel()
    }

    private func chunkCache(for route: ProxyRoute) -> ProxyRouteChunkCache? {
        guard !route.isHLS else { return nil }
        lock.lock()
        let found = chunkCaches[route.upstreamURL.absoluteString]
        lock.unlock()
        return found
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
        let isManifest = matchedRoute.isHLS
            || matchedRoute.upstreamURL.pathExtension.lowercased() == "m3u8"
            || matchedRoute.upstreamURL.absoluteString.lowercased().contains(".m3u8")

        if parsed.method == "GET",
           !isManifest,
           let routeChunkCache = chunkCache(for: matchedRoute),
           let totalLen = routeChunkCache.knownTotalLength,
           totalLen >= 4 * 1024 * 1024,
           let byteRange = parsed.rangeHeader.flatMap({ Self.parseByteRangeHeader($0, totalLength: totalLen) })
               ?? (parsed.rangeHeader == nil ? (start: Int64(0), end: totalLen - 1) : nil),
           (byteRange.end - byteRange.start + 1) > Int64(ProxyRouteChunkCache.chunkSize) {
            let parallelRelay = ParallelChunkedStreamRelay(
                connection: connection,
                chunkCache: routeChunkCache,
                rangeStart: byteRange.start,
                rangeEnd: byteRange.end,
                totalLength: totalLen,
                hadRangeHeader: parsed.rangeHeader != nil,
                upstreamHost: upstreamHost,
                enableMP4HEV1Patch: true,
                onLog: { [weak self] important, msg in
                    self?.emitRouteLog(token: token, route: matchedRoute, important: important, message: msg)
                }
            )
            parallelRelay.start()
            return
        }

        let manifestRewriter: (@Sendable (String, URL) -> String)?
        if isManifest && parsed.method != "HEAD" {
            manifestRewriter = { [weak self] (rawManifest: String, resolvedBaseURL: URL) -> String in
                guard let self else { return rawManifest }
                return Self.rewriteHLSManifest(rawManifest, baseURL: resolvedBaseURL) { childURL in
                    self.registerSubResource(url: childURL, inheritingFrom: matchedRoute, port: activePort)
                }
            }
        } else {
            manifestRewriter = nil
        }
        let matchedCache = isManifest ? nil : chunkCache(for: matchedRoute)
        let streamRelay = UpstreamStreamRelay(
            connection: connection,
            headers: matchedRoute.headers,
            rangeHeader: parsed.rangeHeader,
            requestMethod: parsed.method,
            upstreamHost: upstreamHost,
            enableMP4HEV1Patch: parsed.method != "HEAD",
            chunkCache: matchedCache,
            hlsManifestRewriter: manifestRewriter,
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

    static func parseContentRangeTotalLength(_ contentRange: String?) -> Int64? {
        guard let contentRange else { return nil }
        guard let slashIdx = contentRange.lastIndex(of: "/") else { return nil }
        let suffix = contentRange[contentRange.index(after: slashIdx)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard suffix != "*", let total = Int64(suffix), total > 0 else { return nil }
        return total
    }

    static func parseByteRangeHeader(_ rangeHeader: String?, totalLength: Int64) -> (start: Int64, end: Int64)? {
        guard totalLength > 0, let raw = rangeHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        guard raw.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = String(raw.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.isEmpty, !spec.contains(",") else { return nil }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let left = parts[0].trimmingCharacters(in: .whitespaces)
        let right = parts[1].trimmingCharacters(in: .whitespaces)
        if left.isEmpty, !right.isEmpty {
            guard let suffixLen = Int64(right), suffixLen > 0 else { return nil }
            let start = max(0, totalLength - suffixLen)
            return (start: start, end: totalLength - 1)
        }
        guard !left.isEmpty, let start = Int64(left), start >= 0, start < totalLength else {
            return nil
        }
        if right.isEmpty {
            return (start: start, end: totalLength - 1)
        }
        guard let rawEnd = Int64(right), rawEnd >= start else {
            return nil
        }
        return (start: start, end: min(rawEnd, totalLength - 1))
    }

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
    private enum Mode: Sendable {
        case legacyRawScan
        case boxAware(BoxState)
        case probeMidRange
        case passthrough
    }

    private enum BoxState: Sendable {
        case readingHeader
        case skippingMdat(remaining: UInt64)
        case scanningBox(remaining: UInt64)
    }

    private var mode: Mode
    private var tail = Data()
    private let overlapSize: Int = 256
    private var didValidateFirstBox: Bool = false

    init() {
        self.mode = .legacyRawScan
    }

    init(startsAtFileOffsetZero: Bool) {
        self.mode = startsAtFileOffsetZero ? .boxAware(.readingHeader) : .probeMidRange
    }

    mutating func processChunk(_ chunk: Data) -> Data {
        guard !chunk.isEmpty else { return Data() }

        switch mode {
        case .passthrough:
            return chunk

        case .legacyRawScan:
            tail.append(chunk)
            _ = LocalHTTPStreamProxy.patchHEV1ToHVC1(in: &tail)
            guard tail.count > overlapSize else {
                return Data()
            }
            let emitCount = tail.count - overlapSize
            let out = Data(tail.prefix(emitCount))
            tail = Data(tail.suffix(overlapSize))
            return out

        case .boxAware(.skippingMdat(let remaining)) where tail.isEmpty:
            let chunkCount = UInt64(chunk.count)
            if chunkCount <= remaining {
                let left = remaining - chunkCount
                mode = .boxAware(left == 0 ? .readingHeader : .skippingMdat(remaining: left))
                return chunk
            }
            let prefixLen = Int(remaining)
            var out = Data(chunk.prefix(prefixLen))
            tail = Data(chunk.suffix(chunk.count - prefixLen))
            mode = .boxAware(.readingHeader)
            out.append(drainBoxAware())
            return out

        case .boxAware:
            tail.append(chunk)
            return drainBoxAware()

        case .probeMidRange:
            tail.append(chunk)
            return drainProbeMidRange()
        }
    }

    mutating func flush() -> Data {
        guard !tail.isEmpty else { return Data() }
        switch mode {
        case .passthrough:
            let out = tail
            tail.removeAll(keepingCapacity: false)
            return out
        case .legacyRawScan:
            _ = LocalHTTPStreamProxy.patchHEV1ToHVC1(in: &tail)
            let out = tail
            tail.removeAll(keepingCapacity: false)
            return out
        case .probeMidRange:
            if Self.containsMetadataSignature(in: tail) {
                _ = LocalHTTPStreamProxy.patchHEV1ToHVC1(in: &tail)
            }
            let out = tail
            tail.removeAll(keepingCapacity: false)
            mode = .passthrough
            return out
        case .boxAware(let boxState):
            switch boxState {
            case .readingHeader, .skippingMdat:
                let out = tail
                tail.removeAll(keepingCapacity: false)
                return out
            case .scanningBox:
                _ = LocalHTTPStreamProxy.patchHEV1ToHVC1(in: &tail)
                let out = tail
                tail.removeAll(keepingCapacity: false)
                return out
            }
        }
    }

    private mutating func drainProbeMidRange() -> Data {
        guard tail.count >= 8 else { return Data() }
        if let topHeader = Self.parseTopBoxHeader(in: tail),
           Self.isKnownTopLevelBoxFourCC(topHeader.fourCC) {
            didValidateFirstBox = true
            mode = .boxAware(.readingHeader)
            return drainBoxAware()
        }
        if let moovRange = tail.range(of: Data("moov".utf8)), moovRange.lowerBound >= 4 {
            let boxStart = moovRange.lowerBound - 4
            if let moovHeader = Self.parseTopBoxHeader(in: tail, at: boxStart),
               moovHeader.fourCC == "moov" {
                let prefix = Data(tail.prefix(boxStart))
                tail = Data(tail.suffix(tail.count - boxStart))
                didValidateFirstBox = true
                mode = .boxAware(.readingHeader)
                var out = prefix
                out.append(drainBoxAware())
                return out
            }
        }
        if Self.containsMetadataSignature(in: tail) {
            mode = .legacyRawScan
            _ = LocalHTTPStreamProxy.patchHEV1ToHVC1(in: &tail)
            guard tail.count > overlapSize else { return Data() }
            let emitCount = tail.count - overlapSize
            let out = Data(tail.prefix(emitCount))
            tail = Data(tail.suffix(overlapSize))
            return out
        }
        if tail.count >= 65536 {
            let out = tail
            tail.removeAll(keepingCapacity: false)
            mode = .passthrough
            return out
        }
        return Data()
    }

    private mutating func drainBoxAware() -> Data {
        var output = Data()
        while true {
            guard case .boxAware(let boxState) = mode else {
                if !tail.isEmpty {
                    output.append(tail)
                    tail.removeAll(keepingCapacity: false)
                }
                return output
            }
            switch boxState {
            case .readingHeader:
                guard let header = Self.parseTopBoxHeader(in: tail) else {
                    return output
                }
                if !didValidateFirstBox {
                    guard Self.isKnownTopLevelBoxFourCC(header.fourCC) else {
                        output.append(tail)
                        tail.removeAll(keepingCapacity: false)
                        mode = .passthrough
                        return output
                    }
                    didValidateFirstBox = true
                }
                if header.fourCC == "mdat" {
                    output.append(tail.prefix(header.headerSize))
                    tail = Data(tail.suffix(tail.count - header.headerSize))
                    if header.sizeField == 0 {
                        if !tail.isEmpty {
                            output.append(tail)
                            tail.removeAll(keepingCapacity: false)
                        }
                        mode = .passthrough
                        return output
                    }
                    let payloadBytes = header.totalBoxSize - UInt64(header.headerSize)
                    mode = .boxAware(payloadBytes == 0 ? .readingHeader : .skippingMdat(remaining: payloadBytes))
                } else if header.sizeField == 0 {
                    mode = .legacyRawScan
                    _ = LocalHTTPStreamProxy.patchHEV1ToHVC1(in: &tail)
                    if tail.count > overlapSize {
                        let emitCount = tail.count - overlapSize
                        output.append(tail.prefix(emitCount))
                        tail = Data(tail.suffix(overlapSize))
                    }
                    return output
                } else {
                    mode = .boxAware(.scanningBox(remaining: header.totalBoxSize))
                }

            case .skippingMdat(let remaining):
                guard !tail.isEmpty else { return output }
                let available = UInt64(tail.count)
                if available <= remaining {
                    output.append(tail)
                    tail.removeAll(keepingCapacity: false)
                    let left = remaining - available
                    mode = .boxAware(left == 0 ? .readingHeader : .skippingMdat(remaining: left))
                    return output
                }
                let take = Int(remaining)
                output.append(tail.prefix(take))
                tail = Data(tail.suffix(tail.count - take))
                mode = .boxAware(.readingHeader)

            case .scanningBox(let remaining):
                guard !tail.isEmpty else { return output }
                if UInt64(tail.count) >= remaining {
                    let take = Int(remaining)
                    var boxData = Data(tail.prefix(take))
                    _ = LocalHTTPStreamProxy.patchHEV1ToHVC1(in: &boxData)
                    output.append(boxData)
                    tail = Data(tail.suffix(tail.count - take))
                    mode = .boxAware(.readingHeader)
                } else {
                    _ = LocalHTTPStreamProxy.patchHEV1ToHVC1(in: &tail)
                    guard tail.count > overlapSize else {
                        return output
                    }
                    let emitCount = tail.count - overlapSize
                    output.append(tail.prefix(emitCount))
                    tail = Data(tail.suffix(overlapSize))
                    mode = .boxAware(.scanningBox(remaining: remaining - UInt64(emitCount)))
                    return output
                }
            }
        }
    }

    private struct TopBoxHeader {
        let headerSize: Int
        let sizeField: UInt32
        let totalBoxSize: UInt64
        let fourCC: String
    }

    private static func parseTopBoxHeader(in data: Data, at offset: Int = 0) -> TopBoxHeader? {
        let available = data.count - offset
        guard available >= 8 else { return nil }
        let start = data.startIndex + offset
        let size32 = (UInt32(data[start]) << 24)
            | (UInt32(data[start + 1]) << 16)
            | (UInt32(data[start + 2]) << 8)
            | UInt32(data[start + 3])
        let fourCCBytes = data[(start + 4)..<(start + 8)]
        guard fourCCBytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }),
              let fourCC = String(bytes: fourCCBytes, encoding: .ascii) else {
            return nil
        }
        if size32 == 1 {
            guard available >= 16 else { return nil }
            var size64: UInt64 = 0
            for idx in 8..<16 {
                size64 = (size64 << 8) | UInt64(data[start + idx])
            }
            guard size64 >= 16 else { return nil }
            return TopBoxHeader(headerSize: 16, sizeField: 1, totalBoxSize: size64, fourCC: fourCC)
        }
        if size32 == 0 {
            return TopBoxHeader(headerSize: 8, sizeField: 0, totalBoxSize: 0, fourCC: fourCC)
        }
        guard size32 >= 8 else { return nil }
        return TopBoxHeader(headerSize: 8, sizeField: size32, totalBoxSize: UInt64(size32), fourCC: fourCC)
    }

    private static func isKnownTopLevelBoxFourCC(_ fourCC: String) -> Bool {
        switch fourCC {
        case "ftyp", "moov", "mdat", "moof", "free", "skip", "wide", "meta", "sidx", "styp", "emsg", "uuid", "pdin", "mfra", "prft":
            return true
        default:
            return false
        }
    }

    private static func containsMetadataSignature(in data: Data) -> Bool {
        data.range(of: Data("moov".utf8)) != nil
            || data.range(of: Data("stsd".utf8)) != nil
            || data.range(of: Data("hvcC".utf8)) != nil
    }
}

private protocol ProxySessionTaskHandler: AnyObject, Sendable {
    func handleRedirect(newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void)
    func handleResponse(_ response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void)
    func handleData(_ data: Data)
    func handleCompletion(error: Error?)
}

private final class ProxyUpstreamSessionPool: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = ProxyUpstreamSessionPool()

    private let lock = NSLock()
    private var handlers: [Int: any ProxySessionTaskHandler] = [:]
    private var session: URLSession!

    private override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 1800
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func startTask(with request: URLRequest, handler: any ProxySessionTaskHandler) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        lock.lock()
        handlers[task.taskIdentifier] = handler
        lock.unlock()
        task.resume()
        return task
    }

    func removeTask(withIdentifier taskId: Int) {
        lock.lock()
        handlers.removeValue(forKey: taskId)
        lock.unlock()
    }

    private func handler(for task: URLSessionTask) -> (any ProxySessionTaskHandler)? {
        lock.lock()
        let found = handlers[task.taskIdentifier]
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
        if let handler = handler(for: task) {
            handler.handleRedirect(newRequest: request, completionHandler: completionHandler)
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
        if let handler = handler(for: dataTask) {
            handler.handleResponse(response, completionHandler: completionHandler)
        } else {
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handler(for: dataTask)?.handleData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let handler = handlers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        handler?.handleCompletion(error: error)
    }
}

private final class UpstreamStreamRelay: ProxySessionTaskHandler, @unchecked Sendable {
    private static let maxManifestBytes: Int = 4 * 1024 * 1024

    private let connection: NWConnection
    private let headers: [String: String]
    private let rangeHeader: String?
    private let requestMethod: String
    private let upstreamHost: String
    private let enableMP4HEV1Patch: Bool
    private weak var chunkCache: ProxyRouteChunkCache?
    private let hlsManifestRewriter: (@Sendable (String, URL) -> String)?
    private let onResponse: @Sendable (HTTPURLResponse) -> Void
    private let onLog: @Sendable (Bool, String) -> Void
    private let lock = NSLock()
    private let startTimestamp = CFAbsoluteTimeGetCurrent()
    private var dataTask: URLSessionDataTask?
    private var didFinish = false
    private var didSendHeaders = false
    private var shouldPatchMP4Stream = false
    private var mp4Patcher = MP4HEV1StreamPatcher()
    private var isBufferingManifest = false
    private var manifestData = Data()
    private var manifestBaseURL: URL?
    private var manifestStatusCode: Int = 200
    private var manifestHeaderPacket: Data?
    private var inFlightBytes: Int = 0
    private var isUpstreamSuspended = false
    private let highWaterBytes: Int = 4 * 1024 * 1024
    private let lowWaterBytes: Int = 1 * 1024 * 1024

    init(
        connection: NWConnection,
        headers: [String: String],
        rangeHeader: String?,
        requestMethod: String = "GET",
        upstreamHost: String = "upstream",
        enableMP4HEV1Patch: Bool = true,
        chunkCache: ProxyRouteChunkCache? = nil,
        hlsManifestRewriter: (@Sendable (String, URL) -> String)? = nil,
        onResponse: @escaping @Sendable (HTTPURLResponse) -> Void,
        onLog: @escaping @Sendable (Bool, String) -> Void
    ) {
        self.connection = connection
        self.headers = headers
        self.rangeHeader = rangeHeader
        self.requestMethod = requestMethod
        self.upstreamHost = upstreamHost
        self.enableMP4HEV1Patch = enableMP4HEV1Patch
        self.chunkCache = chunkCache
        self.hlsManifestRewriter = hlsManifestRewriter
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
        let task = ProxyUpstreamSessionPool.shared.startTask(with: request, handler: self)
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
        let wasSuspended = isUpstreamSuspended
        isUpstreamSuspended = false
        didFinish = true
        dataTask = nil
        lock.unlock()
        if let task {
            ProxyUpstreamSessionPool.shared.removeTask(withIdentifier: task.taskIdentifier)
            if wasSuspended {
                task.resume()
            }
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
        let ctLower = contentType.lowercased()
        let isMP4OrBinary = !ctLower.contains("mpegurl") && !ctLower.contains("text/")
        let contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? ""
        let startsAtZero = (http.statusCode == 200) || contentRange.lowercased().hasPrefix("bytes 0-")
        let contentLengthVal = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
        let expectedLen = contentLengthVal ?? http.expectedContentLength
        let parsedTotal = LocalHTTPStreamProxy.parseContentRangeTotalLength(contentRange)
            ?? (http.statusCode == 200 ? contentLengthVal : nil)
        if isMP4OrBinary, (200...299).contains(http.statusCode), let cache = chunkCache {
            cache.setKnownContentType(contentType)
            if let parsedTotal, parsedTotal >= 4 * 1024 * 1024 {
                cache.setKnownTotalLength(parsedTotal)
                if requestMethod == "GET", rangeHeader == "bytes=0-1" {
                    cache.prefetchAhead(startingAfter: -1)
                }
            }
        }

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

        let totalOrExpected = parsedTotal ?? expectedLen
        let shouldBufferManifest = hlsManifestRewriter != nil
            && requestMethod != "HEAD"
            && (200...299).contains(http.statusCode)
            && !ctLower.contains("video/")
            && !ctLower.contains("audio/")
            && totalOrExpected <= Int64(Self.maxManifestBytes)

        lock.lock()
        shouldPatchMP4Stream = enableMP4HEV1Patch && (200...299).contains(http.statusCode) && isMP4OrBinary
        if shouldPatchMP4Stream {
            mp4Patcher = MP4HEV1StreamPatcher(startsAtFileOffsetZero: startsAtZero)
        }
        if shouldBufferManifest {
            isBufferingManifest = true
            manifestData.removeAll(keepingCapacity: true)
            manifestBaseURL = http.url
            manifestStatusCode = http.statusCode
            manifestHeaderPacket = headPacket
            didSendHeaders = false
            lock.unlock()
            completionHandler(.allow)
            return
        }
        didSendHeaders = true
        lock.unlock()

        let elapsedMs = Int(((CFAbsoluteTimeGetCurrent() - startTimestamp) * 1000).rounded())
        let isImportant = http.statusCode >= 400
        let rangeDesc = rangeHeader ?? "full"
        let pathSuffix = isImportant ? " path=...\(String((http.url?.path ?? "").suffix(48)))" : ""
        onLog(isImportant, "[proxy] \(requestMethod) \(upstreamHost) -> HTTP \(http.statusCode) (\(elapsedMs)ms, range=\(rangeDesc))\(pathSuffix)")

        connection.send(content: headPacket, completion: .contentProcessed { _ in })
        completionHandler(.allow)
    }

    private static func isLikelyTextManifestPrefix(_ data: Data) -> Bool? {
        var idx = data.startIndex
        if data.count >= 3,
           data[idx] == 0xEF,
           data[idx + 1] == 0xBB,
           data[idx + 2] == 0xBF {
            idx += 3
        }
        while idx < data.endIndex {
            let byte = data[idx]
            if byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A {
                idx += 1
                continue
            }
            return byte == 0x23
        }
        return nil
    }

    func handleData(_ data: Data) {
        guard !data.isEmpty else { return }
        var fallbackHeader: Data?
        var payloadToStream = data
        var taskToSuspend: URLSessionDataTask?

        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        if isBufferingManifest {
            manifestData.append(data)
            let looksLikeManifest = Self.isLikelyTextManifestPrefix(manifestData)
            if manifestData.count <= Self.maxManifestBytes && looksLikeManifest != false {
                lock.unlock()
                return
            }
            // 上游返回非 #EXTM3U 二进制流（如误标 HLS 的 fmp4/mp4），立即无缝退化为二进制透传
            isBufferingManifest = false
            didSendHeaders = true
            shouldPatchMP4Stream = enableMP4HEV1Patch
            mp4Patcher = MP4HEV1StreamPatcher(startsAtFileOffsetZero: rangeHeader == nil || rangeHeader?.lowercased().hasPrefix("bytes=0-") == true)
            fallbackHeader = manifestHeaderPacket
            manifestHeaderPacket = nil
            payloadToStream = manifestData
            manifestData.removeAll(keepingCapacity: false)
        }

        let outgoing: Data
        if shouldPatchMP4Stream {
            outgoing = mp4Patcher.processChunk(payloadToStream)
        } else {
            outgoing = payloadToStream
        }
        let sentCount = outgoing.count
        if sentCount > 0 {
            inFlightBytes += sentCount
            if inFlightBytes >= highWaterBytes && !isUpstreamSuspended {
                isUpstreamSuspended = true
                taskToSuspend = dataTask
            }
        }
        lock.unlock()
        taskToSuspend?.suspend()

        if let fallbackHeader {
            let elapsedMs = Int(((CFAbsoluteTimeGetCurrent() - startTimestamp) * 1000).rounded())
            onLog(false, "[proxy] 流式混流探测为二进制流 \(upstreamHost) -> 切换直传 (\(elapsedMs)ms)")
            connection.send(content: fallbackHeader, completion: .contentProcessed { _ in })
        }
        guard sentCount > 0 else { return }
        connection.send(content: outgoing, completion: .contentProcessed { [weak self] sendError in
            guard let self else { return }
            if sendError != nil {
                self.cancelAll()
                return
            }
            var taskToResume: URLSessionDataTask?
            self.lock.lock()
            self.inFlightBytes = max(0, self.inFlightBytes - sentCount)
            if self.inFlightBytes <= self.lowWaterBytes && self.isUpstreamSuspended && !self.didFinish {
                self.isUpstreamSuspended = false
                taskToResume = self.dataTask
            }
            self.lock.unlock()
            taskToResume?.resume()
        })
    }

    func handleCompletion(error: Error?) {
        lock.lock()
        let alreadyFinished = didFinish
        let sentHeaders = didSendHeaders
        let wasBufferingManifest = isBufferingManifest
        let rawManifestData = manifestData
        let baseURL = manifestBaseURL
        let statusCode = manifestStatusCode
        let savedHeaderPacket = manifestHeaderPacket
        isBufferingManifest = false
        manifestData.removeAll(keepingCapacity: false)
        manifestHeaderPacket = nil
        didFinish = true
        self.dataTask = nil
        let trailing = (!wasBufferingManifest && shouldPatchMP4Stream) ? mp4Patcher.flush() : Data()
        lock.unlock()
        guard !alreadyFinished else { return }

        if wasBufferingManifest {
            let elapsedMs = Int(((CFAbsoluteTimeGetCurrent() - startTimestamp) * 1000).rounded())
            if let error {
                let nsErr = error as NSError
                if !(nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled) {
                    onLog(true, "[proxy][error] HLS \(upstreamHost) 失败: \(nsErr.domain)(\(nsErr.code)) \(error.localizedDescription) (\(elapsedMs)ms)")
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
            if let rewriter = hlsManifestRewriter,
               let rawText = String(data: rawManifestData, encoding: .utf8),
               let resolvedBase = baseURL,
               Self.isLikelyTextManifestPrefix(rawManifestData) == true {
                onLog(false, "[proxy] HLS \(upstreamHost) -> HTTP \(statusCode) (\(elapsedMs)ms)")
                let rewritten = rewriter(rawText, resolvedBase)
                let outData = Data(rewritten.utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl; charset=utf-8\r\nContent-Length: \(outData.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                var packet = Data(head.utf8)
                packet.append(outData)
                connection.send(content: packet, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                    self?.connection.cancel()
                })
                return
            }
            var rawPacket = savedHeaderPacket ?? Data("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".utf8)
            rawPacket.append(rawManifestData)
            connection.send(content: rawPacket, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
            return
        }

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

private final class UpstreamChunkFetchTask: ProxySessionTaskHandler, @unchecked Sendable {
    private let headers: [String: String]
    private let rangeHeader: String
    private let expectRangeStart: Int64
    private let onCookieResponse: @Sendable (HTTPURLResponse) -> Void
    private let onComplete: @Sendable (Result<Data, Error>) -> Void
    private let lock = NSLock()
    private var dataTask: URLSessionDataTask?
    private var buffer = Data()
    private var statusCode: Int = 0
    private var didComplete = false

    init(
        headers: [String: String],
        rangeHeader: String,
        expectRangeStart: Int64,
        expectedSize: Int,
        onCookieResponse: @escaping @Sendable (HTTPURLResponse) -> Void,
        onComplete: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        self.headers = headers
        self.rangeHeader = rangeHeader
        self.expectRangeStart = expectRangeStart
        self.onCookieResponse = onCookieResponse
        self.onComplete = onComplete
        if expectedSize > 0 {
            self.buffer.reserveCapacity(expectedSize)
        }
    }

    func start(with request: URLRequest) {
        let task = ProxyUpstreamSessionPool.shared.startTask(with: request, handler: self)
        lock.lock()
        if didComplete {
            lock.unlock()
            ProxyUpstreamSessionPool.shared.removeTask(withIdentifier: task.taskIdentifier)
            task.cancel()
            return
        }
        self.dataTask = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        let task = dataTask
        dataTask = nil
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        if let task {
            ProxyUpstreamSessionPool.shared.removeTask(withIdentifier: task.taskIdentifier)
            task.cancel()
        }
        onComplete(.failure(URLError(.cancelled)))
    }

    func handleRedirect(
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var next = request
        for (k, v) in headers {
            next.setValue(v, forHTTPHeaderField: k)
        }
        next.setValue(rangeHeader, forHTTPHeaderField: "Range")
        completionHandler(next)
    }

    func handleResponse(
        _ response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(with: .failure(URLError(.badServerResponse)))
            return
        }
        onCookieResponse(http)
        lock.lock()
        statusCode = http.statusCode
        lock.unlock()
        guard (200...299).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(with: .failure(NSError(domain: "GlassMPV.LocalProxy", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "分块拉取 HTTP \(http.statusCode)"
            ])))
            return
        }
        if http.statusCode == 200 && (expectRangeStart > 0 || http.expectedContentLength <= 0 || http.expectedContentLength > Int64(ProxyRouteChunkCache.chunkSize) * 2) {
            completionHandler(.cancel)
            finish(with: .failure(NSError(domain: "GlassMPV.LocalProxy", code: -416, userInfo: [
                NSLocalizedDescriptionKey: "上游忽略 Range 返回完整 200"
            ])))
            return
        }
        completionHandler(.allow)
    }

    func handleData(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        buffer.append(data)
        lock.unlock()
    }

    func handleCompletion(error: Error?) {
        if let error {
            finish(with: .failure(error))
            return
        }
        lock.lock()
        let out = buffer
        let code = statusCode
        lock.unlock()
        guard (200...299).contains(code) else {
            finish(with: .failure(URLError(.badServerResponse)))
            return
        }
        finish(with: .success(out))
    }

    private func finish(with result: Result<Data, Error>) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        dataTask = nil
        if case .failure = result {
            buffer.removeAll(keepingCapacity: false)
        }
        lock.unlock()
        onComplete(result)
    }
}

private final class ProxyRouteChunkCache: @unchecked Sendable {
    static let chunkSize: Int = 2 * 1024 * 1024
    static let maxCachedChunks: Int = 16
    static let prefetchAheadCount: Int = 3

    private let upstreamURL: URL
    private let onCookieResponse: @Sendable (HTTPURLResponse) -> Void
    private let onLog: @Sendable (Bool, String) -> Void
    private let lock = NSLock()
    private var headers: [String: String]
    private var knownTotalLengthStorage: Int64?
    private var knownContentTypeStorage: String?
    private var chunks: [Int: Data] = [:]
    private var lruOrder: [Int] = []
    private var inFlightWaiters: [Int: [@Sendable (Result<Data, Error>) -> Void]] = [:]
    private var activeTasks: [Int: UpstreamChunkFetchTask] = [:]
    private var isInvalidated = false

    init(
        upstreamURL: URL,
        headers: [String: String],
        onCookieResponse: @escaping @Sendable (HTTPURLResponse) -> Void,
        onLog: @escaping @Sendable (Bool, String) -> Void
    ) {
        self.upstreamURL = upstreamURL
        self.headers = headers
        self.onCookieResponse = onCookieResponse
        self.onLog = onLog
    }

    var knownTotalLength: Int64? {
        lock.lock()
        let total = knownTotalLengthStorage
        lock.unlock()
        return total
    }

    var knownContentType: String? {
        lock.lock()
        let ct = knownContentTypeStorage
        lock.unlock()
        return ct
    }

    func setKnownTotalLength(_ total: Int64) {
        guard total > 0 else { return }
        lock.lock()
        knownTotalLengthStorage = total
        lock.unlock()
    }

    func setKnownContentType(_ contentType: String) {
        guard !contentType.isEmpty else { return }
        lock.lock()
        knownContentTypeStorage = contentType
        lock.unlock()
    }

    func updateHeaders(_ newHeaders: [String: String]) {
        lock.lock()
        headers = newHeaders
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        isInvalidated = true
        let tasksToCancel = Array(activeTasks.values)
        activeTasks.removeAll()
        let pendingGroups = Array(inFlightWaiters.values)
        inFlightWaiters.removeAll()
        chunks.removeAll()
        lruOrder.removeAll()
        lock.unlock()

        for task in tasksToCancel {
            task.cancel()
        }
        let err = URLError(.cancelled)
        for group in pendingGroups {
            for waiter in group {
                waiter(.failure(err))
            }
        }
    }

    func prefetchAhead(startingAfter chunkIndex: Int) {
        lock.lock()
        guard !isInvalidated, let totalLen = knownTotalLengthStorage else {
            lock.unlock()
            return
        }
        var toFetch: [Int] = []
        for offset in 1...Self.prefetchAheadCount {
            let idx = chunkIndex + offset
            guard idx >= 0, Int64(idx) * Int64(Self.chunkSize) < totalLen else { break }
            if chunks[idx] == nil && inFlightWaiters[idx] == nil {
                toFetch.append(idx)
            }
        }
        lock.unlock()

        for idx in toFetch {
            fetchChunk(index: idx) { _ in }
        }
    }

    func fetchChunk(
        index chunkIndex: Int,
        completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        lock.lock()
        if isInvalidated {
            lock.unlock()
            completion(.failure(URLError(.cancelled)))
            return
        }
        if let cached = chunks[chunkIndex] {
            if chunkIndex != 0 {
                lruOrder.removeAll { $0 == chunkIndex }
                lruOrder.append(chunkIndex)
            }
            lock.unlock()
            completion(.success(cached))
            return
        }
        if var waiters = inFlightWaiters[chunkIndex] {
            waiters.append(completion)
            inFlightWaiters[chunkIndex] = waiters
            lock.unlock()
            return
        }
        guard let totalLen = knownTotalLengthStorage else {
            lock.unlock()
            completion(.failure(URLError(.resourceUnavailable)))
            return
        }
        let chunkStart = Int64(chunkIndex) * Int64(Self.chunkSize)
        guard chunkIndex >= 0, chunkStart < totalLen else {
            lock.unlock()
            completion(.failure(URLError(.dataLengthExceedsMaximum)))
            return
        }
        inFlightWaiters[chunkIndex] = [completion]
        lock.unlock()

        launchFetchTask(chunkIndex: chunkIndex, totalLength: totalLen, attempt: 0)
    }

    private func launchFetchTask(chunkIndex: Int, totalLength: Int64, attempt: Int) {
        let chunkStart = Int64(chunkIndex) * Int64(Self.chunkSize)
        let chunkEnd = min(totalLength - 1, chunkStart + Int64(Self.chunkSize) - 1)
        let expectedBytes = Int(chunkEnd - chunkStart + 1)
        let rangeHeader = "bytes=\(chunkStart)-\(chunkEnd)"

        lock.lock()
        guard !isInvalidated else {
            let waiters = inFlightWaiters.removeValue(forKey: chunkIndex) ?? []
            activeTasks.removeValue(forKey: chunkIndex)
            lock.unlock()
            for waiter in waiters {
                waiter(.failure(URLError(.cancelled)))
            }
            return
        }
        let currentHeaders = headers
        lock.unlock()

        var req = URLRequest(url: upstreamURL, timeoutInterval: 15)
        req.httpMethod = "GET"
        for (k, v) in currentHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.setValue(rangeHeader, forHTTPHeaderField: "Range")

        let fetchTask = UpstreamChunkFetchTask(
            headers: currentHeaders,
            rangeHeader: rangeHeader,
            expectRangeStart: chunkStart,
            expectedSize: expectedBytes,
            onCookieResponse: onCookieResponse
        ) { [weak self] result in
            self?.handleFetchFinished(chunkIndex: chunkIndex, totalLength: totalLength, attempt: attempt, result: result)
        }
        lock.lock()
        guard !isInvalidated else {
            let waiters = inFlightWaiters.removeValue(forKey: chunkIndex) ?? []
            activeTasks.removeValue(forKey: chunkIndex)
            lock.unlock()
            for waiter in waiters {
                waiter(.failure(URLError(.cancelled)))
            }
            return
        }
        activeTasks[chunkIndex] = fetchTask
        lock.unlock()
        fetchTask.start(with: req)
    }

    private func handleFetchFinished(
        chunkIndex: Int,
        totalLength: Int64,
        attempt: Int,
        result: Result<Data, Error>
    ) {
        switch result {
        case .success(let data):
            lock.lock()
            let invalidated = isInvalidated
            let waiters = inFlightWaiters.removeValue(forKey: chunkIndex) ?? []
            activeTasks.removeValue(forKey: chunkIndex)
            if !invalidated {
                chunks[chunkIndex] = data
                if chunkIndex != 0 {
                    lruOrder.removeAll { $0 == chunkIndex }
                    lruOrder.append(chunkIndex)
                }
                while chunks.count > Self.maxCachedChunks, let victim = lruOrder.first {
                    lruOrder.removeFirst()
                    chunks.removeValue(forKey: victim)
                }
            }
            lock.unlock()
            let finalResult: Result<Data, Error> = invalidated ? .failure(URLError(.cancelled)) : .success(data)
            for waiter in waiters {
                waiter(finalResult)
            }

        case .failure(let error):
            let nsErr = error as NSError
            let isCancelled = (nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled)
            lock.lock()
            let canRetry = !isInvalidated && !isCancelled && attempt == 0 && inFlightWaiters[chunkIndex] != nil
            if !canRetry {
                let waiters = inFlightWaiters.removeValue(forKey: chunkIndex) ?? []
                activeTasks.removeValue(forKey: chunkIndex)
                lock.unlock()
                if !isCancelled {
                    onLog(true, "[proxy][error] 并发分块 #\(chunkIndex) 失败: \(error.localizedDescription)")
                }
                for waiter in waiters {
                    waiter(.failure(error))
                }
                return
            }
            lock.unlock()
            launchFetchTask(chunkIndex: chunkIndex, totalLength: totalLength, attempt: 1)
        }
    }
}

private final class ParallelChunkedStreamRelay: @unchecked Sendable {
    private let connection: NWConnection
    private let chunkCache: ProxyRouteChunkCache
    private let rangeStart: Int64
    private let rangeEnd: Int64
    private let totalLength: Int64
    private let hadRangeHeader: Bool
    private let upstreamHost: String
    private let enableMP4HEV1Patch: Bool
    private let onLog: @Sendable (Bool, String) -> Void
    private let lock = NSLock()
    private var isCancelled = false
    private var selfRetain: ParallelChunkedStreamRelay?
    private var mp4Patcher: MP4HEV1StreamPatcher

    init(
        connection: NWConnection,
        chunkCache: ProxyRouteChunkCache,
        rangeStart: Int64,
        rangeEnd: Int64,
        totalLength: Int64,
        hadRangeHeader: Bool,
        upstreamHost: String,
        enableMP4HEV1Patch: Bool,
        onLog: @escaping @Sendable (Bool, String) -> Void
    ) {
        self.connection = connection
        self.chunkCache = chunkCache
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.totalLength = totalLength
        self.hadRangeHeader = hadRangeHeader
        self.upstreamHost = upstreamHost
        self.enableMP4HEV1Patch = enableMP4HEV1Patch
        self.onLog = onLog
        self.mp4Patcher = MP4HEV1StreamPatcher(startsAtFileOffsetZero: rangeStart == 0)
    }

    func start() {
        lock.lock()
        selfRetain = self
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.markCancelledAndRelease()
            } else if case .failed = state {
                self?.markCancelledAndRelease()
            }
        }

        let contentLength = rangeEnd - rangeStart + 1
        let statusLine = hadRangeHeader ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK"
        let contentType = chunkCache.knownContentType ?? "video/mp4"
        var headerLines = [
            statusLine,
            "Content-Type: \(contentType)",
            "Content-Length: \(contentLength)"
        ]
        if hadRangeHeader {
            headerLines.append("Content-Range: bytes \(rangeStart)-\(rangeEnd)/\(totalLength)")
        }
        headerLines.append("Accept-Ranges: bytes")
        headerLines.append("Connection: close")
        let headPacket = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)

        let statusCode = hadRangeHeader ? 206 : 200
        onLog(false, "[proxy] GET \(upstreamHost) -> 并发分块直传 HTTP \(statusCode) (range=\(rangeStart)-\(rangeEnd)/\(totalLength))")

        connection.send(content: headPacket, completion: .contentProcessed { [weak self] sendError in
            guard let self else { return }
            if sendError != nil {
                self.markCancelledAndRelease()
                self.connection.cancel()
                return
            }
            self.sendNextChunk(at: self.rangeStart)
        })
    }

    private func markCancelledAndRelease() {
        lock.lock()
        isCancelled = true
        selfRetain = nil
        lock.unlock()
    }

    private func readCancelled() -> Bool {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        return cancelled
    }

    private func sendNextChunk(at cursor: Int64) {
        guard !readCancelled() else { return }

        if cursor > rangeEnd {
            let trailing: Data
            lock.lock()
            trailing = enableMP4HEV1Patch ? mp4Patcher.flush() : Data()
            lock.unlock()
            if !trailing.isEmpty {
                connection.send(content: trailing, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError != nil {
                        self.markCancelledAndRelease()
                        self.connection.cancel()
                        return
                    }
                    self.finishConnection()
                })
            } else {
                finishConnection()
            }
            return
        }

        let chunkSize64 = Int64(ProxyRouteChunkCache.chunkSize)
        let chunkIdx = Int(cursor / chunkSize64)
        let chunkStart = Int64(chunkIdx) * chunkSize64
        chunkCache.prefetchAhead(startingAfter: chunkIdx)

        chunkCache.fetchChunk(index: chunkIdx) { [weak self] result in
            guard let self, !self.readCancelled() else { return }
            switch result {
            case .failure(let error):
                let nsErr = error as NSError
                if !(nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled) {
                    self.onLog(true, "[proxy][error] 并发分块直传终止 (#\(chunkIdx)): \(error.localizedDescription)")
                }
                self.markCancelledAndRelease()
                self.connection.cancel()

            case .success(let chunkData):
                let sliceStart = Int(cursor - chunkStart)
                let availableEndOffset = chunkStart + Int64(chunkData.count) - 1
                let targetEnd = min(self.rangeEnd, availableEndOffset)
                let sliceEnd = Int(targetEnd - chunkStart) + 1
                guard sliceStart >= 0, sliceEnd > sliceStart, sliceEnd <= chunkData.count else {
                    self.markCancelledAndRelease()
                    self.connection.cancel()
                    return
                }
                let rawSlice: Data = (sliceStart == 0 && sliceEnd == chunkData.count)
                    ? chunkData
                    : chunkData.subdata(in: sliceStart..<sliceEnd)
                let outgoing: Data
                self.lock.lock()
                if self.enableMP4HEV1Patch {
                    outgoing = self.mp4Patcher.processChunk(rawSlice)
                } else {
                    outgoing = rawSlice
                }
                self.lock.unlock()

                let nextCursor = targetEnd + 1
                if outgoing.isEmpty {
                    self.sendNextChunk(at: nextCursor)
                } else {
                    self.connection.send(content: outgoing, completion: .contentProcessed { [weak self] sendError in
                        guard let self else { return }
                        if sendError != nil {
                            self.markCancelledAndRelease()
                            self.connection.cancel()
                            return
                        }
                        self.sendNextChunk(at: nextCursor)
                    })
                }
            }
        }
    }

    private func finishConnection() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.markCancelledAndRelease()
            self.connection.cancel()
        })
    }
}
