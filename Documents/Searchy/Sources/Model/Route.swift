import Foundation
import Observation

nonisolated enum RouteKind: String, Codable, CaseIterable, Sendable {
    case direct, inspect, socks5, httpConnect, ssh, wireguard

    var title: String {
        switch self {
        case .direct: "Direct"
        case .inspect: "Traffic Lab"
        case .socks5: "SOCKS5 proxy"
        case .httpConnect: "HTTP(S) proxy"
        case .ssh: "SSH tunnel"
        case .wireguard: "WireGuard"
        }
    }
}

/// Where a tab's network traffic goes. Each non-direct route gets its own cookie jar,
/// so a tab routed through a proxy never shares sign-ins with your normal tabs.
nonisolated struct RouteProfile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var kind: RouteKind
    var host = ""
    var port = 0
    var username = ""
    /// Talk to an HTTP proxy over TLS (looks like ordinary HTTPS to restrictive networks).
    var useTLS = false
    /// SSH tunnel: the account on the server (host/port above), and an optional private key file.
    var sshUser = ""
    var identityPath = ""
    /// WireGuard: path to a `.conf` file (run through `wireproxy`).
    var configPath = ""

    static let inspectID = UUID(uuidString: "5EA2C4F0-0000-4000-8000-000000000001")!
    static let inspect = RouteProfile(id: inspectID, name: "Inspect with Traffic Lab", kind: .inspect)
    static let direct = RouteProfile(id: UUID(uuidString: "5EA2C4F0-0000-4000-8000-000000000000")!, name: "Direct", kind: .direct)

    var isDirect: Bool { kind == .direct }
    var symbol: String {
        switch kind {
        case .direct: "arrow.right"
        case .inspect: "scope"
        case .socks5, .httpConnect: "network"
        case .ssh: "terminal"
        case .wireguard: "lock.shield"
        }
    }

    /// Routes that need a helper process to be running before a tab can use them.
    var needsTunnel: Bool { kind == .ssh || kind == .wireguard }
}

@MainActor @Observable
final class RouteStore {
    static let shared = RouteStore()

    private(set) var profiles: [RouteProfile] = []
    @ObservationIgnored private let file = JSONFile<[RouteProfile]>("Routes.json")

    private init() { profiles = file.load() ?? [] }

    /// Direct, the Traffic Lab, then the user's own proxies.
    var all: [RouteProfile] { [.direct, .inspect] + profiles }

    func profile(_ id: UUID?) -> RouteProfile {
        guard let id else { return .direct }
        return all.first { $0.id == id } ?? .direct
    }

    func add(_ p: RouteProfile) { profiles.append(p); file.save(profiles) }
    func update(_ p: RouteProfile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p; file.save(profiles) }
    }
    func remove(_ id: UUID) { profiles.removeAll { $0.id == id }; file.save(profiles) }
}
