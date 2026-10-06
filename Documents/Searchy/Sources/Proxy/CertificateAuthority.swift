import Foundation
import Security
import os

/// A private certificate authority for the Traffic Lab. It signs a throwaway certificate per site so the
/// proxy can read HTTPS. The CA is only ever trusted by tabs you've chosen to inspect — it is never
/// added to the system keychain.
nonisolated final class CertificateAuthority: @unchecked Sendable {
    static let shared = CertificateAuthority()

    private let dir = Paths.appSupport.appendingPathComponent("TrafficLabCA", isDirectory: true)
    private let lock = NSLock()
    private var cachedCA: SecCertificate?

    /// `SecIdentity` is immutable and thread-safe, but isn't marked Sendable.
    private struct IdentityBox: @unchecked Sendable { let identity: SecIdentity }
    private struct Cache { var identities: [String: IdentityBox] = [:]; var inflight: [String: Task<IdentityBox, Error>] = [:] }
    private let cache = OSAllocatedUnfairLock(initialState: Cache())

    private var caKey: URL { dir.appendingPathComponent("ca.key") }
    private var caCert: URL { dir.appendingPathComponent("ca.crt") }
    private let openssl = "/usr/bin/openssl"
    private let p12Password = "searchy"

    private init() { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

    // MARK: CA

    func ensureCA() throws {
        if FileManager.default.fileExists(atPath: caCert.path), FileManager.default.fileExists(atPath: caKey.path) { return }
        let cnf = dir.appendingPathComponent("ca.cnf")
        try """
        [req]
        distinguished_name = dn
        x509_extensions = v3
        prompt = no
        [dn]
        CN = Searchy Traffic Lab CA
        O = Searchy
        [v3]
        basicConstraints = critical,CA:TRUE
        keyUsage = critical,keyCertSign,cRLSign
        subjectKeyIdentifier = hash
        """.write(to: cnf, atomically: true, encoding: .utf8)
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", caKey.path, "-out", caCert.path,
                 "-days", "3650", "-sha256", "-config", cnf.path])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: caKey.path)
    }

    func regenerate() throws {
        lock.lock(); cachedCA = nil; lock.unlock()
        cache.withLock { $0 = Cache() }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ensureCA()
    }

    func caCertificate() throws -> SecCertificate {
        lock.lock(); defer { lock.unlock() }
        if let cachedCA { return cachedCA }
        try ensureCA()
        let pem = try Data(contentsOf: caCert)
        var items: CFArray?
        var format = SecExternalFormat.formatPEMSequence
        var type = SecExternalItemType.itemTypeCertificate
        guard SecItemImport(pem as CFData, nil, &format, &type, [], nil, nil, &items) == errSecSuccess,
              let cert = (items as? [SecCertificate])?.first else { throw CAError.importFailed }
        cachedCA = cert
        return cert
    }

    var caPEMURL: URL { caCert }

    /// SHA-256 fingerprint of the CA, for display.
    func fingerprint() -> String {
        guard let cert = try? caCertificate() else { return "—" }
        let der = SecCertificateCopyData(cert) as Data
        var digest = [UInt8](repeating: 0, count: 32)
        der.withUnsafeBytes { _ = CC_SHA256_shim($0.baseAddress, UInt32(der.count), &digest) }
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: Leaf certificates

    func identity(for host: String) async throws -> SecIdentity {
        enum Plan { case ready(IdentityBox), wait(Task<IdentityBox, Error>) }
        let plan: Plan = cache.withLock { state in
            if let box = state.identities[host] { return .ready(box) }
            if let task = state.inflight[host] { return .wait(task) }
            let task = Task.detached { [self] in IdentityBox(identity: try makeIdentity(host)) }
            state.inflight[host] = task
            return .wait(task)
        }
        switch plan {
        case .ready(let box): return box.identity
        case .wait(let task):
            do {
                let box = try await task.value
                cache.withLock { $0.identities[host] = box; $0.inflight[host] = nil }
                return box.identity
            } catch {
                cache.withLock { $0.inflight[host] = nil }
                throw error
            }
        }
    }

    private func makeIdentity(_ host: String) throws -> SecIdentity {
        try ensureCA()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("searchy-leaf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let key = work.appendingPathComponent("leaf.key"), csr = work.appendingPathComponent("leaf.csr")
        let crt = work.appendingPathComponent("leaf.crt"), p12 = work.appendingPathComponent("leaf.p12")
        let ext = work.appendingPathComponent("ext.cnf"), req = work.appendingPathComponent("req.cnf")
        let isIP = host.allSatisfy { $0.isNumber || $0 == "." } || host.contains(":")
        let san = isIP ? "IP:\(host)" : "DNS:\(host)"
        try """
        [req]
        distinguished_name = dn
        prompt = no
        [dn]
        CN = \(host.prefix(60))
        """.write(to: req, atomically: true, encoding: .utf8)
        try """
        basicConstraints = CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = \(san)
        """.write(to: ext, atomically: true, encoding: .utf8)
        try run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key.path])
        try run(["req", "-new", "-key", key.path, "-out", csr.path, "-config", req.path])
        try run(["x509", "-req", "-in", csr.path, "-CA", caCert.path, "-CAkey", caKey.path, "-CAcreateserial",
                 "-out", crt.path, "-days", "397", "-sha256", "-extfile", ext.path])
        try run(["pkcs12", "-export", "-inkey", key.path, "-in", crt.path, "-certfile", caCert.path, "-out", p12.path,
                 "-passout", "pass:\(p12Password)"])
        var items: CFArray?
        let status = SecPKCS12Import(try Data(contentsOf: p12) as CFData, [kSecImportExportPassphrase as String: p12Password] as CFDictionary, &items)
        guard status == errSecSuccess, let entry = (items as? [[String: Any]])?.first,
              let identity = entry[kSecImportItemIdentity as String] else { throw CAError.importFailed }
        return identity as! SecIdentity
    }

    // MARK: Trust (used by inspected tabs)

    /// True when `trust` is valid with Searchy's CA as an anchor.
    func validates(_ trust: SecTrust) -> Bool {
        guard let ca = try? caCertificate() else { return false }
        SecTrustSetAnchorCertificates(trust, [ca] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, false)
        return SecTrustEvaluateWithError(trust, nil)
    }

    // MARK: Helpers

    @discardableResult
    private func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: openssl)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw CAError.openssl(String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "failed")
        }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    enum CAError: Error, LocalizedError {
        case importFailed, openssl(String)
        var errorDescription: String? {
            switch self {
            case .importFailed: "Couldn’t load the certificate."
            case .openssl(let m): "openssl failed: \(m)"
            }
        }
    }
}

import CommonCrypto
private nonisolated func CC_SHA256_shim(_ data: UnsafeRawPointer?, _ len: UInt32, _ out: UnsafeMutablePointer<UInt8>) -> UnsafeMutablePointer<UInt8>? {
    CC_SHA256(data, len, out)
}
