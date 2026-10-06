import Foundation

/// "yt cats", "gh swiftui", "!w apple" — jump straight into a site's own search.
nonisolated struct QuickSearch: Sendable {
    let keys: [String]
    let name: String
    let template: String

    func url(for query: String) -> URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: q))
    }

    static let all: [QuickSearch] = [
        .init(keys: ["yt", "youtube"], name: "YouTube", template: "https://www.youtube.com/results?search_query=%s"),
        .init(keys: ["gh", "github"], name: "GitHub", template: "https://github.com/search?q=%s"),
        .init(keys: ["w", "wiki"], name: "Wikipedia", template: "https://en.wikipedia.org/w/index.php?search=%s"),
        .init(keys: ["maps", "map"], name: "Apple Maps", template: "https://maps.apple.com/?q=%s"),
        .init(keys: ["a", "amz", "amazon"], name: "Amazon", template: "https://www.amazon.com/s?k=%s"),
        .init(keys: ["r", "reddit"], name: "Reddit", template: "https://www.reddit.com/search/?q=%s"),
        .init(keys: ["so"], name: "Stack Overflow", template: "https://stackoverflow.com/search?q=%s"),
        .init(keys: ["mdn"], name: "MDN", template: "https://developer.mozilla.org/en-US/search?q=%s"),
        .init(keys: ["npm"], name: "npm", template: "https://www.npmjs.com/search?q=%s"),
        .init(keys: ["x", "tw"], name: "X", template: "https://x.com/search?q=%s"),
        .init(keys: ["imdb"], name: "IMDb", template: "https://www.imdb.com/find/?q=%s"),
        .init(keys: ["hn"], name: "Hacker News", template: "https://hn.algolia.com/?q=%s"),
        .init(keys: ["img", "images"], name: "Google Images", template: "https://www.google.com/search?tbm=isch&q=%s"),
        .init(keys: ["tr", "translate"], name: "Google Translate", template: "https://translate.google.com/?sl=auto&text=%s"),
        .init(keys: ["g", "google"], name: "Google", template: "https://www.google.com/search?q=%s"),
        .init(keys: ["ddg"], name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s"),
        .init(keys: ["bing"], name: "Bing", template: "https://www.bing.com/search?q=%s"),
        .init(keys: ["wa", "wolfram"], name: "Wolfram Alpha", template: "https://www.wolframalpha.com/input?i=%s"),
    ]

    /// Splits "yt cats" into (YouTube, "cats"). A leading "!" is accepted too.
    static func match(_ text: String) -> (QuickSearch, String)? {
        var t = text
        if t.hasPrefix("!") { t.removeFirst() }
        guard let space = t.firstIndex(of: " ") else { return nil }
        let key = t[..<space].lowercased()
        let rest = t[t.index(after: space)...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, let hit = all.first(where: { $0.keys.contains(key) }) else { return nil }
        return (hit, rest)
    }
}

/// Live search suggestions from the chosen engine.
nonisolated enum Suggestions {
    static func fetch(_ query: String, engine: SearchEngine) async -> [String] {
        guard let url = engine.suggestionURL(for: query) else { return [] }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 2.5)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any], json.count > 1,
              let list = json[1] as? [String] else { return [] }
        return Array(list.prefix(6))
    }
}
