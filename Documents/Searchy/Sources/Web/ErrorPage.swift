import Foundation

/// The page shown when a navigation fails. Rendered through `loadSimulatedRequest`, so Reload retries the real URL.
nonisolated enum ErrorPage {
    static func html(for error: NSError, url: URL, hasSavedCopy: Bool = false, offline: Bool = false) -> String {
        let (title, detail, symbol) = describe(error)
        let host = url.host ?? url.absoluteString
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? ""
        var buttons = "<a class=\"btn primary\" href=\"searchy-action://retry?u=\(encoded)\">Try Again</a>"
        if hasSavedCopy { buttons += "<a class=\"btn\" href=\"searchy-action://offline?u=\(encoded)\">Open Saved Copy</a>" }
        if !offline { buttons += "<a class=\"btn\" href=\"searchy-action://lite?u=\(encoded)\">Try in Lite Mode</a>" }
        buttons += "<a class=\"btn\" href=\"searchy-action://doctor\">Network Doctor</a>"

        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <title>\(escape(title))</title><style>
        :root{color-scheme:light dark}
        body{margin:0;min-height:100vh;display:grid;place-items:center;font:15px/1.5 -apple-system,system-ui,sans-serif;
             background:Canvas;color:CanvasText}
        main{max-width:460px;padding:40px;text-align:center}
        .icon{font-size:52px;margin-bottom:10px;filter:saturate(.8)}
        h1{font-size:26px;letter-spacing:-.02em;margin:0 0 8px}
        p{color:GrayText;margin:6px 0}
        code{font:13px ui-monospace,Menlo,monospace;background:color-mix(in srgb,CanvasText 8%,transparent);padding:2px 7px;border-radius:6px}
        .row{display:flex;flex-wrap:wrap;gap:8px;justify-content:center;margin-top:22px}
        .btn{font:600 13px -apple-system,system-ui;padding:9px 16px;border-radius:999px;text-decoration:none;color:CanvasText;
             background:color-mix(in srgb,CanvasText 9%,transparent)}
        .btn.primary{background:#0a84ff;color:#fff}
        .btn:active{filter:brightness(.9)}
        small{display:block;margin-top:26px;color:GrayText;opacity:.7;font-size:12px}
        </style></head><body><main>
        <div class="icon">\(symbol)</div>
        <h1>\(escape(title))</h1>
        <p>\(escape(detail))</p><p><code>\(escape(host))</code></p>
        <div class="row">\(buttons)</div>
        <small>\(escape(error.localizedDescription)) (\(error.domain) \(error.code))</small>
        </main></body></html>
        """
    }

    private static func describe(_ e: NSError) -> (String, String, String) {
        switch e.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed:
            return ("You’re offline", "Searchy can’t reach the internet. Check your connection and try again.", "📡")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return ("Can’t find that site", "The server’s address couldn’t be found. Check the spelling, or your connection.", "🔎")
        case NSURLErrorTimedOut:
            return ("The site took too long", "The server didn’t respond in time.", "⏳")
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
            return ("Couldn’t connect", "The server refused or dropped the connection.", "🔌")
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorSecureConnectionFailed, NSURLErrorClientCertificateRejected:
            return ("This connection isn’t private", "The site’s security certificate can’t be verified, so Searchy stopped loading it.", "🔒")
        default:
            return ("This page can’t be opened", "Something went wrong while loading it.", "⚠️")
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
