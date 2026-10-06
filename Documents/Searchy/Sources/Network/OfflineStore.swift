import Foundation
import Observation
import WebKit

nonisolated struct OfflineItem: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var url: String
    var title: String
    var host: String
    var savedAt: Date
    var bytes: Int
    /// First part of the page text, so saved pages can be found by what they say — even offline.
    var excerpt: String
    var file: String
}

/// Pages saved for offline use as WebKit web archives (the page plus its images and styles).
@MainActor @Observable
final class OfflineStore {
    static let shared = OfflineStore()

    private(set) var items: [OfflineItem] = []
    /// Oldest saved pages are dropped beyond this.
    var capBytes = 800 << 20

    @ObservationIgnored private let dir: URL
    @ObservationIgnored private let index = JSONFile<[OfflineItem]>("Offline.json")

    private init() {
        dir = Paths.appSupport.appendingPathComponent("Offline", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        items = (index.load() ?? []).sorted { $0.savedAt > $1.savedAt }
    }

    var totalBytes: Int { items.reduce(0) { $0 + $1.bytes } }

    // MARK: Saving

    /// Archives whatever `view` is showing right now.
    @discardableResult
    func save(from view: WKWebView, title fallbackTitle: String = "") async -> OfflineItem? {
        guard let url = view.url, let scheme = url.scheme, scheme == "http" || scheme == "https" else { return nil }
        guard let data = await Self.archiveData(view), data.count > 200 else { return nil }
        let text = (try? await view.evaluateJavaScript("(document.body && document.body.innerText || '').replace(/\\s+/g,' ').slice(0,4000)")) as? String ?? ""
        let title = (view.title?.isEmpty == false ? view.title : nil) ?? (fallbackTitle.isEmpty ? url.host ?? url.absoluteString : fallbackTitle)
        return store(data: data, url: url, title: title, excerpt: text)
    }

    private static func archiveData(_ view: WKWebView) async -> Data? {
        await withCheckedContinuation { cont in
            view.createWebArchiveData { result in cont.resume(returning: try? result.get()) }
        }
    }

    private func store(data: Data, url: URL, title: String, excerpt: String) -> OfflineItem? {
        let key = Self.key(url)
        let name = "\(UUID().uuidString).webarchive"
        do { try data.write(to: dir.appendingPathComponent(name), options: .atomic) } catch { return nil }
        if let old = items.first(where: { Self.key(URL(string: $0.url)) == key }) { remove(old.id, persist: false) }
        let item = OfflineItem(url: url.absoluteString, title: title, host: url.host?.strippingWWW ?? "", savedAt: Date(),
                               bytes: data.count, excerpt: excerpt, file: name)
        items.insert(item, at: 0)
        trim()
        index.save(items)
        return item
    }

    private func trim() {
        while totalBytes > capBytes, let oldest = items.last { remove(oldest.id, persist: false) }
    }

    // MARK: Reading

    func item(for url: URL?) -> OfflineItem? {
        guard let key = Self.key(url) else { return nil }
        return items.first { Self.key(URL(string: $0.url)) == key }
    }

    func data(for item: OfflineItem) -> Data? { try? Data(contentsOf: dir.appendingPathComponent(item.file)) }

    func search(_ text: String, limit: Int = 5) -> [OfflineItem] {
        let terms = text.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        return items.filter { item in
            let hay = (item.title + " " + item.url + " " + item.excerpt).lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }.prefix(limit).map { $0 }
    }

    // MARK: Removing

    func remove(_ id: UUID, persist: Bool = true) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(items[i].file))
        items.remove(at: i)
        if persist { index.save(items) }
    }

    func removeAll() {
        for item in items { try? FileManager.default.removeItem(at: dir.appendingPathComponent(item.file)) }
        items = []
        index.save(items)
    }

    nonisolated static func key(_ url: URL?) -> String? {
        guard let url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.fragment = nil
        var s = c.string ?? url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s.lowercased()
    }
}

/// Loads pages in a hidden web view just to archive them — used by "Prepare for flight".
@MainActor
final class PageSaver: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Returns true if the page was archived.
    func save(_ url: URL, dataStore: WKWebsiteDataStore, timeout: TimeInterval = 30) async -> Bool {
        let config = WebEngine.shared.makeConfiguration(dataStore: dataStore)
        WebEngine.shared.install(on: config, handler: self)
        let view = WebEngine.shared.makeWebView(configuration: config)
        view.frame = NSRect(x: 0, y: 0, width: 1280, height: 900)
        view.navigationDelegate = self
        defer { WebEngine.shared.discard(view); view.navigationDelegate = nil }

        let loaded: Bool = await withCheckedContinuation { cont in
            continuation = cont
            view.load(URLRequest(url: url))
            Task { try? await Task.sleep(for: .seconds(timeout)); self.finish(false) }
        }
        guard loaded else { return false }
        // Nudge lazy-loaded images into loading, then let them arrive.
        _ = try? await view.evaluateJavaScript("""
            (async () => { const h = document.documentElement.scrollHeight; for (let y = 0; y < Math.min(h, 12000); y += 700) { window.scrollTo(0, y); await new Promise(r => setTimeout(r, 120)); } window.scrollTo(0, 0); })()
            """)
        try? await Task.sleep(for: .seconds(1.2))
        return await OfflineStore.shared.save(from: view) != nil
    }

    private func finish(_ ok: Bool) {
        continuation?.resume(returning: ok)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}

/// "Prepare for flight": saves open tabs, pinned tabs and favorites for offline use, with progress.
@MainActor @Observable
final class FlightPrep {
    static let shared = FlightPrep()

    private(set) var isRunning = false
    private(set) var total = 0
    private(set) var done = 0
    private(set) var failed = 0
    private(set) var current = ""
    private(set) var finished = false
    @ObservationIgnored private var task: Task<Void, Never>?

    var fraction: Double { total == 0 ? 0 : Double(done + failed) / Double(total) }

    func start(model: BrowserModel, includeFavorites: Bool = true) {
        guard !isRunning else { return }
        var urls: [URL] = []
        var seen = Set<String>()
        func add(_ u: URL?) {
            guard let u, u.scheme == "http" || u.scheme == "https", let k = OfflineStore.key(u), seen.insert(k).inserted else { return }
            urls.append(u)
        }
        for tab in model.activeSpace.allTabs where !tab.isPrivate { add(tab.webView?.url ?? tab.url) }
        for space in model.spaces where space !== model.activeSpace { for tab in space.pinned { add(tab.url) } }
        if includeFavorites { for b in BookmarkStore.shared.favorites.prefix(25) { add(URL(string: b.url)) } }
        let live = Dictionary(model.allTabs.compactMap { t in t.webView.map { (OfflineStore.key($0.url) ?? "", $0) } }, uniquingKeysWith: { a, _ in a })

        total = urls.count; done = 0; failed = 0; finished = false; isRunning = true
        task = Task {
            let saver = PageSaver()
            for url in urls {
                if Task.isCancelled { break }
                current = url.host?.strippingWWW ?? url.absoluteString
                var ok = false
                if let view = live[OfflineStore.key(url) ?? ""] { ok = await OfflineStore.shared.save(from: view) != nil }
                if !ok { ok = await saver.save(url, dataStore: .default()) }
                if ok { done += 1 } else { failed += 1 }
            }
            isRunning = false
            finished = true
            current = ""
        }
    }

    func cancel() { task?.cancel(); isRunning = false }
}
