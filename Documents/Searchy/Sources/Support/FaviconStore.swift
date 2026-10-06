import AppKit
import ImageIO

/// Per-host favicon cache: memory first, then disk, then the network. Icons are shrunk to 64px.
@MainActor
final class FaviconStore {
    static let shared = FaviconStore()

    private let memory = NSCache<NSString, NSImage>()
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private let maxAge: TimeInterval = 3 * 24 * 3600

    private init() { memory.countLimit = 400 }

    /// Instant lookup of a previously stored icon.
    func cached(host: String) -> NSImage? {
        let key = host as NSString
        if let image = memory.object(forKey: key) { return image }
        guard let data = try? Data(contentsOf: fileURL(host)), let image = NSImage(data: data) else { return nil }
        memory.setObject(image, forKey: key)
        return image
    }

    /// Returns a fresh icon, downloading from the page's declared icons and `/favicon.ico` when needed.
    func icon(host: String, declared: [URL]) async -> NSImage? {
        if let existing = cached(host: host), !isStale(host) || FlightMode.shared.isActive || !NetworkMonitor.shared.isOnline { return existing }
        if FlightMode.shared.isActive { return nil }
        if let task = inflight[host] { return await task.value }
        let candidates = declared + (URL(string: "https://\(host)/favicon.ico").map { [$0] } ?? [])
        let file = fileURL(host)
        let task = Task { [weak self] () -> NSImage? in
            guard let png = await Self.download(candidates) else { return self?.cached(host: host) }
            try? png.write(to: file, options: .atomic)
            guard let image = NSImage(data: png) else { return nil }
            self?.memory.setObject(image, forKey: host as NSString)
            return image
        }
        inflight[host] = task
        let result = await task.value
        inflight[host] = nil
        return result
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: Paths.favicons)
        try? FileManager.default.createDirectory(at: Paths.favicons, withIntermediateDirectories: true)
    }

    // MARK: -

    private func fileURL(_ host: String) -> URL {
        let safe = host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        return Paths.favicons.appendingPathComponent(String(safe) + ".png")
    }

    private func isStale(_ host: String) -> Bool {
        guard let date = (try? fileURL(host).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return true }
        return Date().timeIntervalSince(date) > maxAge
    }

    private nonisolated static func download(_ candidates: [URL]) async -> Data? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        let session = URLSession(configuration: config)
        for url in candidates.prefix(5) {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  data.count > 60, data.count < 600_000,
                  let png = thumbnailPNG(from: data) else { continue }
            return png
        }
        return nil
    }

    nonisolated static func thumbnailPNG(from data: Data, maxPixel: Int = 64) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        var best = 0, bestWidth = 0
        for i in 0..<CGImageSourceGetCount(source) {
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            if w > bestWidth { best = i; bestWidth = w }
        }
        guard bestWidth >= 16 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, best, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
