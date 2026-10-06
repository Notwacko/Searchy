import Foundation

/// On-disk locations. Everything Searchy owns lives under one folder.
nonisolated enum Paths {
    /// Set SEARCHY_HOME to keep all of Searchy's files in one folder (tests, side-by-side dev instances).
    private static let home: URL? = ProcessInfo.processInfo.environment["SEARCHY_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    static let appSupport: URL = home.map { sub($0, "Support") } ?? directory(.applicationSupportDirectory, "Searchy")
    static let caches: URL = home.map { sub($0, "Caches") } ?? directory(.cachesDirectory, "Searchy")
    static let extensions: URL = sub(appSupport, "Extensions")
    static let favicons: URL = sub(caches, "Favicons")

    static func file(_ name: String) -> URL { appSupport.appendingPathComponent(name) }

    private static func directory(_ kind: FileManager.SearchPathDirectory, _ name: String) -> URL {
        let base = FileManager.default.urls(for: kind, in: .userDomainMask)[0]
        return sub(base, name)
    }
    private static func sub(_ base: URL, _ name: String) -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
