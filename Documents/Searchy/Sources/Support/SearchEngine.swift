import Foundation

nonisolated struct SearchEngine: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// `%s` is replaced with the percent-encoded query.
    let template: String
    /// OpenSearch-style suggestion endpoint (returns `[query, [suggestions…]]`).
    let suggest: String?

    func searchURL(for query: String) -> URL {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: q)) ?? URL(string: "about:blank")!
    }

    func suggestionURL(for query: String) -> URL? {
        guard let suggest else { return nil }
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? query
        return URL(string: suggest.replacingOccurrences(of: "%s", with: q))
    }

    static let all: [SearchEngine] = [
        .init(id: "google", name: "Google", template: "https://www.google.com/search?q=%s",
              suggest: "https://suggestqueries.google.com/complete/search?client=firefox&q=%s"),
        .init(id: "duckduckgo", name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s",
              suggest: "https://duckduckgo.com/ac/?type=list&q=%s"),
        .init(id: "brave", name: "Brave Search", template: "https://search.brave.com/search?q=%s",
              suggest: "https://search.brave.com/api/suggest?q=%s"),
        .init(id: "bing", name: "Bing", template: "https://www.bing.com/search?q=%s",
              suggest: "https://api.bing.com/osjson.aspx?query=%s"),
        .init(id: "kagi", name: "Kagi", template: "https://kagi.com/search?q=%s", suggest: nil),
        .init(id: "ecosia", name: "Ecosia", template: "https://www.ecosia.org/search?q=%s", suggest: nil),
        .init(id: "startpage", name: "Startpage", template: "https://www.startpage.com/do/search?q=%s", suggest: nil),
    ]

    static func named(_ id: String) -> SearchEngine { all.first { $0.id == id } ?? all[0] }
}

extension CharacterSet {
    nonisolated static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=#?/:;@$,")
        return set
    }()
}
