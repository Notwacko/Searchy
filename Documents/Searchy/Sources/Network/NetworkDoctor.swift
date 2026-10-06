import Foundation
import Network
import Observation
import Security

/// Walks through the usual ways a network can fail — portals, blocked ports, DNS tampering, TLS interception,
/// bad latency or bandwidth — and says what to do about each.
@MainActor @Observable
final class NetworkDoctor {
    static let shared = NetworkDoctor()

    enum State: Equatable { case pending, running, ok, warn, fail }
    enum Fix: Equatable { case signIn, lite, textOnly, saveOffline, routes }

    struct Check: Identifiable {
        let id: String
        var title: String
        var symbol: String
        var state: State = .pending
        var detail = ""
    }
    struct Finding: Identifiable {
        let id = UUID()
        var text: String
        var fix: Fix?
        var fixTitle: String { switch fix { case .signIn: "Sign In"; case .lite: "Turn On Lite"; case .textOnly: "Text Only"; case .saveOffline: "Prepare for Flight"; case .routes: "Open Routes"; case nil: "" } }
    }

    private(set) var checks: [Check] = NetworkDoctor.blank()
    private(set) var findings: [Finding] = []
    private(set) var isRunning = false
    private(set) var hasRun = false
    private(set) var downMbps: Double?
    private(set) var rttMs: Int?
    @ObservationIgnored private var task: Task<Void, Never>?

    private static func blank() -> [Check] {
        [Check(id: "link", title: "Connection", symbol: "wifi"),
         Check(id: "portal", title: "Sign-in page (captive portal)", symbol: "person.badge.key"),
         Check(id: "dns", title: "Name lookup (DNS)", symbol: "magnifyingglass"),
         Check(id: "ports", title: "Open ports", symbol: "point.3.connected.trianglepath.dotted"),
         Check(id: "tls", title: "Secure connections (HTTPS)", symbol: "lock.shield"),
         Check(id: "speed", title: "Speed and latency", symbol: "speedometer")]
    }

    func run() {
        guard !isRunning else { return }
        checks = Self.blank(); findings = []; downMbps = nil; rttMs = nil
        isRunning = true; hasRun = true
        task = Task {
            await linkCheck()
            await portalCheck()
            await dnsCheck()
            await portsCheck()
            await tlsCheck()
            await speedCheck()
            summarize()
            isRunning = false
        }
    }

    func cancel() { task?.cancel(); isRunning = false }

    private func set(_ id: String, _ state: State, _ detail: String) {
        guard let i = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[i].state = state; checks[i].detail = detail
    }
    private func begin(_ id: String) { set(id, .running, "") }

    // MARK: Checks

    private func linkCheck() async {
        begin("link")
        let n = NetworkMonitor.shared
        guard n.isOnline else { set("link", .fail, "No network connection. Check Wi-Fi or Airplane mode."); return }
        var bits = [n.interfaceName]
        if n.isConstrained { bits.append("Low Data Mode") }
        if n.isExpensive { bits.append("metered") }
        set("link", n.isConstrained || n.isExpensive ? .warn : .ok, bits.joined(separator: " · "))
    }

    private func portalCheck() async {
        begin("portal")
        switch await NetworkProbes.captiveCheck() {
        case .clear: set("portal", .ok, "No sign-in page in the way.")
        case .portal(let url):
            set("portal", .fail, "This network is holding traffic until you sign in" + (url?.host.map { " (\($0))" } ?? "") + ".")
            findings.append(Finding(text: "Sign in to the Wi-Fi first — nothing else will load until you do.", fix: .signIn))
        case .unreachable(let why):
            set("portal", .warn, "Couldn’t reach Apple’s check server: \(why)")
        }
    }

    private func dnsCheck() async {
        begin("dns")
        let t0 = Date()
        let known = await Self.resolve("apple.com")
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let bogus = await Self.resolve("searchy-\(UUID().uuidString.prefix(8).lowercased()).invalid-test.com")
        if known.isEmpty {
            set("dns", .fail, "Names don’t resolve. DNS is blocked or broken here.")
            findings.append(Finding(text: "DNS isn’t working. If another resolver is reachable, a route that resolves names remotely (SOCKS5/HTTPS proxy) avoids the problem.", fix: .routes))
        } else if !bogus.isEmpty {
            set("dns", .warn, "Lookups work (\(ms) ms), but made-up names also resolve — this network rewrites DNS answers (typical of portals and filters).")
        } else {
            set("dns", .ok, "Resolved apple.com in \(ms) ms.")
        }
    }

    private func portsCheck() async {
        begin("ports")
        let targets: [(String, UInt16, String)] = [("1.1.1.1", 443, "HTTPS 443"), ("1.1.1.1", 80, "HTTP 80"), ("1.1.1.1", 53, "DNS 53"),
                                                    ("github.com", 22, "SSH 22"), ("1.1.1.1", 853, "DNS-over-TLS 853"), ("8.8.8.8", 443, "HTTPS (alt)")]
        var open: [String] = [], blocked: [String] = []
        await withTaskGroup(of: (String, Bool).self) { group in
            for (host, port, label) in targets { group.addTask { (label, await Self.tcpProbe(host, port).open) } }
            for await (label, ok) in group { if ok { open.append(label) } else { blocked.append(label) } }
        }
        open.sort(); blocked.sort()
        if open.isEmpty {
            set("ports", .fail, "Nothing connects. Blocked: \(blocked.joined(separator: ", ")).")
        } else {
            set("ports", blocked.isEmpty ? .ok : .warn, "Open: \(open.joined(separator: ", "))" + (blocked.isEmpty ? "" : " · Blocked: \(blocked.joined(separator: ", "))"))
            if blocked.contains("SSH 22") && open.contains("HTTPS 443") {
                findings.append(Finding(text: "SSH is blocked but HTTPS (443) is open. An HTTPS-CONNECT proxy or an SSH server listening on port 443 will get through.", fix: .routes))
            }
        }
    }

