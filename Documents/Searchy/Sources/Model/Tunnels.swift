import Foundation
import Network
import Observation

/// Runs the helper processes behind SSH and WireGuard routes and exposes each as a local SOCKS5 port.
/// Nothing runs until a tab actually uses the route.
@MainActor @Observable
final class TunnelManager {
    static let shared = TunnelManager()

    enum TunnelError: LocalizedError {
        case missingTool(String), failed(String), timeout
        var errorDescription: String? {
            switch self {
            case .missingTool(let t): "\(t) isn’t installed."
            case .failed(let why): why
            case .timeout: "The tunnel didn’t come up in time."
            }
        }
    }

    private final class Running {
        let process: Process
        let port: UInt16
        var log = ""
        init(process: Process, port: UInt16) { self.process = process; self.port = port }
    }

    private var running: [UUID: Running] = [:]
    private var starting: [UUID: Task<UInt16, Error>] = [:]
    private(set) var lastError: [UUID: String] = [:]

    func port(for route: RouteProfile) -> UInt16? {
        guard let r = running[route.id], r.process.isRunning else { return nil }
        return r.port
    }

    func isRunning(_ route: RouteProfile) -> Bool { port(for: route) != nil }

    func ensureRunning(_ route: RouteProfile) async throws -> UInt16 {
        if let p = port(for: route) { return p }
        if let task = starting[route.id] { return try await task.value }
        let task = Task { try await self.start(route) }
        starting[route.id] = task
        defer { starting[route.id] = nil }
        do {
            let p = try await task.value
            lastError[route.id] = nil
            return p
        } catch {
            lastError[route.id] = error.localizedDescription
            throw error
        }
    }

    func stop(_ route: RouteProfile) {
        running[route.id]?.process.terminate()
        running[route.id] = nil
    }

    func stopAll() {
        for (_, r) in running { r.process.terminate() }
        running = [:]
    }

    // MARK: Starting

    private func start(_ route: RouteProfile) async throws -> UInt16 {
        let port = Self.freePort()
        let process = Process()
        let log = Pipe()
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice

        switch route.kind {
        case .ssh:
            guard !route.host.isEmpty else { throw TunnelError.failed("Add the server’s address first.") }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            var args = ["-N", "-D", "127.0.0.1:\(port)", "-p", String(route.port > 0 ? route.port : 22),
                        "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                        "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=12", "-C"]
            if !route.identityPath.isEmpty { args += ["-i", (route.identityPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
            args.append(route.sshUser.isEmpty ? route.host : "\(route.sshUser)@\(route.host)")
            process.arguments = args
        case .wireguard:
            guard let tool = Self.find("wireproxy") else { throw TunnelError.missingTool("wireproxy (install with: brew install wireproxy)") }
            guard !route.configPath.isEmpty, let base = try? String(contentsOfFile: (route.configPath as NSString).expandingTildeInPath, encoding: .utf8)
            else { throw TunnelError.failed("Choose a WireGuard .conf file first.") }
            let conf = FileManager.default.temporaryDirectory.appendingPathComponent("searchy-wg-\(route.id.uuidString).conf")
            try (base + "\n\n[Socks5]\nBindAddress = 127.0.0.1:\(port)\n").write(to: conf, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: conf.path)
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = ["-c", conf.path]
        default:
            throw TunnelError.failed("This route doesn’t use a tunnel.")
        }

        let entry = Running(process: process, port: port)
        log.fileHandleForReading.readabilityHandler = { handle in
            let text = String(data: handle.availableData, encoding: .utf8) ?? ""
            Task { @MainActor in entry.log += text; if entry.log.count > 4000 { entry.log = String(entry.log.suffix(2000)) } }
        }
        do { try process.run() } catch { throw TunnelError.failed(error.localizedDescription) }
        running[route.id] = entry

        // Wait for the local SOCKS port to accept connections (or the process to die with a reason).
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(300))
            if !process.isRunning {
                running[route.id] = nil
                let reason = entry.log.split(separator: "\n").last.map(String.init) ?? "exited immediately"
                throw TunnelError.failed(reason)
            }
            if await NetworkDoctor.tcpProbe("127.0.0.1", port, timeout: 1).open { return port }
        }
        process.terminate()
        running[route.id] = nil
        throw TunnelError.timeout
    }

    static func find(_ tool: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", NSHomeDirectory() + "/go/bin", NSHomeDirectory() + "/.local/bin"]
            .map { $0 + "/" + tool }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func freePort() -> UInt16 {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return UInt16(bigEndian: addr.sin_port)
    }
}

/// "Where does this route come out?" — fetches Cloudflare's trace through the route with an ephemeral session.
nonisolated enum RouteTester {
    struct Result: Sendable { var ip: String; var country: String; var colo: String; var ms: Int }

    static func test(_ route: RouteProfile, proxy: ProxyConfigurationBox?) async throws -> Result {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.urlCache = nil
        if let proxy { config.proxyConfigurations = [proxy.value] }
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let started = Date()
        let (data, _) = try await session.data(from: URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!)
        let text = String(data: data, encoding: .utf8) ?? ""
        func field(_ k: String) -> String { text.split(separator: "\n").first { $0.hasPrefix(k + "=") }.map { String($0.dropFirst(k.count + 1)) } ?? "?" }
        return Result(ip: field("ip"), country: field("loc"), colo: field("colo"), ms: Int(Date().timeIntervalSince(started) * 1000))
    }
}

import Network
/// ProxyConfiguration isn't Sendable-annotated for crossing actors here; this carries it safely.
nonisolated struct ProxyConfigurationBox: @unchecked Sendable { let value: ProxyConfiguration }
