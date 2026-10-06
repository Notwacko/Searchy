import Foundation
import Network
import Security
import os

// MARK: - Connection helpers

extension NWConnection {
    /// Next chunk of bytes; nil on a clean end of stream.
    nonisolated func receiveChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { cont in
            receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if isComplete { cont.resume(returning: nil) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    nonisolated func sendAll(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }
}

/// Copies bytes both ways between two connections until either side closes.
nonisolated enum ConnectionPipe {
    static func link(_ a: NWConnection, _ b: NWConnection) {
        let state = PipeState()
        pump(from: a, to: b, state: state)
        pump(from: b, to: a, state: state)
    }

    private final class PipeState: @unchecked Sendable { var finished = 0 }

    private static func pump(from: NWConnection, to: NWConnection, state: PipeState) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil { from.cancel(); to.cancel() }
                    else if isComplete || error != nil { close(from, to, state) }
                    else { pump(from: from, to: to, state: state) }
                })
            } else if isComplete || error != nil {
                close(from, to, state)
            } else {
                pump(from: from, to: to, state: state)
            }
        }
    }

    private static func close(_ from: NWConnection, _ to: NWConnection, _ state: PipeState) {
        to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        state.finished += 1
        if state.finished >= 2 { from.cancel(); to.cancel() }
    }
}

// MARK: - The proxy

nonisolated final class TrafficProxy: @unchecked Sendable {
    static let shared = TrafficProxy()

    let queue = DispatchQueue(label: "app.searchy.proxy")

    private struct State {
        var listener: NWListener?
        var port: UInt16 = 0
        var mitmPorts: [String: UInt16] = [:]
        var inflight: [String: Task<UInt16, Error>] = [:]
        var mitmListeners: [NWListener] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func start() async throws -> UInt16 {
        if let existing = state.withLock({ $0.port != 0 ? $0.port : nil }) { return existing }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [self] conn in ProxyEntry(conn: conn, proxy: self).begin() }
        let port = try await ready(l)
        state.withLock { $0.listener = l; $0.port = port }
        return port
    }

    func stop() {
        state.withLock { s in
            s.listener?.cancel(); s.listener = nil; s.port = 0
            s.mitmListeners.forEach { $0.cancel() }
            s.mitmListeners = []; s.mitmPorts = [:]
        }
    }

    /// Port of a loopback TLS listener that presents a forged certificate for `host`.
    func mitmPort(host: String, port: Int) async throws -> UInt16 {
        let key = "\(host):\(port)"
        enum Plan { case ready(UInt16), wait(Task<UInt16, Error>) }
        let plan: Plan = state.withLock { s in
            if let p = s.mitmPorts[key] { return .ready(p) }
            if let t = s.inflight[key] { return .wait(t) }
            let task = Task { [self] () throws -> UInt16 in
                let identity = try await CertificateAuthority.shared.identity(for: host)
                let tls = NWProtocolTLS.Options()
                guard let secIdentity = sec_identity_create(identity) else { throw CertificateAuthority.CAError.importFailed }
                sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
                sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
                let params = NWParameters(tls: tls)
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                let l = try NWListener(using: params)
                l.newConnectionHandler = { [self] conn in
                    conn.start(queue: queue)
                    Task { await HTTPSession(conn: conn, scheme: "https", host: host, port: port, initial: Data()).run() }
                }
                let p = try await ready(l)
                state.withLock { $0.mitmListeners.append(l); $0.mitmPorts[key] = p }
                return p
            }
            s.inflight[key] = task
            return .wait(task)
        }
        switch plan {
        case .ready(let p): return p
        case .wait(let task):
            defer { state.withLock { $0.inflight[key] = nil } }
            return try await task.value
        }
    }

    private func ready(_ l: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            let once = OnceFlag()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { cont.resume(returning: l.port?.rawValue ?? 0) }
                case .failed(let e): if once.take() { cont.resume(throwing: e) }
                case .cancelled: if once.take() { cont.resume(throwing: CancellationError()) }
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }
}

// MARK: - First contact from the browser

