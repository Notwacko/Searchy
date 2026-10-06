import Foundation

nonisolated struct ContentHit: Identifiable, Sendable {
    let id: Int64
    let url: String
    let title: String
    let snippet: String
    var host: String { URL(string: url)?.host?.strippingWWW ?? "" }
}

/// A private, on-device full-text index of pages you've read (SQLite FTS5), so you can search by what a page *said*.
/// Pages with login forms and private tabs are never indexed. Nothing leaves the Mac.
nonisolated final class ContentIndex: @unchecked Sendable {
    static let shared = ContentIndex()

    private let queue = DispatchQueue(label: "app.searchy.index", qos: .utility)
    private var db: SQLiteDatabase?
    private let maxPages = 6000

    private init() {}

    func add(url: URL, title: String, text: String) {
        guard let key = HistoryStore.normalize(url) else { return }
        queue.async { [self] in
            guard let db = database() else { return }
            try? db.transaction {
                try db.execute("DELETE FROM pages_fts WHERE url = ?", [.text(key)])
                try db.execute("INSERT INTO pages_fts(title, body, url) VALUES(?,?,?)", [.text(title), .text(text), .text(key)])
                var count = 0
                try db.query("SELECT COUNT(*) FROM pages_fts") { count = Int($0.int(0)) }
                if count > maxPages {   // drop the oldest rows
                    try db.execute("DELETE FROM pages_fts WHERE rowid IN (SELECT rowid FROM pages_fts ORDER BY rowid LIMIT ?)", [.int(Int64(count - maxPages))])
                }
            }
        }
    }

    func search(_ query: String, limit: Int = 5) async -> [ContentHit] {
        guard let match = Self.matchExpression(query) else { return [] }
        return await withCheckedContinuation { cont in
            queue.async { [self] in
                var out: [ContentHit] = []
                try? database()?.query("""
                    SELECT rowid, url, title, snippet(pages_fts, 1, '', '', '…', 14) FROM pages_fts
                    WHERE pages_fts MATCH ? ORDER BY rank LIMIT ?
                    """, [.text(match), .int(Int64(limit))]) { r in
                    out.append(ContentHit(id: r.int(0), url: r.text(1), title: r.text(2), snippet: r.text(3)))
                }
                cont.resume(returning: out)
            }
        }
    }

    func count() async -> Int {
        await withCheckedContinuation { cont in
            queue.async { [self] in
                var n = 0
                try? database()?.query("SELECT COUNT(*) FROM pages_fts") { n = Int($0.int(0)) }
                cont.resume(returning: n)
            }
        }
    }

    func clear() {
        queue.async { [self] in try? database()?.execute("DELETE FROM pages_fts") }
    }

    func remove(url: URL) {
        guard let key = HistoryStore.normalize(url) else { return }
        queue.async { [self] in try? database()?.execute("DELETE FROM pages_fts WHERE url = ?", [.text(key)]) }
    }

    /// "sourdough starter" → `"sourdough"* "starter"*` (every word, as a prefix), with FTS syntax characters removed.
    static func matchExpression(_ text: String) -> String? {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    private func database() -> SQLiteDatabase? {
        if let db { return db }
        guard let opened = try? SQLiteDatabase(path: Paths.file("Index.sqlite").path) else { return nil }
        try? opened.execute("PRAGMA journal_mode = WAL")
        try? opened.execute("PRAGMA synchronous = NORMAL")
        try? opened.execute("CREATE VIRTUAL TABLE IF NOT EXISTS pages_fts USING fts5(title, body, url UNINDEXED, tokenize = 'porter unicode61')")
        db = opened
        return opened
    }
}