    private func tlsCheck() async {
        begin("tls")
        let result = await Self.tlsProbe()
        switch result {
        case .trusted(let issuer):
            let known = ["DigiCert", "Apple", "Let’s Encrypt", "Let's Encrypt", "GlobalSign", "Sectigo", "Amazon", "Google", "Microsoft", "Cloudflare", "ISRG", "USERTrust"]
            if known.contains(where: { issuer.localizedCaseInsensitiveContains($0) }) {
                set("tls", .ok, "Certificates look genuine (issued by \(issuer)).")
            } else {
                set("tls", .warn, "Certificates are valid but issued by “\(issuer)”, not a usual public authority — this network may be inspecting HTTPS.")
            }
        case .untrusted(let why):
            set("tls", .fail, "Secure connections are being rejected: \(why). A portal or filter may be intercepting HTTPS.")
        case .failed(let why):
            set("tls", .fail, "Couldn’t make a secure connection: \(why)")
        }
    }

    private func speedCheck() async {
        begin("speed")
        let rtt = await NetworkProbes.httpsRTT()
        rttMs = rtt
        guard let rtt else { set("speed", .fail, "Couldn’t measure — HTTPS requests are failing."); return }
        let mbps = await Self.downloadSpeed()
        downMbps = mbps
        let speedText = mbps.map { String(format: "%.1f Mbps down", $0) } ?? "download test failed"
        let slow = (mbps ?? 0) < 1.5 || rtt > 700
        set("speed", slow ? .warn : .ok, "\(rtt) ms round trip · \(speedText)")
        if slow {
            findings.append(Finding(text: "This connection is slow. Lite mode skips video, fonts and heavy extras; Text only also drops images.", fix: .lite))
            findings.append(Finding(text: "Save the pages you’ll want while you’re on a good connection.", fix: .saveOffline))
        }
    }

    private func summarize() {
        if findings.isEmpty, checks.allSatisfy({ $0.state == .ok }) {
            findings = [Finding(text: "Everything looks healthy.", fix: nil)]
        }
    }

    // MARK: Probes

    nonisolated static func resolve(_ host: String) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { cont.resume(returning: []); return }
                var out: [String] = []
                var p: UnsafeMutablePointer<addrinfo>? = first
                while let node = p {
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(node.pointee.ai_addr, node.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                        out.append(String(cString: buf))
                    }
                    p = node.pointee.ai_next
                }
                freeaddrinfo(first)
                cont.resume(returning: out)
            }
        }
    }

    nonisolated static func tcpProbe(_ host: String, _ port: UInt16, timeout: TimeInterval = 4) async -> (open: Bool, ms: Int?) {
        await withCheckedContinuation { cont in
            guard let p = NWEndpoint.Port(rawValue: port) else { cont.resume(returning: (false, nil)); return }
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let queue = DispatchQueue(label: "app.searchy.probe")
            let start = Date()
            let done = ProbeFlag()
            let finish: @Sendable (Bool) -> Void = { ok in
                guard done.take() else { return }
                conn.cancel()
                cont.resume(returning: (ok, ok ? Int(Date().timeIntervalSince(start) * 1000) : nil))
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed: finish(false)
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    private nonisolated final class ProbeFlag: @unchecked Sendable {
        private let lock = NSLock(); private var taken = false
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; if taken { return false }; taken = true; return true }
    }

    enum TLSResult: Sendable { case trusted(issuer: String), untrusted(String), failed(String) }

    nonisolated static func tlsProbe() async -> TLSResult {
        final class Delegate: NSObject, URLSessionDelegate, @unchecked Sendable {
            var issuer = ""
            func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
                if let trust = challenge.protectionSpace.serverTrust,
                   let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], chain.count > 1 {
                    issuer = SecCertificateCopySubjectSummary(chain[1]) as String? ?? ""
                }
                completionHandler(.performDefaultHandling, nil)
            }
        }
        let delegate = Delegate()
        let session = URLSession(configuration: NetworkProbes.probeConfig(), delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: URL(string: "https://www.apple.com/library/test/success.html")!)
            return .trusted(issuer: delegate.issuer.isEmpty ? "a public authority" : delegate.issuer)
        } catch let e as NSError {
            if (-1207 ... -1200).contains(e.code) || e.code == NSURLErrorServerCertificateUntrusted { return .untrusted(e.localizedDescription) }
            return .failed(e.localizedDescription)
        }
    }

    nonisolated static func downloadSpeed() async -> Double? {
        let session = URLSession(configuration: NetworkProbes.probeConfig())
        defer { session.invalidateAndCancel() }
        let started = Date()
        guard let (data, _) = try? await session.data(from: URL(string: "https://speed.cloudflare.com/__down?bytes=400000")!), data.count > 50_000 else { return nil }
        let seconds = max(Date().timeIntervalSince(started), 0.05)
        return Double(data.count) * 8 / seconds / 1_000_000
    }
}
