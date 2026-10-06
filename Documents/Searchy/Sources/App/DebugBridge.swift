#if DEBUG || SEARCHY_BRIDGE
import AppKit
import WebKit
import Network
import SwiftUI

/// Development-only remote control. When launched with SEARCHY_DEBUG=1 the app watches
/// `~/Library/Caches/Searchy/debug/command.json`, runs the command, and writes `result.json`
/// (plus a window snapshot when asked). Lets the app be driven and inspected without
/// Screen Recording or Accessibility permission. Compiled out of Release builds.
@MainActor
enum DebugBridge {
    private static var timer: Timer?
    private static var lastRun = Date.distantPast

    static func start() {
        guard ProcessInfo.processInfo.environment["SEARCHY_DEBUG"] == "1" else { return }
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated { poll() }
        }
    }

    private static var directory: URL { Paths.caches.appendingPathComponent("debug", isDirectory: true) }   // honors SEARCHY_HOME
    private static var commandURL: URL { directory.appendingPathComponent("command.json") }
    private static var resultURL: URL { directory.appendingPathComponent("result.json") }

    private static func poll() {
        guard let data = try? Data(contentsOf: commandURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        try? FileManager.default.removeItem(at: commandURL)
        Task { @MainActor in
            var result = await run(obj)
            result["cmd"] = obj["cmd"] ?? ""
            if let out = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: resultURL, options: .atomic)
            }
        }
    }

    private static func run(_ cmd: [String: Any]) async -> [String: Any] {
        let name = cmd["cmd"] as? String ?? ""
        guard let model = BrowserRegistry.shared.frontmost else { return ["error": "no window"] }
        switch name {
        case "state":
            return state(model)
        case "open":
            if let s = cmd["url"] as? String, let url = URL(string: s) { model.open(url, inNewTab: cmd["newTab"] as? Bool ?? false) }
            return state(model)
        case "navigate":
            model.navigate(cmd["text"] as? String ?? "")
            return state(model)
        case "newTab":
            model.newTabWithPalette()
            return state(model)
        case "palette":
            model.openPalette(prefill: cmd["text"] as? String ?? "")
            return state(model)
        case "closePalette":
            model.closePalette()
            return state(model)
        case "pin":
            if let t = model.selectedTab { model.togglePin(t) }
            return state(model)
        case "sleep":
            model.selectedTab?.sleep(force: true)
            return state(model)
        case "wake":
            model.selectedTab?.activate()
            return state(model)
        case "space":
            if let n = cmd["n"] as? Int { model.switchSpace(number: n) }
            return state(model)
        case "addSpace":
            model.addSpace(SpaceInfo(name: cmd["name"] as? String ?? "Work", symbol: "briefcase.fill", color: .orange, isolated: cmd["isolated"] as? Bool ?? false))
            return state(model)
        case "sidebar":
            model.toggleSidebar()
            return state(model)
        case "layout":
            Preferences.shared.tabLayout = (cmd["value"] as? String) == "top" ? .top : .sidebar
            return state(model)
        case "reader":
            model.selectedTab?.toggleReader()
            return state(model)
        case "eval":
            guard let js = cmd["js"] as? String, let view = model.selectedTab?.webView else { return ["error": "no web view"] }
            let value = try? await view.evaluateJavaScript(js)
            return ["value": "\(value ?? "nil")"]
        case "paletteResults":
            let vm = CommandBarModel()
            model.palette = PaletteState(isOpen: false, opensNewTab: false, prefill: cmd["text"] as? String ?? "", ephemeralTabID: nil)
            vm.bind(model)
            try? await Task.sleep(for: .seconds(cmd["seconds"] as? Double ?? 2))
            return ["items": vm.items.map { "\($0.hint) | \($0.title) | \($0.subtitle)" }]
        case "sleepOthers":
            model.sleepIdleTabs(olderThan: 0)
            return state(model)
        case "route":
            let want = cmd["value"] as? String ?? "direct"
            if let t = model.selectedTab { t.setRoute(want == "inspect" ? .inspect : .direct) }
            return state(model)
        case "lab":
            let lab = TrafficLab.shared
            return ["running": lab.isRunning, "port": Int(lab.port), "flows": lab.flows.count, "held": lab.held.count,
                    "recent": lab.flows.suffix(8).map { "\($0.id) \($0.method) \($0.urlString) -> \($0.status.map(String.init) ?? "-") \($0.state)" }]
        case "labIntercept":
            TrafficLab.shared.interceptRequests = cmd["on"] as? Bool ?? true
            return ["interceptRequests": TrafficLab.shared.interceptRequests]
        case "labForwardAll":
            TrafficLab.shared.forwardAll()
            return ["held": TrafficLab.shared.held.count]
        case "memory":
            return ["appMB": Double(MemoryManager.appFootprint) / 1_048_576,
                    "tabs": model.allTabs.map { ["title": $0.displayTitle, "mb": Double($0.sampleMemory()) / 1_048_576, "asleep": $0.isSleeping] as [String: Any] },
                    "budgetMB": Double(MemoryManager.budgetBytes) / 1_048_576]
        case "delegateCheck":
            // Every selector WebKit would call on our coordinator; any "MISSING" means a silently dead handler.
            let expected = [
                "webView:decidePolicyForNavigationAction:preferences:decisionHandler:",
                "webView:decidePolicyForNavigationResponse:decisionHandler:",
                "webView:navigationAction:didBecomeDownload:", "webView:navigationResponse:didBecomeDownload:",
                "webView:didCommitNavigation:", "webView:didFinishNavigation:", "webView:didFailNavigation:withError:",
                "webView:didFailProvisionalNavigation:withError:", "webViewWebContentProcessDidTerminate:",
                "webView:didReceiveAuthenticationChallenge:completionHandler:",
                "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:", "webViewDidClose:",
                "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
                "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
                "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:",
                "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:",
                "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:",
                "userContentController:didReceiveScriptMessage:",
            ]
            let coordinator: AnyClass = TabCoordinator.self
            return ["results": expected.map { (class_respondsToSelector(coordinator, NSSelectorFromString($0)) ? "ok      " : "MISSING ") + $0 }]
        case "offlineSave":
            guard let tab = model.selectedTab, let view = tab.webView else { return ["error": "no web view"] }
            let item = await OfflineStore.shared.save(from: view)
            return ["saved": item != nil, "bytes": item?.bytes ?? 0, "count": OfflineStore.shared.items.count]
        case "offlineLoad":
            guard let tab = model.selectedTab, let item = OfflineStore.shared.items.first(where: { $0.url.contains(cmd["match"] as? String ?? "") }),
                  let data = OfflineStore.shared.data(for: item), let url = URL(string: item.url) else { return ["error": "none saved"] }
            tab.webView?.load(data, mimeType: "application/x-webarchive", characterEncodingName: "utf-8", baseURL: url)
            try? await Task.sleep(for: .seconds(2))
            return ["title": tab.webView?.title ?? "", "url": tab.webView?.url?.absoluteString ?? ""]
        case "net":
            let n = NetworkMonitor.shared
            n.recheck()
            try? await Task.sleep(for: .seconds(cmd["seconds"] as? Double ?? 5))
            return ["quality": "\(n.quality)", "online": n.isOnline, "interface": n.interfaceName, "rttMs": n.rttMs ?? -1,
                    "portal": n.portalURL?.absoluteString ?? "", "detail": n.detail, "lite": FlightMode.shared.effective.title]
        case "lite":
            FlightMode.shared.level = LiteLevel(rawValue: cmd["level"] as? Int ?? 0) ?? .off
            try? await Task.sleep(for: .seconds(1.5))
            return ["effective": FlightMode.shared.effective.title, "blockerLists": ContentBlocker.shared.activeLists.count]
        case "doctor":
            let d = NetworkDoctor.shared
            d.run()
            for _ in 0..<80 where d.isRunning { try? await Task.sleep(for: .milliseconds(500)) }
            return ["checks": d.checks.map { "\($0.state) | \($0.title) | \($0.detail)" }, "findings": d.findings.map(\.text), "mbps": d.downMbps ?? -1]
        case "openPortal":
            model.openPortal()
            try? await Task.sleep(for: .seconds(2))
            return ["portalTab": model.selectedTab?.isPortal ?? false, "url": model.selectedTab?.url?.absoluteString ?? ""]
        case "tabFlags":
            let t = model.selectedTab
            return ["offlineCopy": t?.isOfflineCopy ?? false, "stalled": t?.stalled ?? false, "title": t?.webView?.title ?? "", "url": t?.webView?.url?.absoluteString ?? t?.url?.absoluteString ?? ""]
        case "routeAdd":
            // {"cmd":"routeAdd","kind":"socks5","host":"127.0.0.1","port":1080}
            var r = RouteProfile(name: cmd["name"] as? String ?? "Test route", kind: RouteKind(rawValue: cmd["kind"] as? String ?? "socks5") ?? .socks5,
                                 host: cmd["host"] as? String ?? "", port: cmd["port"] as? Int ?? 0)
            r.sshUser = cmd["user"] as? String ?? ""
            RouteStore.shared.add(r)
            model.selectedTab?.setRoute(r)
            return ["route": r.id.uuidString, "tabRoute": model.selectedTab?.route.name ?? ""]
        case "routeTest":
            guard let r = RouteStore.shared.profiles.last else { return ["error": "no route"] }
            var out: [String: Any] = ["route": r.name]
            do {
                let ep = NWEndpoint.Port(rawValue: UInt16(clamping: r.port))!
                let cfg = r.kind == .socks5 ? ProxyConfiguration(socksv5Proxy: .hostPort(host: .init(r.host), port: ep)) : ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .init(r.host), port: ep))
                let res = try await RouteTester.test(r, proxy: ProxyConfigurationBox(value: cfg))
                out["ip"] = res.ip; out["loc"] = res.country; out["ms"] = res.ms
            } catch { out["error"] = error.localizedDescription }
            return out
        case "evalIsolated":
            guard let js = cmd["js"] as? String, let view = model.selectedTab?.webView else { return ["error": "no web view"] }
            let value = try? await view.evaluateJavaScript(js, in: nil, contentWorld: WebEngine.world)
            return ["value": "\(value ?? "nil")"]
        case "privateTab":
            let tab = model.newTab(url: URL(string: cmd["url"] as? String ?? "about:blank"), select: true, isPrivate: true)
            return ["id": tab.id.uuidString.prefix(8).description, "private": tab.isPrivate]
        case "selectIndex":
            if let n = cmd["n"] as? Int { model.selectTab(number: n) }
            return state(model)
        case "closeSelected":
            model.closeSelectedTab()
            return state(model)
        case "shutdownSave":
            model.saveSessionNow()
            return ["saved": true]
        case "renderView":
            // Renders a SwiftUI view offscreen so sheets/popovers can be reviewed without a screen.
            let name = cmd["view"] as? String ?? ""
            let path = cmd["path"] as? String ?? directory.appendingPathComponent("view.png").path
            let dark = cmd["dark"] as? Bool ?? true
            let content: AnyView
            switch name {
            case "flightPopover": content = AnyView(FlightPopover(model: model, dismiss: {}))
            case "doctor": content = AnyView(NetworkDoctorSheet(model: model))
            case "offline": content = AnyView(OfflineSheet(model: model))
            case "prep": content = AnyView(FlightPrepSheet(model: model))
            case "routes": content = AnyView(RoutesSheet(model: model))
            case "memory": content = AnyView(MemorySheet(model: model))
            case "spaceEditor": content = AnyView(SpaceEditor(model: model, request: SpaceEditorRequest(info: SpaceInfo(name: "Work", symbol: "briefcase.fill", color: .orange), isNew: true)))
            case "banner": content = AnyView(NetworkBanner(model: model).frame(width: 760, height: 120))
            default: return ["error": "unknown view"]
            }
            let renderer = ImageRenderer(content: content.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return ["error": "render failed"] }
            try? png.write(to: URL(fileURLWithPath: path))
            return ["path": path, "size": "\(Int(image.size.width))x\(Int(image.size.height))"]
        case "indexSearch":
            let hits = await ContentIndex.shared.search(cmd["q"] as? String ?? "", limit: 5)
            return ["count": await ContentIndex.shared.count(), "hits": hits.map { "\($0.title) | \($0.snippet)" }]
        case "inspector":
            guard let view = model.selectedTab?.webView else { return ["error": "no web view"] }
            let responds = view.responds(to: NSSelectorFromString("_inspector"))
            view.showInspector(console: true)
            try? await Task.sleep(for: .seconds(1))
            view.showInspector(console: false)
            return ["respondsToInspector": responds, "inspectable": view.isInspectable, "alive": true]
        case "wait":
            try? await Task.sleep(for: .seconds(cmd["seconds"] as? Double ?? 1))
            return state(model)
        case "snapshot":
            let path = cmd["path"] as? String ?? directory.appendingPathComponent("window.png").path
            var out = state(model)
            out["snapshot"] = await snapshot(model: model, to: path) ? path : "failed"
            return out
        default:
            return ["error": "unknown command \(name)"]
        }
    }

    private static func state(_ model: BrowserModel) -> [String: Any] {
        func tab(_ t: Tab) -> [String: Any] {
            ["id": t.id.uuidString.prefix(8).description, "title": t.title, "url": t.url?.absoluteString ?? "",
             "sleeping": t.isSleeping, "loading": t.isLoading, "progress": t.progress, "pinned": t.isPinned,
             "private": t.isPrivate, "audio": t.isPlayingAudio, "video": t.hasPlayingVideo, "readable": t.isReadable,
             "reader": t.isReaderActive, "login": t.hasLoginForm, "hasFavicon": t.favicon != nil, "secure": t.isSecure]
        }
        return [
            "windows": BrowserRegistry.shared.models.count,
            "activeSpace": model.activeSpace.info.name,
            "spaces": model.spaces.map { ["name": $0.info.name, "isolated": $0.info.isolated, "pinned": $0.pinned.count, "tabs": $0.tabs.count] },
            "selected": model.selectedTab.map(tab) as Any,
            "tabs": model.activeSpace.allTabs.map(tab),
            "palette": model.palette.isOpen,
            "sidebarVisible": model.sidebarVisible,
            "layout": Preferences.shared.tabLayout.rawValue,
            "toasts": model.toasts.map(\.text),
            "adRulesLoaded": ContentBlocker.shared.adList != nil,
            "blockerReady": ContentBlocker.shared.isReady,
        ]
    }

    /// Renders the window's SwiftUI chrome and composites the live page on top of it.
    private static func snapshot(model: BrowserModel, to path: String) async -> Bool {
        guard let window = model.window, let content = window.contentView else { return false }
        let bounds = content.bounds
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        content.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)

        var pageImage: NSImage?
        var pageFrame = NSRect.zero
        if let web = model.selectedTab?.webView, web.window != nil {
            pageFrame = web.convert(web.bounds, to: content)
            pageImage = try? await web.takeSnapshot(configuration: WKSnapshotConfiguration())
        }
        let composed = NSImage(size: bounds.size, flipped: false) { _ in
            image.draw(in: bounds)
            if let pageImage {
                // `pageFrame` is in the content view's (flipped) space; NSImage drawing here is unflipped.
                let y = content.isFlipped ? bounds.height - pageFrame.maxY : pageFrame.minY
                let clip = NSBezierPath(roundedRect: NSRect(x: pageFrame.minX, y: y, width: pageFrame.width, height: pageFrame.height),
                                        xRadius: Metrics.cardRadius, yRadius: Metrics.cardRadius)
                clip.addClip()
                pageImage.draw(in: NSRect(x: pageFrame.minX, y: y, width: pageFrame.width, height: pageFrame.height))
            }
            return true
        }
        guard let tiff = composed.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
#endif
