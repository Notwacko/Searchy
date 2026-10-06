import AppKit
import WebKit
import os

/// Receives everything WebKit reports about one tab: navigation policy, popups, dialogs,
/// downloads and messages from Searchy's page scripts.
final class TabCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var tab: Tab?

    // MARK: Navigation policy

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = action.request.url else { return (.allow, preferences) }
        if action.shouldPerformDownload { return (.download, preferences) }

        let scheme = url.scheme?.lowercased() ?? ""
        // Buttons on Searchy's own error pages.
        if scheme == "searchy-action" {
            if let tab { tab.model?.handleAction(url, from: tab) }
            return (.cancel, preferences)
        }
        if !["http", "https", "about", "file", "data", "blob", "view-source"].contains(scheme) {
            // mailto:, tel:, app deep links… belong to other apps.
            if action.navigationType == .linkActivated || action.targetFrame?.isMainFrame == true {
                NSWorkspace.shared.open(url)
            }
            return (.cancel, preferences)
        }

        // ⌘-click and middle-click open a background tab; ⇧⌘-click opens in front.
        if action.navigationType == .linkActivated, let tab, let model = tab.model,
           action.modifierFlags.contains(.command) || action.buttonNumber == 4 {
            model.openLink(url, from: tab, background: !action.modifierFlags.contains(.shift))
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disposition.hasPrefix("attachment") {
            return .download
        }
        return response.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download)
    }

    // MARK: Navigation lifecycle

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { tab?.pageDidCommit() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { tab?.pageDidFinish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { show(error, in: webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        show(error, in: webView)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    private func show(_ error: Error, in webView: WKWebView) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain", ns.code == 102 || ns.code == 204 { return }   // handed off to a download / plug-in
        guard let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? tab?.url else { return }
        tab?.url = failing
        let saved = OfflineStore.shared.item(for: failing)
        if Self.isNetworkProblem(ns), let tab, !tab.isPortal {
            tab.stallNext = true          // reloads itself when the connection comes back
            NetworkMonitor.shared.recheck()
            if let saved, FlightMode.shared.preferOffline { tab.loadOfflineCopy(saved); return }
        }
        let html = ErrorPage.html(for: ns, url: failing, hasSavedCopy: saved != nil, offline: !NetworkMonitor.shared.isOnline)
        webView.loadSimulatedRequest(URLRequest(url: failing), responseHTML: html)
    }

    /// Failures that mean "the network", not "the site".
    private static func isNetworkProblem(_ e: NSError) -> Bool {
        guard e.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorDataNotAllowed, NSURLErrorSecureConnectionFailed].contains(e.code)
    }

    // MARK: Authentication

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust {
            let inspect = tab?.route.kind == .inspect
            let ok = inspect && challenge.protectionSpace.serverTrust.map { CertificateAuthority.shared.validates($0) } == true
            Logger(subsystem: "app.searchy", category: "tls").notice("trust challenge host=\(challenge.protectionSpace.host, privacy: .public) inspect=\(inspect) trusted=\(ok)")
            if ok, let trust = challenge.protectionSpace.serverTrust { return (.useCredential, URLCredential(trust: trust)) }
        }
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM].contains(method),
              challenge.previousFailureCount < 3 else { return (.performDefaultHandling, nil) }
        if let credential = await promptCredentials(for: challenge.protectionSpace) { return (.useCredential, credential) }
        return (.cancelAuthenticationChallenge, nil)
    }

    private func promptCredentials(for space: URLProtectionSpace) async -> URLCredential? {
        let alert = NSAlert()
        alert.messageText = "Sign in to \(space.host)"
        alert.informativeText = space.realm.map { "The site says: “\($0)”" } ?? "Enter your name and password."
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        user.placeholderString = "Name"
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        pass.placeholderString = "Password"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 58))
        box.addSubview(user); box.addSubview(pass)
        alert.accessoryView = box
        alert.window.initialFirstResponder = user
        guard await present(alert) == .alertFirstButtonReturn else { return nil }
        return URLCredential(user: user.stringValue, password: pass.stringValue, persistence: .forSession)
    }

    // MARK: Popups, dialogs, panels

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let tab, let model = tab.model else { return nil }
        return model.openPopup(configuration: configuration, from: tab).webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let tab { tab.model?.close(tab) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = await present(alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page asks"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await present(alert) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page asks"
        alert.informativeText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return await present(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let response: NSApplication.ModalResponse
        if let window = webView.window { response = await panel.beginSheetModal(for: window) } else { response = panel.runModal() }
        return response == .OK ? panel.urls : nil
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        .prompt
    }

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let tab, let model = tab.model, model.selectedTab !== tab { model.select(tab) }   // show the tab that's talking
        if let window = tab?.webView?.window { return await alert.beginSheetModal(for: window) }
        return alert.runModal()
    }

    // MARK: Messages from page scripts

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let tab, let body = message.body as? [String: Any], let kind = body["t"] as? String else { return }
        switch kind {
        case "media":
            let audible = body["audible"] as? Bool ?? false
            let video = body["video"] as? Bool ?? false
            if video { tab.pipFrame = message.frameInfo.isMainFrame ? nil : message.frameInfo }
            if video || message.frameInfo.isMainFrame || !audible { tab.hasPlayingVideo = video || (tab.hasPlayingVideo && !message.frameInfo.isMainFrame && audible) }
            tab.isPlayingAudio = audible
            if !video && !audible { tab.pipFrame = nil }
        case "pip":
            tab.isPiPActive = body["active"] as? Bool ?? false
        case "icons":
            let urls = (body["urls"] as? [String] ?? []).compactMap(URL.init(string:))
            tab.updateFavicon(declared: urls)
        case "readable":
            tab.isReadable = body["value"] as? Bool ?? false
        case "login":
            tab.hasLoginForm = body["has"] as? Bool ?? false
        case "reader":
            tab.isReaderActive = body["active"] as? Bool ?? false
        case "readerPrefs":
            let p = Preferences.shared
            if let t = (body["theme"] as? String).flatMap(ReaderTheme.init(rawValue:)) { p.readerTheme = t }
            if let f = (body["font"] as? String).flatMap(ReaderFont.init(rawValue:)) { p.readerFont = f }
            if let s = body["size"] as? Double { p.readerSize = s }
        case "picker":
            tab.isPickerActive = body["active"] as? Bool ?? false
        case "hide":
            guard let selector = body["selector"] as? String, let host = body["host"] as? String else { return }
            HiddenElementStore.shared.add(selector, host: host)
            tab.model?.toast("Hidden on \(HiddenElementStore.key(host))", symbol: "eye.slash.fill", actionTitle: "Undo") {
                HiddenElementStore.shared.remove(selector, host: host)
                tab.reload()
            }
        case "credentials":
            tab.model?.credentialsSubmitted(from: tab, body: body)
        default:
            break
        }
    }
}