nonisolated final class ProxyEntry: @unchecked Sendable {
    let conn: NWConnection
    let proxy: TrafficProxy

    init(conn: NWConnection, proxy: TrafficProxy) { self.conn = conn; self.proxy = proxy }

    func begin() {
        conn.start(queue: proxy.queue)
        Task { await run() }
    }

    private func run() async {
        do {
            var buffer = Data()
            while HTTPWire.headEnd(in: buffer) == nil {
                guard let chunk = try await conn.receiveChunk() else { conn.cancel(); return }
                buffer.append(chunk)
                if buffer.count > 1 << 20 { conn.cancel(); return }
            }
            let end = HTTPWire.headEnd(in: buffer)!
            guard let (start, _) = HTTPWire.parseHead(buffer.prefix(end)) else { conn.cancel(); return }
            let parts = start.split(separator: " ").map(String.init)
            guard parts.count >= 2 else { conn.cancel(); return }

            guard parts[0].uppercased() == "CONNECT" else {
                await HTTPSession(conn: conn, scheme: "http", host: nil, port: 80, initial: buffer).run()
                return
            }
            let (host, port) = Self.splitHostPort(parts[1])
            try await conn.sendAll(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
            var first = Data(buffer.dropFirst(end))
            if first.isEmpty {
                guard let chunk = try await conn.receiveChunk() else { conn.cancel(); return }
                first = chunk
            }
            if first.first == 0x16 {
                await secureTunnel(host: host, port: port, first: first)
            } else {
                await HTTPSession(conn: conn, scheme: "http", host: host, port: port, initial: first).run()
            }
        } catch {
            conn.cancel()
        }
    }

    /// TLS: read it through a forged-certificate listener; if that fails, fall back to a blind tunnel.
    private func secureTunnel(host: String, port: Int, first: Data) async {
        do {
            let local = try await proxy.mitmPort(host: host, port: port)
            let inner = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: local)!, using: .tcp)
            inner.start(queue: proxy.queue)
            try await inner.sendAll(first)
            ConnectionPipe.link(conn, inner)
        } catch {
            await blindTunnel(host: host, port: port, first: first)
        }
    }

    private func blindTunnel(host: String, port: Int, first: Data) async {
        guard let p = NWEndpoint.Port(rawValue: UInt16(port)) else { conn.cancel(); return }
        let upstream = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        upstream.start(queue: proxy.queue)
        do { try await upstream.sendAll(first) } catch { conn.cancel(); upstream.cancel(); return }
        ConnectionPipe.link(conn, upstream)
    }

    static func splitHostPort(_ s: String) -> (String, Int) {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let port = s[close...].split(separator: ":").last.flatMap { Int($0) } ?? 443
            return (host, port)
        }
        let bits = s.split(separator: ":", maxSplits: 1).map(String.init)
        return (bits[0], bits.count > 1 ? Int(bits[1]) ?? 443 : 443)
    }
}

// MARK: - HTTP/1.1 session

