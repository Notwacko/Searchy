import Foundation
import Observation
import os

/// One request/response pair seen by the proxy.
@MainActor @Observable
final class Flow: Identifiable {
    enum State: Equatable { case pending, held, done, dropped, failed(String), tunnel, websocket }

    let id: Int
    let startedAt = Date()
    let scheme: String
    let host: String
    let port: Int
    var request: HTTPRequestMessage
    var response: HTTPResponseMessage?
    var state: State = .pending
    var duration: TimeInterval?
    var wasEdited = false
    var truncated = false
    var comment = ""
    var tabTitle = ""

    init(id: Int, scheme: String, host: String, port: Int, request: HTTPRequestMessage) {
        self.id = id; self.scheme = scheme; self.host = host; self.port = port; self.request = request
    }

    var method: String { request.method }
    var path: String {
        if request.target.hasPrefix("/") { return request.target }
        return URL(string: request.target).map { ($0.path.isEmpty ? "/" : $0.path) + ($0.query.map { "?" + $0 } ?? "") } ?? request.target
    }
    var urlString: String {
        let defaultPort = (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host)\(port == defaultPort ? "" : ":\(port)")\(path)"
    }
    var status: Int? { response?.status }
    var mime: String { (response?.contentType ?? "").split(separator: ";").first.map { String($0).lowercased() } ?? "" }
    var size: Int { response?.body.count ?? 0 }
    var isStatic: Bool {
        mime.hasPrefix("image/") || mime.hasPrefix("font/") || mime == "text/css" || mime.contains("javascript") || mime.hasPrefix("audio/") || mime.hasPrefix("video/")
    }
}

/// Everything the Traffic Lab shows: history, intercept queue, scope and rewrite rules.
@MainActor @Observable
final class TrafficLab {
    static let shared = TrafficLab()

    // History
    private(set) var flows: [Flow] = []
    private var nextID = 1
    let capacity = 4000

    // Intercept
    var interceptRequests = false { didSet { pushConfig(); if !interceptRequests { releaseHeld(stage: .request) } } }
    var interceptResponses = false { didSet { pushConfig(); if !interceptResponses { releaseHeld(stage: .response) } } }
    private(set) var held: [HeldItem] = []

    // Scope & rules
    var scope: [String] { didSet { UserDefaults.standard.set(scope, forKey: "labScope"); pushConfig() } }
    var inScopeOnlyIntercept = true { didSet { pushConfig() } }
    var rules: [RewriteRule] { didSet { persistRules(); pushConfig() } }
    var allowInvalidUpstream = false { didSet { pushConfig() } }
    var paused = false

    // Repeater
    var repeaterTabs: [RepeaterTab] = []
    var selectedRepeater: UUID?

    // Proxy
    private(set) var port: UInt16 = 0
    private(set) var isRunning = false
    var lastError: String?
    @ObservationIgnored private let log = Logger(subsystem: "app.searchy", category: "lab")

    private init() {
        scope = UserDefaults.standard.stringArray(forKey: "labScope") ?? []
        if let data = UserDefaults.standard.data(forKey: "labRules"), let r = try? JSONDecoder().decode([RewriteRule].self, from: data) { rules = r }
        else { rules = [] }
        pushConfig()
    }

    // MARK: Proxy lifecycle

