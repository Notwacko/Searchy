import Foundation
import Network
import Observation

/// Watches the connection and classifies it, so Searchy can adapt on airplane wifi, hotel portals and flaky links.
@MainActor @Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    enum Quality: Equatable {
        case unknown, offline, captive, restricted, slow, good

        var title: String {
            switch self {
            case .unknown: "Checking connection…"
            case .offline: "Offline"
            case .captive: "Wi-Fi needs sign-in"
            case .restricted: "Restricted network"
            case .slow: "Slow connection"
            case .good: "Connected"
            }
        }
        var symbol: String {
            switch self {
            case .unknown: "wifi"
            case .offline: "wifi.slash"
            case .captive: "wifi.exclamationmark"
            case .restricted: "lock.shield"
            case .slow: "tortoise.fill"
            case .good: "wifi"
            }
        }
    }

    private(set) var isOnline = true
    private(set) var isConstrained = false
    private(set) var isExpensive = false
    private(set) var interfaceName = "—"
    private(set) var quality: Quality = .unknown
    private(set) var rttMs: Int?
    private(set) var portalURL: URL?
    private(set) var lastChecked: Date?
    private(set) var detail = ""

    /// Called when the connection becomes usable again (so stalled tabs can reload).
    @ObservationIgnored var onRecovered: (() -> Void)?

    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let constrained = path.isConstrained, expensive = path.isExpensive
            let name = path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.wiredEthernet) ? "Ethernet"
                : path.usesInterfaceType(.cellular) ? "Cellular" : online ? "Other" : "—"
            Task { @MainActor in self?.pathChanged(online: online, constrained: constrained, expensive: expensive, interface: name) }
        }
        monitor.start(queue: DispatchQueue(label: "app.searchy.netmon", qos: .utility))
        self.monitor = monitor
        // Re-check periodically; cheap when everything is fine, more often when it isn't.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.periodic() }
        }
    }

    private var lastProbe = Date.distantPast

    private func periodic() {
        let interval: TimeInterval = (quality == .good || quality == .unknown) && !FlightMode.shared.isActive ? 600 : 75
        if Date().timeIntervalSince(lastProbe) >= interval { recheck() }
    }

    private func pathChanged(online: Bool, constrained: Bool, expensive: Bool, interface: String) {
        let wasOnline = isOnline
        isOnline = online; isConstrained = constrained; isExpensive = expensive; interfaceName = interface
        if !online {
            quality = .offline; portalURL = nil; detail = "No network connection."
            FlightMode.shared.networkChanged()
            return
        }
        if !wasOnline { detail = "Back online — checking…" }
        recheck()
    }

    /// Runs the captive-portal and latency probes (debounced).
    func recheck() {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            self.lastProbe = Date()
            let result = await NetworkProbes.run()
            guard !Task.isCancelled else { return }
            self.apply(result)
        }
    }

    private func apply(_ r: NetworkProbes.Result) {
        let previous = quality
        rttMs = r.rttMs
        portalURL = r.portalURL
        lastChecked = Date()
        detail = r.detail
        switch r.verdict {
        case .portal: quality = .captive
        case .offline: quality = isOnline ? .restricted : .offline
        case .httpsBlocked: quality = .restricted
        case .ok:
            if isConstrained || (r.rttMs ?? 0) > 900 { quality = .slow } else { quality = .good }
        }
        FlightMode.shared.networkChanged()
        if (previous == .offline || previous == .captive || previous == .restricted) && (quality == .good || quality == .slow) {
            onRecovered?()
        }
    }
}

/// Small, polite network probes. Nothing here runs unless the monitor decides it needs it.
nonisolated enum NetworkProbes {
    struct Result: Sendable {
        enum Verdict: Sendable { case ok, portal, httpsBlocked, offline }
        var verdict: Verdict
        var rttMs: Int?
        var portalURL: URL?
        var detail: String
    }

    static func run() async -> Result {
        // 1. Apple's captive-portal check: plain HTTP, expects the word "Success".
        let captive = await captiveCheck()
        switch captive {
        case .portal(let url):
            return Result(verdict: .portal, rttMs: nil, portalURL: url, detail: "This network wants you to sign in before it lets traffic through.")
        case .unreachable(let why):
            // Try HTTPS before giving up: some networks only allow 443.
            if let rtt = await httpsRTT() {
                return Result(verdict: .ok, rttMs: rtt, portalURL: nil, detail: "Plain HTTP is blocked here, but HTTPS works (\(why)).")
            }
            return Result(verdict: .offline, rttMs: nil, portalURL: nil, detail: "Can’t reach the internet (\(why)).")
        case .clear:
            break
        }
        // 2. HTTPS round trip — also our latency estimate.
        if let rtt = await httpsRTT() {
            return Result(verdict: .ok, rttMs: rtt, portalURL: nil, detail: rtt > 900 ? "Very high latency (\(rtt) ms) — typical of in-flight wifi." : "Round trip \(rtt) ms.")
        }
        return Result(verdict: .httpsBlocked, rttMs: nil, portalURL: nil, detail: "HTTP works but secure (HTTPS) connections are failing — the network may be filtering them.")
    }

    enum Captive { case clear, portal(URL?), unreachable(String) }

    static func captiveCheck() async -> Captive {
        let session = URLSession(configuration: probeConfig(), delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // SEARCHY_CAPTIVE_URL lets tests point the check at a local server that imitates a portal.
        let probeURL = ProcessInfo.processInfo.environment["SEARCHY_CAPTIVE_URL"].flatMap(URL.init(string:)) ?? URL(string: "http://captive.apple.com/hotspot-detect.html")!
        var request = URLRequest(url: probeURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 6)
        request.setValue("CaptiveNetworkSupport/1.0 wispr", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable("no response") }
            if (300..<400).contains(http.statusCode) {
                return .portal(http.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)))
            }
            let body = String(data: data.prefix(2048), encoding: .utf8) ?? ""
            if http.statusCode == 200, body.contains("Success") { return .clear }
            // A 200 with some other page is the other classic portal behaviour.
            return .portal(URL(string: "http://captive.apple.com/hotspot-detect.html"))
        } catch {
            return .unreachable((error as NSError).localizedDescription)
        }
    }

    /// Median time to first byte of three tiny HTTPS requests, in ms; nil if they all fail.
    static func httpsRTT() async -> Int? {
        var samples: [Int] = []
        for _ in 0..<3 {
            let started = Date()
            let session = URLSession(configuration: probeConfig())
            var req = URLRequest(url: URL(string: "https://www.apple.com/library/test/success.html")!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
            req.httpMethod = "HEAD"
            if (try? await session.data(for: req)) != nil { samples.append(Int(Date().timeIntervalSince(started) * 1000)) }
            session.invalidateAndCancel()
            if samples.isEmpty && Date().timeIntervalSince(started) > 7 { break }   // don't spend ages on a dead link
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }

    static func probeConfig() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.timeoutIntervalForRequest = 8
        return c
    }

    final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
