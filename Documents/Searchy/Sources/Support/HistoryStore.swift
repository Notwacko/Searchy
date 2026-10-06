import Foundation

nonisolated struct HistoryEntry: Identifiable, Hashable, Sendable {
    let id: Int64
    let url: String
    let title: String
    let visitCount: Int
    let lastVisit: Date

    var host: String { URL(string: url)?.host?.strippingWWW ?? "" }
}

nonisolated struct ImportedHistoryItem: Sendable {
    var url: String
    var title: String
    var visitCount: Int
    var lastVisit: Date
}

/// Browsing history in SQLite. All database work happens on one background queue,
/// so recording a visit never costs the UI a frame.
nonisolated final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore()

    private let queue = DispatchQueue(label: "app.searchy.history", qos: .utility)
    private var db: SQLiteDatabase?

    private init() {}

    // MARK: Writing

    func record(url: URL, title: String) {
        guard let key = Self.normalize(url) else { return }
        let host = url.host ?? ""
        let now = Date().timeIntervalSince1970
        queue.async { [self] in
            try? database()?.execute("""
                INSERT INTO pages(url, title, host, visit_count, last_visit) VALUES(?,?,?,1,?)
                ON CONFLICT(url) DO UPDATE SET visit_count = visit_count + 1, last_visit = excluded.last_visit,
                    title = CASE WHEN excluded.title != '' THEN excluded.title ELSE title END
                """, [.text(key), .text(title), .text(host), .double(now)])
        }
    }

    func updateTitle(url: URL, title: String) {
        guard let key = Self.normalize(url), !title.isEmpty else { return }
        queue.async { [self] in
            try? database()?.execute("UPDATE pages SET title = ? WHERE url = ?", [.text(title), .text(key)])
        }
    }

    func delete(url: String) {
        queue.async { [self] in try? database()?.execute("DELETE FROM pages WHERE url = ?", [.text(url)]) }
    }

    func clear(since: Date? = nil) {
        queue.async { [self] in
            if let since {
                try? database()?.execute("DELETE FROM pages WHERE last_visit >= ?", [.double(since.timeIntervalSince1970)])
            } else {
                try? database()?.execute("DELETE FROM pages")
            }
        }
    }

    @discardableResult
    func add(_ items: [ImportedHistoryItem]) async -> Int {
        await withCheckedContinuation { cont in
            queue.async { [self] in
                guard let db = database() else { cont.resume(returning: 0); return }
                var count = 0
                try? db.transaction {
                    for item in items {
                        guard let url = URL(string: item.url), let key = Self.normalize(url) else { continue }
                        try? db.execute("""
                            INSERT INTO pages(url, title, host, visit_count, last_visit) VALUES(?,?,?,?,?)
                            ON CONFLICT(url) DO UPDATE SET visit_count = MAX(visit_count, excluded.visit_count),
                                last_visit = MAX(last_visit, excluded.last_visit),
                                title = CASE WHEN title = '' THEN excluded.title ELSE title END
                            """, [.text(key), .text(item.title), .text(url.host ?? ""), .int(Int64(item.visitCount)),
                                  .double(item.lastVisit.timeIntervalSince1970)])
                        count += 1
                    }
                }
                cont.resume(returning: count)
            }
        }
    }

    // MARK: Reading

    /// Ranks by how often and how recently a page was visited, matching URL or title.
    func search(_ text: String, limit: Int = 8) async -> [HistoryEntry] {
        let terms = text.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        let clauses = terms.map { _ in "(url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\')" }.joined(separator: " AND ")
        var params: [SQLValue] = []
        for t in terms {
            let like = "%" + t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%"
            params += [.text(like), .text(like)]
        }
        params.append(.int(Int64(limit)))
        return await rows("""
            SELECT id, url, title, visit_count, last_visit FROM pages WHERE \(clauses)
            ORDER BY (visit_count * 1.0) / (1.0 + (strftime('%s','now') - last_visit) / 604800.0) DESC LIMIT ?
            """, params)
    }

    func recent(limit: Int = 200, offset: Int = 0) async -> [HistoryEntry] {
        await rows("SELECT id, url, title, visit_count, last_visit FROM pages ORDER BY last_visit DESC LIMIT ? OFFSET ?",
                   [.int(Int64(limit)), .int(Int64(offset))])
    }

    func topSites(limit: Int = 8) async -> [HistoryEntry] {
        // One entry per host: the most visited page on it.
        await rows("""
            SELECT id, url, title, SUM(visit_count) AS vc, MAX(last_visit) FROM pages
            WHERE host != '' GROUP BY host ORDER BY vc DESC, MAX(last_visit) DESC LIMIT ?
            """, [.int(Int64(limit))])
    }

    func count() async -> Int {
        await withCheckedContinuation { cont in
            queue.async { [self] in
                var n = 0
                try? database()?.query("SELECT COUNT(*) FROM pages") { n = Int($0.int(0)) }
                cont.resume(returning: n)
            }
        }
    }

    // MARK: Internals

    private func rows(_ sql: String, _ params: [SQLValue]) async -> [HistoryEntry] {
        await withCheckedContinuation { cont in
            queue.async { [self] in
                var out: [HistoryEntry] = []
                try? database()?.query(sql, params) { r in
                    out.append(HistoryEntry(id: r.int(0), url: r.text(1), title: r.text(2),
                                            visitCount: Int(r.int(3)), lastVisit: Date(timeIntervalSince1970: r.double(4))))
                }
                cont.resume(returning: out)
            }
        }
    }

    private func database() -> SQLiteDatabase? {
        if let db { return db }
        guard let opened = try? SQLiteDatabase(path: Paths.file("History.sqlite").path) else { return nil }
        try? opened.execute("PRAGMA journal_mode = WAL")
        try? opened.execute("PRAGMA synchronous = NORMAL")
        try? opened.execute("""
            CREATE TABLE IF NOT EXISTS pages(
                id INTEGER PRIMARY KEY, url TEXT NOT NULL UNIQUE, title TEXT NOT NULL DEFAULT '',
                host TEXT NOT NULL DEFAULT '', visit_count INTEGER NOT NULL DEFAULT 1, last_visit REAL NOT NULL)
            """)
        try? opened.execute("CREATE INDEX IF NOT EXISTS pages_last_visit ON pages(last_visit)")
        try? opened.execute("CREATE INDEX IF NOT EXISTS pages_host ON pages(host)")
        db = opened
        return opened
    }

    /// History keys drop the fragment and only cover web pages.
    static func normalize(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        return c?.string
    }
}

extension String {
    nonisolated var strippingWWW: String { hasPrefix("www.") ? String(dropFirst(4)) : self }
}