    /// Starts the local proxy on first use and returns its port.
    @discardableResult
    func ensureRunning() async -> UInt16? {
        if isRunning { return port }
        do {
            try CertificateAuthority.shared.ensureCA()
            let p = try await TrafficProxy.shared.start()
            port = p
            isRunning = true
            lastError = nil
            return p
        } catch {
            lastError = error.localizedDescription
            log.error("Proxy failed to start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Flow recording (called from the proxy)

    func begin(scheme: String, host: String, port: Int, request: HTTPRequestMessage) -> Flow {
        let flow = Flow(id: nextID, scheme: scheme, host: host, port: port, request: request)
        nextID += 1
        flows.append(flow)
        if flows.count > capacity { flows.removeFirst(flows.count - capacity) }
        return flow
    }

    func clearHistory() { flows.removeAll() }

    func inScope(host: String) -> Bool {
        guard !scope.isEmpty else { return true }
        return scope.contains { Self.matches(pattern: $0, host: host) }
    }

    nonisolated static func matches(pattern: String, host: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        let h = host.lowercased()
        if p.isEmpty { return false }
        if p.hasPrefix("*.") { let base = String(p.dropFirst(2)); return h == base || h.hasSuffix("." + base) }
        if p.contains("*") {
            let regex = "^" + NSRegularExpression.escapedPattern(for: p).replacingOccurrences(of: "\\*", with: ".*") + "$"
            return h.range(of: regex, options: .regularExpression) != nil
        }
        return h == p || h.hasSuffix("." + p)
    }

    // MARK: Interception

    enum Stage { case request, response }
    enum Decision { case forward(String), drop }

    final class HeldItem: Identifiable {
        let id = UUID()
        let flow: Flow
        let stage: Stage
        var raw: String
        fileprivate var continuation: CheckedContinuation<Decision, Never>?
        init(flow: Flow, stage: Stage, raw: String) { self.flow = flow; self.stage = stage; self.raw = raw }
    }

    /// Suspends the proxy session until the user forwards or drops the message.
    func hold(_ flow: Flow, stage: Stage, raw: String) async -> Decision {
        await withCheckedContinuation { cont in
            let item = HeldItem(flow: flow, stage: stage, raw: raw)
            item.continuation = cont
            flow.state = .held
            held.append(item)
            NotificationCenter.default.post(name: .labHeldChanged, object: nil)
        }
    }

    func forward(_ item: HeldItem) {
        guard let cont = item.continuation else { return }
        item.continuation = nil
        held.removeAll { $0.id == item.id }
        cont.resume(returning: .forward(item.raw))
    }

    func drop(_ item: HeldItem) {
        guard let cont = item.continuation else { return }
        item.continuation = nil
        held.removeAll { $0.id == item.id }
        cont.resume(returning: .drop)
    }

    func forwardAll() { for item in held { forward(item) } }

    private func releaseHeld(stage: Stage) { for item in held where item.stage == stage { forward(item) } }

    // MARK: Config shared with the network side

    @ObservationIgnored let config = OSAllocatedUnfairLock(initialState: LabConfig())

    private func pushConfig() {
        let snapshot = LabConfig(interceptRequests: interceptRequests, interceptResponses: interceptResponses, scope: scope,
                                 inScopeOnly: inScopeOnlyIntercept, rules: rules.filter(\.enabled), allowInvalidUpstream: allowInvalidUpstream)
        config.withLock { $0 = snapshot }
    }

    private func persistRules() {
        if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: "labRules") }
    }

    // MARK: Repeater

    @discardableResult
    func sendToRepeater(_ flow: Flow) -> RepeaterTab {
        var req = flow.request
        if !req.target.hasPrefix("/") { req.target = URL(string: req.target).map { ($0.path.isEmpty ? "/" : $0.path) + ($0.query.map { "?" + $0 } ?? "") } ?? req.target }
        let tab = RepeaterTab(title: "\(flow.method) \(flow.host)", scheme: flow.scheme, host: flow.host, port: flow.port, request: req)
        repeaterTabs.append(tab)
        selectedRepeater = tab.id
        return tab
    }

    func newRepeater() {
        let tab = RepeaterTab(title: "New", scheme: "https", host: "example.com", port: 443,
                              request: HTTPRequestMessage(method: "GET", target: "/", headers: [HTTPHeader(name: "Host", value: "example.com"), HTTPHeader(name: "User-Agent", value: "Searchy-Repeater")]))
        repeaterTabs.append(tab)
        selectedRepeater = tab.id
    }
}

extension Notification.Name { static let labHeldChanged = Notification.Name("searchy.lab.held") }

nonisolated struct LabConfig: Sendable {
    var interceptRequests = false
    var interceptResponses = false
    var scope: [String] = []
    var inScopeOnly = true
    var rules: [RewriteRule] = []
    var allowInvalidUpstream = false

    func inScope(_ host: String) -> Bool {
        scope.isEmpty || scope.contains { TrafficLab.matches(pattern: $0, host: host) }
    }
}

/// A Burp-style "match and replace" rule applied to traffic as it passes through.
nonisolated struct RewriteRule: Codable, Identifiable, Hashable, Sendable {
    enum Target: String, Codable, CaseIterable, Sendable {
        case requestHeader = "Request header", requestBody = "Request body", responseHeader = "Response header", responseBody = "Response body"
    }
    var id = UUID()
    var enabled = true
    var target: Target = .requestHeader
    var pattern = ""
    var replacement = ""
    var isRegex = false
    var comment = ""
}

@MainActor @Observable
final class RepeaterTab: Identifiable {
    let id = UUID()
    var title: String
    var scheme: String
    var host: String
    var port: Int
    var rawRequest: String
    var originalBody: Data
    var followRedirects = false
    var response: HTTPResponseMessage?
    var duration: TimeInterval?
    var error: String?
    var isSending = false
    var history: [(date: Date, status: Int, ms: Int)] = []

    init(title: String, scheme: String, host: String, port: Int, request: HTTPRequestMessage) {
        self.title = title; self.scheme = scheme; self.host = host; self.port = port
        self.rawRequest = request.rawText
        self.originalBody = request.body
    }

    var targetLabel: String { "\(scheme)://\(host)\(port == (scheme == "https" ? 443 : 80) ? "" : ":\(port)")" }

    func send() async {
        guard let request = HTTPRequestMessage.parse(rawText: rawRequest, originalBody: originalBody) else {
            error = "Couldn’t parse the request. The first line should look like: GET /path HTTP/1.1"
            return
        }
        isSending = true; error = nil
        let started = Date()
        let url = URL(string: "\(targetLabel)\(request.target.hasPrefix("/") ? request.target : "/" + request.target)")
        guard let url else { error = "Invalid URL"; isSending = false; return }
        do {
            let result = try await Replay.send(request, to: url, followRedirects: followRedirects,
                                               allowInvalidCerts: TrafficLab.shared.config.withLock { $0.allowInvalidUpstream })
            response = result
            duration = Date().timeIntervalSince(started)
            history.insert((Date(), result.status, Int((duration ?? 0) * 1000)), at: 0)
        } catch {
            self.error = error.localizedDescription
            response = nil
        }
        isSending = false
    }
}