nonisolated final class HTTPSession: @unchecked Sendable {
    let conn: NWConnection
    let scheme: String
    var fixedHost: String?
    var fixedPort: Int
    var buffer: Data

    init(conn: NWConnection, scheme: String, host: String?, port: Int, initial: Data) {
        self.conn = conn; self.scheme = scheme; self.fixedHost = host; self.fixedPort = port; self.buffer = initial
    }

    func run() async {
        defer { conn.cancel() }
        do {
            while let request = try await readRequest() {
                guard try await handle(request) else { return }
            }
        } catch {
            return
        }
    }

    // MARK: Reading the browser's request

    private struct Incoming { var message: HTTPRequestMessage; var host: String; var port: Int }

    private func readRequest() async throws -> Incoming? {
        while HTTPWire.headEnd(in: buffer) == nil {
            guard let chunk = try await conn.receiveChunk() else { return nil }
            buffer.append(chunk)
            if buffer.count > 4 << 20 { return nil }
        }
        let end = HTTPWire.headEnd(in: buffer)!
        guard let (start, headers) = HTTPWire.parseHead(buffer.prefix(end)) else { return nil }
        let parts = start.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        var msg = HTTPRequestMessage(method: parts[0], target: parts[1], version: parts.count > 2 ? parts[2] : "HTTP/1.1", headers: headers)
        var consumed = end

        // Body
        if msg.header("Expect")?.lowercased().contains("100-continue") == true {
            try await conn.sendAll(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        if msg.header("Transfer-Encoding")?.lowercased().contains("chunked") == true {
            while true {
                if let (body, used) = HTTPWire.decodeChunked(buffer.dropFirst(end)) { msg.body = body; consumed = end + used; break }
                guard let chunk = try await conn.receiveChunk() else { return nil }
                buffer.append(chunk)
            }
            msg.removeHeader("Transfer-Encoding")
            msg.setHeader("Content-Length", String(msg.body.count))
        } else if let length = msg.header("Content-Length").flatMap({ Int($0) }), length > 0 {
            while buffer.count < end + length {
                guard let chunk = try await conn.receiveChunk() else { return nil }
                buffer.append(chunk)
            }
            msg.body = Data(buffer[end..<(end + length)])
            consumed = end + length
        }
        buffer = Data(buffer.dropFirst(consumed))

        // Work out where it's going and normalise the target to origin-form.
        var host = fixedHost
        var port = fixedPort
        if let url = URL(string: msg.target), let h = url.host, url.scheme != nil {
            host = h
            port = url.port ?? (url.scheme == "https" ? 443 : 80)
            var path = url.path.isEmpty ? "/" : url.path
            if let q = url.query { path += "?" + q }
            msg.target = path
        } else if host == nil, let hostHeader = msg.header("Host") {
            let (h, p) = ProxyEntry.splitHostPort(hostHeader)
            host = h
            port = hostHeader.contains(":") ? p : 80
        }
        guard let host else { return nil }
        if msg.header("Host") == nil { msg.setHeader("Host", port == (scheme == "https" ? 443 : 80) ? host : "\(host):\(port)") }
        msg.removeHeader("Proxy-Connection")
        return Incoming(message: msg, host: host, port: port)
    }

    // MARK: One exchange

    /// Returns whether the connection can be reused for another request.
    private func handle(_ incoming: Incoming) async throws -> Bool {
        let lab = await MainActor.run { TrafficLab.shared }
        let config = lab.config.withLock { $0 }
        var request = incoming.message
        let host = incoming.host, port = incoming.port
        let wantsClose = request.header("Connection")?.lowercased() == "close" || request.version == "HTTP/1.0"

        if request.header("Upgrade")?.lowercased() == "websocket" {
            await tunnelWebSocket(request, host: host, port: port)
            return false
        }

        Rewriter.apply(config.rules, to: &request)
        let flow = await lab.begin(scheme: scheme, host: host, port: port, request: request)
        let started = Date()

        // Intercept the request.
        if config.interceptRequests, !config.inScopeOnly || config.inScope(host) {
            switch await lab.hold(flow, stage: .request, raw: request.rawText) {
            case .drop:
                await MainActor.run { flow.state = .dropped }
                try await send(.init(status: 403, reason: "Forbidden", headers: [HTTPHeader(name: "Content-Type", value: "text/plain")],
                                     body: Data("Request dropped by Searchy Traffic Lab.".utf8)), method: request.method, keepAlive: !wantsClose)
                return !wantsClose
            case .forward(let raw):
                if let edited = HTTPRequestMessage.parse(rawText: raw, originalBody: request.body), edited.rawText != request.rawText {
                    request = edited
                    await MainActor.run { flow.request = edited; flow.wasEdited = true }
                }
            }
        }
        await MainActor.run { flow.state = .pending }

        guard let url = URL(string: "\(scheme)://\(Self.authority(host, port, scheme))\(request.target.hasPrefix("/") ? request.target : "/" + request.target)") else {
            try await send(.init(status: 400, reason: "Bad Request", headers: [], body: Data("Bad request target".utf8)), method: request.method, keepAlive: false)
            return false
        }

        let upstream = Upstream(followRedirects: false, allowInvalid: config.allowInvalidUpstream)
        var response: HTTPResponseMessage?
        var streaming = false
        var streamedBytes = 0
        do {
            for try await event in upstream.stream(Upstream.makeRequest(request, url: url)) {
                switch event {
                case .head(let status, let headers):
                    var r = HTTPResponseMessage(status: status, reason: HTTPWire.reasonPhrase(status), headers: headers)
                    r.version = "HTTP/1.1"
                    response = r
                    if Self.shouldStream(r) {
                        streaming = true
                        try await sendHead(r, chunked: true, keepAlive: !wantsClose)
                    }
                case .data(let chunk):
                    if streaming {
                        streamedBytes += chunk.count
                        try await conn.sendAll(Data("\(String(chunk.count, radix: 16))\r\n".utf8) + chunk + Data("\r\n".utf8))
                    } else {
                        response?.body.append(chunk)
                        if (response?.body.count ?? 0) > 48 << 20, let r = response {
                            // Too big to hold: switch to pass-through.
                            streaming = true
                            try await sendHead(r, chunked: true, keepAlive: !wantsClose)
                            try await conn.sendAll(Data("\(String(r.body.count, radix: 16))\r\n".utf8) + r.body + Data("\r\n".utf8))
                            streamedBytes = r.body.count
                            response?.body = Data()
                        }
                    }
                }
            }
        } catch {
            let message = (error as NSError).localizedDescription
            await MainActor.run { flow.state = .failed(message) }
            if !streaming {
                try await send(.init(status: 502, reason: "Bad Gateway", headers: [HTTPHeader(name: "Content-Type", value: "text/plain; charset=utf-8")],
                                     body: Data("Searchy Traffic Lab couldn’t reach \(host):\n\(message)".utf8)), method: request.method, keepAlive: false)
            }
            return false
        }

        guard var final = response else { return false }
        if streaming {
            try await conn.sendAll(Data("0\r\n\r\n".utf8))
            let head = final
            await MainActor.run {
                flow.response = head; flow.truncated = true; flow.state = .done; flow.duration = Date().timeIntervalSince(started)
            }
            return !wantsClose
        }

        Rewriter.apply(config.rules, to: &final)
        if config.interceptResponses, !config.inScopeOnly || config.inScope(host) {
            let snapshot = final
            await MainActor.run { flow.response = snapshot }
            switch await lab.hold(flow, stage: .response, raw: final.rawText) {
            case .drop:
                await MainActor.run { flow.state = .dropped }
                return false
            case .forward(let raw):
                if let edited = HTTPResponseMessage.parse(rawText: raw, originalBody: final.body), edited.rawText != final.rawText {
                    final = edited
                    await MainActor.run { flow.wasEdited = true }
                }
            }
        }
        let done = final
        await MainActor.run {
            flow.response = done; flow.state = .done; flow.duration = Date().timeIntervalSince(started)
        }
        try await send(final, method: request.method, keepAlive: !wantsClose)
        return !wantsClose
    }

    // MARK: Writing to the browser

    private static let dropFromResponse: Set<String> = ["content-length", "transfer-encoding", "content-encoding", "connection", "keep-alive", "proxy-connection"]

    private func sendHead(_ r: HTTPResponseMessage, chunked: Bool, keepAlive: Bool) async throws {
        var head = "HTTP/1.1 \(r.status) \(r.reason)\r\n"
        for h in r.headers where !Self.dropFromResponse.contains(h.name.lowercased()) { head += "\(h.name): \(h.value)\r\n" }
        if chunked { head += "Transfer-Encoding: chunked\r\n" }
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        try await conn.sendAll(Data(head.utf8))
    }

    private func send(_ r: HTTPResponseMessage, method: String, keepAlive: Bool) async throws {
        var head = "HTTP/1.1 \(r.status) \(r.reason)\r\n"
        for h in r.headers where !Self.dropFromResponse.contains(h.name.lowercased()) { head += "\(h.name): \(h.value)\r\n" }
        let bodiless = method == "HEAD" || r.status == 204 || r.status == 304 || (100..<200).contains(r.status)
        if !bodiless { head += "Content-Length: \(r.body.count)\r\n" }
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var data = Data(head.utf8)
        if !bodiless { data.append(r.body) }
        try await conn.sendAll(data)
    }

    private static func shouldStream(_ r: HTTPResponseMessage) -> Bool {
        let type = r.contentType.lowercased()
        if type.hasPrefix("text/event-stream") || type.hasPrefix("video/") || type.hasPrefix("audio/") { return true }
        if let length = r.header("Content-Length").flatMap({ Int($0) }), length > 16 << 20 { return true }
        return false
    }

    private static func authority(_ host: String, _ port: Int, _ scheme: String) -> String {
        let h = host.contains(":") ? "[\(host)]" : host
        return port == (scheme == "https" ? 443 : 80) ? h : "\(h):\(port)"
    }

    // MARK: WebSockets

    private func tunnelWebSocket(_ request: HTTPRequestMessage, host: String, port: Int) async {
        let lab = await MainActor.run { TrafficLab.shared }
        let flow = await lab.begin(scheme: scheme == "https" ? "wss" : "ws", host: host, port: port, request: request)
        await MainActor.run { flow.state = .websocket }
        guard let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        let params: NWParameters = scheme == "https" ? .tls : .tcp
        let upstream = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        upstream.start(queue: TrafficProxy.shared.queue)
        do {
            try await upstream.sendAll(request.wireData())
            ConnectionPipe.link(conn, upstream)
            // The pipe now owns both connections; park until the browser side goes away.
            while conn.state != .cancelled { try await Task.sleep(for: .seconds(1)) }
        } catch {
            upstream.cancel()
        }
    }
}

// MARK: - Rewrite rules

nonisolated enum Rewriter {
    static func apply(_ rules: [RewriteRule], to request: inout HTTPRequestMessage) {
        for rule in rules where rule.enabled && !rule.pattern.isEmpty {
            switch rule.target {
            case .requestHeader:
                let block = request.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\r\n")
                request.headers = parseHeaders(replace(in: block, rule))
            case .requestBody:
                if let t = String(data: request.body, encoding: .utf8) {
                    request.body = Data(replace(in: t, rule).utf8)
                    if request.header("Content-Length") != nil { request.setHeader("Content-Length", String(request.body.count)) }
                }
            default: break
            }
        }
    }

    static func apply(_ rules: [RewriteRule], to response: inout HTTPResponseMessage) {
        for rule in rules where rule.enabled && !rule.pattern.isEmpty {
            switch rule.target {
            case .responseHeader:
                let block = response.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\r\n")
                response.headers = parseHeaders(replace(in: block, rule))
            case .responseBody:
                if let t = String(data: response.body, encoding: .utf8) { response.body = Data(replace(in: t, rule).utf8) }
            default: break
            }
        }
    }

    private static func replace(in text: String, _ rule: RewriteRule) -> String {
        if rule.isRegex {
            guard let re = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { return text }
            return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.replacement)
        }
        return text.replacingOccurrences(of: rule.pattern, with: rule.replacement)
    }

    private static func parseHeaders(_ block: String) -> [HTTPHeader] {
        block.components(separatedBy: "\r\n").compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return HTTPHeader(name: String(line[..<colon]), value: String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
    }
}

// MARK: - Upstream fetching

nonisolated final class Upstream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event: Sendable { case head(status: Int, headers: [HTTPHeader]), data(Data) }

    private let followRedirects: Bool
    private let allowInvalid: Bool
    private var continuation: AsyncThrowingStream<Event, Error>.Continuation?
    private var session: URLSession?

    init(followRedirects: Bool, allowInvalid: Bool) { self.followRedirects = followRedirects; self.allowInvalid = allowInvalid }

    static func makeRequest(_ message: HTTPRequestMessage, url: URL) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        req.httpMethod = message.method
        req.httpShouldHandleCookies = false
        let skip: Set<String> = ["connection", "proxy-connection", "keep-alive", "te", "trailer", "transfer-encoding", "upgrade",
                                 "content-length", "accept-encoding", "proxy-authorization"]
        for h in message.headers where !skip.contains(h.name.lowercased()) { req.addValue(h.value, forHTTPHeaderField: h.name) }
        if !message.body.isEmpty, message.method != "GET", message.method != "HEAD" { req.httpBody = message.body }
        return req
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpCookieAcceptPolicy = .never
            config.httpShouldSetCookies = false
            config.urlCache = nil
            config.timeoutIntervalForRequest = 60
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in task.cancel(); session.invalidateAndCancel() }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            var headers: [HTTPHeader] = []
            for (k, v) in http.allHeaderFields {
                guard let name = k as? String, let value = v as? String else { continue }
                if name.lowercased() == "set-cookie" {
                    for cookie in Self.splitSetCookie(value) { headers.append(HTTPHeader(name: name, value: cookie)) }
                } else {
                    headers.append(HTTPHeader(name: name, value: value))
                }
            }
            continuation?.yield(.head(status: http.statusCode, headers: headers))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { continuation?.yield(.data(data)) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(followRedirects ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust {
            if allowInvalid, let trust = challenge.protectionSpace.serverTrust { completionHandler(.useCredential, URLCredential(trust: trust)) }
            else { completionHandler(.performDefaultHandling, nil) }
        } else {
            // Let the browser handle 401s itself.
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// URLSession folds repeated Set-Cookie headers into one comma-joined value; split them back apart.
    static func splitSetCookie(_ combined: String) -> [String] {
        var parts: [String] = []
        var current = ""
        let chars = Array(combined)
        var i = 0
        while i < chars.count {
            if chars[i] == ",", i + 1 < chars.count, chars[i + 1] == " " {
                // A new cookie starts if what follows looks like `name=`.
                let rest = String(chars[(i + 2)...])
                if let eq = rest.firstIndex(of: "="), !rest[..<eq].contains(where: { $0 == ";" || $0 == " " || $0 == "," }) {
                    parts.append(current); current = ""; i += 2; continue
                }
            }
            current.append(chars[i]); i += 1
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

// MARK: - Replay (Repeater)

nonisolated enum Replay {
    static func send(_ request: HTTPRequestMessage, to url: URL, followRedirects: Bool, allowInvalidCerts: Bool) async throws -> HTTPResponseMessage {
        let upstream = Upstream(followRedirects: followRedirects, allowInvalid: allowInvalidCerts)
        var response: HTTPResponseMessage?
        for try await event in upstream.stream(Upstream.makeRequest(request, url: url)) {
            switch event {
            case .head(let status, let headers):
                response = HTTPResponseMessage(status: status, reason: HTTPWire.reasonPhrase(status), headers: headers)
            case .data(let chunk):
                response?.body.append(chunk)
            }
        }
        guard let response else { throw URLError(.badServerResponse) }
        return response
    }
}
