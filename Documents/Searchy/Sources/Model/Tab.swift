import AppKit
import WebKit
import Observation

/// One browser tab. The web view is created lazily and can be released at any time
/// ("sleep") without losing history or scroll position — which is what keeps Searchy light.
@MainActor @Observable
final class Tab: Identifiable {
    let id: UUID
    let isPrivate: Bool
    @ObservationIgnored weak var model: BrowserModel?
    var spaceID: UUID

    // What the UI shows (survives sleeping).
    var url: URL?
    var title: String
    var favicon: NSImage?
    var isPinned = false
    var pinnedHome: URL?
    /// nil = direct. Anything else routes this tab's traffic through a proxy / the Traffic Lab.
    var routeID: UUID?

    // Live state.
    var isLoading = false
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    var isSecure = false
    var isPlayingAudio = false
    var hasPlayingVideo = false
    var isPiPActive = false
    var isReaderActive = false
    var isReadable = false
    var isPickerActive = false
    var hasLoginForm = false
    var themeColor: NSColor?
    /// A captive-portal sign-in tab: plain HTTP allowed, no content blocking, direct route.
    var isPortal = false
    /// Showing a saved (offline) copy rather than the live page.
    var isOfflineCopy = false
    /// The last load failed because of the network; reload automatically when it's back.
    var stalled = false
    var lastActive = Date()
    /// Last sampled memory of this tab's web process, in bytes (0 while asleep).
    var memoryBytes: UInt64 = 0

    private(set) var webView: SearchyWebView?

    @ObservationIgnored var savedState: Data?
    @ObservationIgnored private var pendingOffline: OfflineItem?
    @ObservationIgnored private var expectOfflineCommit = false
    /// Set just before an error page loads, so the flag survives that page's own commit.
    @ObservationIgnored var stallNext = false
    @ObservationIgnored var pipFrame: WKFrameInfo?
    @ObservationIgnored private let coordinator = TabCoordinator()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(id: UUID = UUID(), spaceID: UUID, url: URL? = nil, title: String = "", isPrivate: Bool = false) {
        self.id = id
        self.spaceID = spaceID
        self.url = url
        self.title = title
        self.isPrivate = isPrivate
        coordinator.tab = self
        if !isPrivate, let host = url?.host { favicon = FaviconStore.shared.cached(host: host) }
    }

    // MARK: Display helpers

    var host: String? { url?.host?.strippingWWW }
    var displayTitle: String { title.isEmpty ? (host ?? "New Tab") : title }
    var isSleeping: Bool { webView == nil }
    var route: RouteProfile { RouteStore.shared.profile(routeID) }
    /// True when there's nothing to show yet, so the new-tab page is displayed.
    var isBlank: Bool { url == nil && webView?.url == nil }

    /// A single letter for pinned tiles: the first letter of the site's name.
    var letter: String {
        guard let h = host else { return "•" }
        let parts = h.split(separator: ".")
        let name = parts.count >= 2 ? parts[parts.count - 2] : (parts.first ?? "")
        return String(name.first ?? "•").uppercased()
    }

    // MARK: Lifecycle

    /// Creates the web view if needed and starts loading (or restores saved state).
    func wake(configuration popup: WKWebViewConfiguration? = nil) {
        guard webView == nil, let model else { return }
        // A Traffic Lab tab needs the local proxy to be listening before its web view exists.
        if popup == nil, route.kind == .inspect, !TrafficLab.shared.isRunning {
            Task { await TrafficLab.shared.ensureRunning(); wake() }
            return
        }
        // SSH / WireGuard routes need their tunnel up first.
        if popup == nil, route.needsTunnel, TunnelManager.shared.port(for: route) == nil {
            let r = route
            Task {
                do { _ = try await TunnelManager.shared.ensureRunning(r) }
                catch { model.toast("Route “\(r.name)” failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill"); return }
                wake()
            }
            return
        }
        let config = popup ?? WebEngine.shared.makeConfiguration(dataStore: model.dataStore(for: self), portal: isPortal)
        WebEngine.shared.install(on: config, handler: coordinator, portal: isPortal)
        let view = WebEngine.shared.makeWebView(configuration: config)
        view.tab = self
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        webView = view
        observe(view)
        guard popup == nil else { return }   // a popup's content is supplied by WebKit
        let state = savedState
        savedState = nil
        let target = url
        let offline = pendingOffline
        pendingOffline = nil
        whenBlockerReady { [weak view] in
            guard let view else { return }
            if let offline, let data = OfflineStore.shared.data(for: offline), let u = URL(string: offline.url) {
                view.load(data, mimeType: "application/x-webarchive", characterEncodingName: "utf-8", baseURL: u)
            } else if let state { view.interactionState = state }
            else if let target { view.load(URLRequest(url: target)) }
        }
    }

