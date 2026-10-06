import Foundation

/// Turns whatever was typed in the command bar into something loadable.
nonisolated enum Omnibox {
    enum Kind: Equatable { case url(URL), search(String) }

    static func classify(_ raw: String) -> Kind {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .search("") }

        // Explicit scheme.
        if let range = text.range(of: "://"), !text[..<range.lowerBound].contains(where: { $0 == " " || $0 == "." }) {
            let scheme = text[..<range.lowerBound].lowercased()
            if ["http", "https", "file", "ftp"].contains(scheme), let url = URL(string: text) { return .url(url) }
        }
        for s in ["about:", "data:", "view-source:"] where text.lowercased().hasPrefix(s) {
            if let url = URL(string: text) { return .url(url) }
        }
        if text.hasPrefix("/") || text.hasPrefix("~/") {
            let path = (text as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) { return .url(URL(fileURLWithPath: path)) }
        }
        if text.contains(" ") { return .search(text) }

        // host[:port][/path]
        let (hostPart, rest) = split(text)
        let (host, hasPort) = stripPort(hostPart)
        guard isHost(host, hasPort: hasPort) else { return .search(text) }
        let secure = !(isLocal(host) || hasPort)
        let scheme = secure ? "https" : "http"
        if let url = URL(string: "\(scheme)://\(hostPart)\(rest)") { return .url(url) }
        return .search(text)
    }

    static func resolve(_ raw: String, engine: SearchEngine) -> URL {
        switch classify(raw) {
        case .url(let url): return url
        case .search(let q): return engine.searchURL(for: q)
        }
    }

    // MARK: - helpers

    private static func split(_ s: String) -> (String, String) {
        guard let i = s.firstIndex(where: { "/?#".contains($0) }) else { return (s, "") }
        return (String(s[..<i]), String(s[i...]))
    }

    private static func stripPort(_ s: String) -> (String, Bool) {
        if s.hasPrefix("[") { return (s, false) }  // IPv6 literal
        guard let colon = s.lastIndex(of: ":") else { return (s, false) }
        let port = s[s.index(after: colon)...]
        guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return (s, false) }
        return (String(s[..<colon]), true)
    }

    private static func isLocal(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".test") || h.hasSuffix(".internal")
            || h.hasSuffix(".localhost") || isIPv4(h) || h.hasPrefix("[")
    }

    private static func isIPv4(_ h: String) -> Bool {
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    private static func isHost(_ host: String, hasPort: Bool) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || isIPv4(h) || (h.hasPrefix("[") && h.hasSuffix("]")) { return true }
        if hasPort && !h.isEmpty && !h.contains(".") { return true }   // e.g. myserver:8080
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for l in labels {
            guard !l.isEmpty, l.count <= 63, !l.hasPrefix("-"), !l.hasSuffix("-"),
                  l.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return false }
        }
        let tld = String(labels.last!)
        if tld.hasPrefix("xn--") { return true }
        guard tld.allSatisfy({ $0.isLetter && $0.isASCII }) else { return false }
        if tld.count == 2 { return !fileLikeExtensions.contains(tld) }
        return knownTLDs.contains(tld)
    }

    private static let fileLikeExtensions: Set<String> = ["js", "py", "rb", "md", "sh", "ts", "rs", "cs", "ps", "gz", "pl", "h", "mm"]

    private static let knownTLDs: Set<String> = Set([
        "com", "org", "net", "edu", "gov", "mil", "int", "info", "biz", "name", "pro", "mobi", "asia", "tel", "travel", "jobs",
        "io", "dev", "app", "ai", "cloud", "tech", "online", "site", "store", "shop", "blog", "news", "xyz", "club", "live",
        "life", "world", "today", "space", "agency", "studio", "design", "art", "wiki", "page", "link", "email", "one", "zone",
        "run", "network", "systems", "software", "digital", "media", "social", "video", "games", "game", "fun", "top", "vip",
        "website", "web", "company", "center", "team", "tools", "works", "group", "global", "city", "academy", "education",
        "school", "science", "money", "finance", "bank", "capital", "fund", "health", "care", "life", "photo", "photos",
        "music", "movie", "tv", "radio", "press", "report", "review", "reviews", "rocks", "ninja", "guru", "expert", "codes",
        "build", "cafe", "coffee", "food", "kitchen", "recipes", "garden", "house", "homes", "land", "farm", "eco", "green",
        "earth", "energy", "solar", "legal", "law", "lawyer", "consulting", "marketing", "partners", "ventures", "holdings",
        "foundation", "community", "support", "help", "chat", "forum", "plus", "land", "lol", "wtf", "dog", "cat", "pet",
        "xxx", "porn", "sex", "adult", "bet", "casino", "poker", "ltd", "inc", "llc", "gmbh", "foo", "bar", "new", "now",
        "icu", "cyou", "sbs", "bond", "buzz", "monster", "quest", "rest", "beauty", "makeup", "hair", "skin", "yoga", "fit",
        "fitness", "sport", "sports", "golf", "bike", "car", "cars", "auto", "taxi", "flights", "hotel", "hotels", "tours",
        "vacations", "cruise", "airforce", "army", "navy", "church", "bible", "faith", "wedding", "gift", "gifts", "toys",
        "fashion", "style", "boutique", "clothing", "shoes", "jewelry", "watch", "diamonds", "luxury", "luxe", "estate",
    ])
}
