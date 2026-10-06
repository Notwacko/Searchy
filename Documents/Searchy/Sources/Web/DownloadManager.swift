import AppKit
import WebKit
import Observation

@MainActor @Observable
final class DownloadItem: Identifiable {
    enum State: Equatable { case running, finished, failed(String), cancelled }

    let id = UUID()
    var filename: String
    var sourceURL: URL?
    var destination: URL?
    var fraction: Double = 0
    var state: State = .running
    @ObservationIgnored fileprivate var download: WKDownload?
    @ObservationIgnored fileprivate var progressObservation: NSKeyValueObservation?

    init(filename: String, sourceURL: URL?) { self.filename = filename; self.sourceURL = sourceURL }

    func cancel() {
        download?.cancel()
        state = .cancelled
    }

    func reveal() { if let destination { NSWorkspace.shared.activateFileViewerSelecting([destination]) } }
    func open() { if let destination { NSWorkspace.shared.open(destination) } }
}

@MainActor @Observable
final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()

    private(set) var items: [DownloadItem] = []
    @ObservationIgnored private var byDownload: [ObjectIdentifier: DownloadItem] = [:]

    var activeCount: Int { items.filter { $0.state == .running }.count }

    func adopt(_ download: WKDownload) {
        let item = DownloadItem(filename: download.originalRequest?.url?.lastPathComponent ?? "Download",
                                sourceURL: download.originalRequest?.url)
        item.download = download
        byDownload[ObjectIdentifier(download)] = item
        items.insert(item, at: 0)
        download.delegate = self
        item.progressObservation = download.progress.observe(\.fractionCompleted) { [weak item] progress, _ in
            let value = progress.fractionCompleted
            MainActor.assumeIsolated { item?.fraction = value }
        }
        BrowserRegistry.shared.frontmost?.downloadsPopoverShown = true
    }

    func clearFinished() { items.removeAll { $0.state != .running } }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let url = Self.uniqueURL(in: dir, name: suggestedFilename)
        if let item = byDownload[ObjectIdentifier(download)] {
            item.filename = url.lastPathComponent
            item.destination = url
        }
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = byDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.state = .finished
        item.fraction = 1
        item.download = nil
        if let path = item.destination?.path {
            // Makes the Downloads stack in the Dock bounce, like Safari.
            DistributedNotificationCenter.default().post(name: Notification.Name("com.apple.DownloadFileFinished"), object: path)
        }
        BrowserRegistry.shared.frontmost?.toast("Downloaded \(item.filename)", symbol: "arrow.down.circle.fill",
                                               actionTitle: "Show") { item.reveal() }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = byDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        if item.state != .cancelled { item.state = .failed(error.localizedDescription) }
        item.download = nil
    }

    private static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 1
        repeat {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        } while fm.fileExists(atPath: url.path)
        return url
    }
}