    /// Releases the web view. History and scroll position are kept in `savedState`.
    func sleep(force: Bool = false) {
        guard let view = webView else { return }
        if !force && (isPlayingAudio || isPiPActive) { return }
        savedState = view.interactionState as? Data
        if let current = view.url { url = current }
        observations.removeAll()
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
        WebEngine.shared.discard(view)
        webView = nil
        isLoading = false
        progress = 0
        isPlayingAudio = false
        hasPlayingVideo = false
        isPiPActive = false
        isReaderActive = false
        isPickerActive = false
        hasLoginForm = false
        pipFrame = nil
    }

    /// Moves this tab to another route. The page reloads in the route's own cookie jar.
    func setRoute(_ new: RouteProfile) {
        guard !isPrivate, new.id != route.id || (new.isDirect && routeID != nil) else { return }
        let current = webView?.url ?? url
        sleep(force: true)
        savedState = nil
        url = current
        routeID = new.isDirect ? nil : new.id
        if model?.selectedTab === self { wake() }
        model?.sessionDirty()
    }

    @discardableResult
    func sampleMemory() -> UInt64 {
        memoryBytes = MemoryManager.footprint(of: webView) ?? 0
        return memoryBytes
    }

    func activate() {
        lastActive = Date()
        // A blank tab is just our new-tab page: no web view (and no web process) until something loads.
        if url != nil || savedState != nil { wake() }
        if isPiPActive { exitPiP() }
    }

    func deactivate() {
        lastActive = Date()
        if hasPlayingVideo, Preferences.shared.autoFloatVideo, !isPiPActive { enterPiP() }
    }

    private func whenBlockerReady(_ work: @escaping () -> Void) {
        if ContentBlocker.shared.isReady { work(); return }
        Task { await ContentBlocker.shared.waitUntilReady(); work() }
    }

    // MARK: Navigation

    func load(_ target: URL) {
        stalled = false
        // No usable connection but we hold a saved copy: show that instantly instead of an error.
        let net = NetworkMonitor.shared
        if !isPortal, FlightMode.shared.preferOffline, net.quality == .offline || net.quality == .captive,
           let saved = OfflineStore.shared.item(for: target) {
            loadOfflineCopy(saved)
            return
        }
        url = target
        if let view = webView {
            view.load(URLRequest(url: target))
        } else {
            savedState = nil
            wake()
        }
    }

    func loadOfflineCopy(_ item: OfflineItem) {
        guard let target = URL(string: item.url) else { return }
        url = target
        title = item.title
        expectOfflineCommit = true
        if let view = webView, let data = OfflineStore.shared.data(for: item) {
            view.load(data, mimeType: "application/x-webarchive", characterEncodingName: "utf-8", baseURL: target)
        } else {
            savedState = nil
            pendingOffline = item
            wake()
        }
    }

    /// Saves what this tab shows so it can be read with no connection.
    @discardableResult
    func saveForOffline() async -> Bool {
        guard let view = webView, !isPrivate else { return false }
        let ok = await OfflineStore.shared.save(from: view, title: displayTitle) != nil
        model?.toast(ok ? "Saved for offline reading" : "Couldn’t save this page", symbol: ok ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill",
                     actionTitle: ok ? "Library" : nil) { [weak self] in self?.model?.sheet = .offline }
        return ok
    }

    /// Back to the live page after viewing a saved copy.
    func openLive() {
        guard let u = url else { return }
        isOfflineCopy = false
        webView?.load(URLRequest(url: u))
    }

    func reload(fromOrigin: Bool = false) {
        guard let view = webView else { wake(); return }
        if view.url == nil, let url { view.load(URLRequest(url: url)); return }
        fromOrigin ? view.reloadFromOrigin() : view.reload()
    }

    func stop() { webView?.stopLoading() }
    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func goHome() { if let pinnedHome { load(pinnedHome) } }

    func setZoom(_ value: Double) {
        let z = min(5, max(0.25, value))
        webView?.pageZoom = z
        SiteSettings.shared.setZoom(z, for: url?.host)
    }
    func zoomIn() { setZoom((webView?.pageZoom ?? 1) + 0.1) }
    func zoomOut() { setZoom((webView?.pageZoom ?? 1) - 0.1) }
    func zoomReset() { setZoom(1) }

