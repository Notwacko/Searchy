import AppKit
import WebKit
import Network
import CryptoKit

/// Owns everything shared between web views: the content world, injected scripts, rule lists,
/// data stores and the Safari-compatible user agent.
@MainActor
final class WebEngine {
    static let shared = WebEngine()

    /// Isolated world for Searchy's own scripts — pages can't see or spoof them.
    static let world = WKContentWorld.world(name: "Searchy")

    private var scriptCache: [String: String] = [:]
    private var controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var spaceStores: [UUID: WKWebsiteDataStore] = [:]
    private var routeStoreKeys: [UUID: UUID] = [:]

    /// Sites where video should keep autoplaying: players, feeds and streaming services.
    static let autoplayHosts = ["youtube.com", "youtu.be", "netflix.com", "twitch.tv", "vimeo.com", "spotify.com", "tiktok.com",
                                "disneyplus.com", "hulu.com", "max.com", "primevideo.com", "x.com", "twitter.com", "instagram.com",
                                "facebook.com", "reddit.com", "soundcloud.com", "bilibili.com", "dailymotion.com", "apple.com"]

    /// Searchy's page bridge, with the current autoplay policy baked in.
    private func makeBridgeScript() -> WKUserScript {
        let lite = FlightMode.shared.isActive
        let allow = lite ? [] : Self.autoplayHosts + SiteSettings.shared.autoplayAllowed.sorted()
        let json = (try? JSONSerialization.data(withJSONObject: allow)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let prefix = "window.__searchyAutoplay = {stop: \(Preferences.shared.stopAutoplay || lite), allow: \(json)};\n"
        return WKUserScript(source: prefix + source("bridge"), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.world)
    }

    /// Looks like Safari to sites (so Google sign-in, Netflix, etc. behave), reports the real WebKit underneath.
    let userAgentSuffix: String = {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return "Version/\(major).0 Safari/605.1.15"
    }()

    private init() {
        ContentBlocker.shared.onChange = { [weak self] old, new in self?.swapRuleLists(old: old, new: new) }
        HiddenElementStore.shared.onChange = { Task { await ContentBlocker.shared.rebuildHidden() } }
        SiteSettings.shared.onAdAllowlistChange = { Task { await ContentBlocker.shared.rebuildAds() } }
    }

    // MARK: Data stores

    func dataStore(for space: SpaceInfo, privateStore: WKWebsiteDataStore?, route: RouteProfile = .direct) -> WKWebsiteDataStore {
        if let privateStore { return privateStore }
        if !route.isDirect { return routedStore(space: space, route: route) }
        guard space.isolated else { return .default() }
        if let store = spaceStores[space.id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: space.id)
        spaceStores[space.id] = store
        return store
    }

    /// A persistent store of its own for a (space, route) pair, with the route's proxy wired in.
    private func routedStore(space: SpaceInfo, route: RouteProfile) -> WKWebsiteDataStore {
        let scope = space.isolated ? space.id.uuidString : "shared"
        let key = Self.uuid(from: "\(scope)|\(route.id.uuidString)")
        if let store = spaceStores[key] { return store }
        let store = WKWebsiteDataStore(forIdentifier: key)
        if let config = Self.proxyConfiguration(for: route) { store.proxyConfigurations = [config] }
        spaceStores[key] = store
        routeStoreKeys[key] = route.id
        return store
    }

    static func proxyConfiguration(for route: RouteProfile) -> ProxyConfiguration? {
        func endpoint(_ host: String, _ port: Int) -> NWEndpoint? {
            NWEndpoint.Port(rawValue: UInt16(clamping: port)).map { .hostPort(host: NWEndpoint.Host(host), port: $0) }
        }
        switch route.kind {
        case .direct:
            return nil
        case .inspect:
            let port = TrafficLab.shared.port
            guard port != 0, let ep = endpoint("127.0.0.1", Int(port)) else { return nil }
            return ProxyConfiguration(httpCONNECTProxy: ep)
        case .socks5:
            guard let ep = endpoint(route.host, route.port) else { return nil }
            var config = ProxyConfiguration(socksv5Proxy: ep)
            if !route.username.isEmpty, let password = RouteSecrets.password(for: route.id) { config.applyCredential(username: route.username, password: password) }
            return config
        case .ssh, .wireguard:
            // The tunnel exposes a local SOCKS5 port.
            guard let port = TunnelManager.shared.port(for: route), let ep = endpoint("127.0.0.1", Int(port)) else { return nil }
            return ProxyConfiguration(socksv5Proxy: ep)
        case .httpConnect:
            guard let ep = endpoint(route.host, route.port) else { return nil }
            var config = ProxyConfiguration(httpCONNECTProxy: ep, tlsOptions: route.useTLS ? NWProtocolTLS.Options() : nil)
            if !route.username.isEmpty, let password = RouteSecrets.password(for: route.id) { config.applyCredential(username: route.username, password: password) }
            return config
        }
    }

    /// A stable UUID derived from text (so the same space+route always maps to the same store).
    private static func uuid(from text: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Drops cached stores for a route so changed proxy settings take effect on the next tab load.
    func forgetRoute(_ id: UUID) {
        for key in spaceStores.keys where routeStoreKeys[key] == id { spaceStores[key] = nil; routeStoreKeys[key] = nil }
    }

    func removeDataStore(for space: SpaceInfo) {
        spaceStores[space.id] = nil
        let id = space.id
        Task { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
    }

    // MARK: Configuration

    func makeConfiguration(dataStore: WKWebsiteDataStore, portal: Bool = false) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.applicationNameForUserAgent = userAgentSuffix
        config.upgradeKnownHostsToHTTPS = !portal      // captive portals are plain HTTP
        config.allowsAirPlayForMediaPlayback = true
        let prefs = config.preferences
        prefs.isElementFullscreenEnabled = true
        prefs.isFraudulentWebsiteWarningEnabled = true
        prefs.setValue(true, forKey: "developerExtrasEnabled")   // enables Inspect Element in the context menu
        ExtensionManager.shared.attach(to: config)
        return config
    }

    /// Installs Searchy's scripts, rule lists and message handler on a configuration's content controller.
    func install(on config: WKWebViewConfiguration, handler: WKScriptMessageHandler, portal: Bool = false) {
        let controller = WKUserContentController()
        controller.addUserScript(makeBridgeScript())
        controller.add(WeakScriptHandler(handler), contentWorld: Self.world, name: "searchy")
        if !portal {
            for list in ContentBlocker.shared.activeLists { controller.add(list) }
            controllers.add(controller)
        }
        config.userContentController = controller
    }

    func makeWebView(configuration: WKWebViewConfiguration) -> SearchyWebView {
        let view = SearchyWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.isInspectable = true
        view.setValue(false, forKey: "drawsBackground") // avoid a white flash behind the rounded card in dark mode
        return view
    }

    func discard(_ view: WKWebView) {
        let controller = view.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "searchy", contentWorld: Self.world)
        controller.removeAllUserScripts()
        controller.removeAllContentRuleLists()
        controllers.remove(controller)
    }

    private func swapRuleLists(old: [WKContentRuleList], new: [WKContentRuleList]) {
        for controller in controllers.allObjects {
            for list in old { controller.remove(list) }
            for list in new { controller.add(list) }
        }
    }

    // MARK: Scripts on demand

    /// Runs one of the bundled scripts (idempotent) and then an expression that uses it.
    @discardableResult
    func run(_ script: String, expression: String, in webView: WKWebView, frame: WKFrameInfo? = nil) async -> Any? {
        let js = source(script) + "\n;(() => { return " + expression + "; })()"
        return try? await webView.evaluateJavaScript(js, in: frame, contentWorld: Self.world)
    }

    func call(_ expression: String, in webView: WKWebView, frame: WKFrameInfo? = nil) async -> Any? {
        try? await webView.evaluateJavaScript("(async () => { return await (\(expression)); })()", in: frame, contentWorld: Self.world)
    }

    func source(_ name: String) -> String {
        if let cached = scriptCache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        scriptCache[name] = text
        return text
    }
}

/// `WKUserContentController` retains its handlers; this proxy keeps the tab from being retained by its own web view.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