    // MARK: Page features

    func toggleReader() {
        guard let view = webView else { return }
        let p = Preferences.shared
        let args = "{theme:'\(p.readerTheme.rawValue)',font:'\(p.readerFont.rawValue)',size:\(Int(p.readerSize))}"
        Task {
            let result = await WebEngine.shared.run("reader", expression: "window.__searchy.reader.toggle(\(args))", in: view)
            if (result as? String) == "unavailable" {
                model?.toast("No article found on this page", symbol: "doc.questionmark")
            }
        }
    }

    func togglePicker() {
        guard let view = webView else { return }
        Task { _ = await WebEngine.shared.run("picker", expression: "window.__searchy.picker.toggle()", in: view) }
    }

    func enterPiP() {
        guard let view = webView else { return }
        let frame = pipFrame
        Task {
            let ok = await WebEngine.shared.call("window.__searchy.enterPiP()", in: view, frame: frame) as? Bool
            if ok != true { model?.toast("No video to float on this page", symbol: "pip") }
        }
    }

    func exitPiP() {
        guard let view = webView else { return }
        let frame = pipFrame
        Task { _ = await WebEngine.shared.call("window.__searchy.exitPiP()", in: view, frame: frame) }
    }

    func toggleFloatingVideo() { isPiPActive ? exitPiP() : enterPiP() }

    // MARK: Coordinator hooks

    func pageDidCommit() {
        isOfflineCopy = expectOfflineCommit
        expectOfflineCommit = false
        stalled = stallNext
        stallNext = false
        isReaderActive = false
        isReadable = false
        isPickerActive = false
        hasLoginForm = false
        hasPlayingVideo = false
        isPlayingAudio = false
        isPiPActive = false
        pipFrame = nil
        if let view = webView, let host = view.url?.host {
            view.pageZoom = SiteSettings.shared.zoom(for: host)
            favicon = isPrivate ? nil : FaviconStore.shared.cached(host: host)
        }
        model?.sessionDirty()
    }

    func pageDidFinish() {
        guard let view = webView, let current = view.url else { return }
        url = current
        if !isPrivate { HistoryStore.shared.record(url: current, title: view.title ?? title) }
        model?.sessionDirty()
        scheduleIndexing(for: current)
    }

    /// After the reader has had a moment with the page, add its text to the private search index.
    private func scheduleIndexing(for target: URL) {
        guard !isPrivate, !isPortal, Preferences.shared.indexPages, target.scheme?.hasPrefix("http") == true else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, let view = self.webView, view.url == target, !self.hasLoginForm, !self.isOfflineCopy else { return }
            let js = "(document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').trim().slice(0, 30000)"
            guard let text = (try? await view.evaluateJavaScript(js)) as? String, text.count > 400 else { return }
            ContentIndex.shared.add(url: target, title: view.title ?? self.title, text: text)
        }
    }

    func updateFavicon(declared: [URL]) {
        guard !isPrivate, let host = webView?.url?.host else { return }
        Task {
            if let image = await FaviconStore.shared.icon(host: host, declared: declared), webView?.url?.host == host {
                favicon = image
            }
        }
    }

    // MARK: Observation

    private func observe(_ view: SearchyWebView) {
        observations = [
            view.observe(\.title) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.titleChanged(v.title) }
            },
            view.observe(\.url) { [weak self] v, _ in
                MainActor.assumeIsolated { if let u = v.url { self?.url = u; self?.model?.sessionDirty() } }
            },
            view.observe(\.isLoading) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.isLoading = v.isLoading }
            },
            view.observe(\.estimatedProgress) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.progress = v.estimatedProgress }
            },
            view.observe(\.canGoBack) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.canGoBack = v.canGoBack }
            },
            view.observe(\.canGoForward) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.canGoForward = v.canGoForward }
            },
            view.observe(\.hasOnlySecureContent) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.isSecure = v.hasOnlySecureContent }
            },
            view.observe(\.themeColor) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.themeColor = v.themeColor }
            },
        ]
    }

    private func titleChanged(_ new: String?) {
        guard let new, !new.isEmpty else { return }
        title = new
        if !isPrivate, let u = webView?.url { HistoryStore.shared.updateTitle(url: u, title: new) }
        model?.sessionDirty()
    }

    // MARK: Persistence

    func snapshot() -> TabSnapshot {
        TabSnapshot(id: id, url: (webView?.url ?? url)?.absoluteString, title: title, home: pinnedHome?.absoluteString,
                    state: (webView?.interactionState as? Data) ?? savedState, route: routeID)
    }
}
