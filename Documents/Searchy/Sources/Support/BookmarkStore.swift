import Foundation
import Observation

nonisolated struct Bookmark: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var url: String
    /// Slash-separated folder path ("" = top level).
    var folder: String = ""
    var isFavorite = false
    var addedAt = Date()
}

@MainActor @Observable
final class BookmarkStore {
    static let shared = BookmarkStore()

    private(set) var items: [Bookmark] = []
    @ObservationIgnored private let file = JSONFile<[Bookmark]>("Bookmarks.json")

    private init() { items = file.load() ?? [] }

    var favorites: [Bookmark] { items.filter(\.isFavorite) }
    var folders: [String] { Array(Set(items.map(\.folder).filter { !$0.isEmpty })).sorted() }

    func bookmark(for url: URL?) -> Bookmark? {
        guard let key = url.flatMap(Self.key) else { return nil }
        return items.first { Self.key(string: $0.url) == key }
    }

    func isBookmarked(_ url: URL?) -> Bool { bookmark(for: url) != nil }

    func toggle(url: URL, title: String) {
        if let existing = bookmark(for: url) { remove(existing.id) }
        else { add(title: title, url: url.absoluteString) }
    }

    func add(title: String, url: String, folder: String = "", favorite: Bool = false) {
        items.insert(Bookmark(title: title.isEmpty ? url : title, url: url, folder: folder, isFavorite: favorite), at: 0)
        persist()
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id }; persist() }

    func setFavorite(_ id: UUID, _ value: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].isFavorite = value
        persist()
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = title
        persist()
    }

    /// Adds imported bookmarks, skipping ones that already exist. Returns how many were new.
    @discardableResult
    func merge(_ incoming: [Bookmark]) -> Int {
        var known = Set(items.compactMap { Self.key(string: $0.url) })
        var added = 0
        for b in incoming {
            guard let k = Self.key(string: b.url), known.insert(k).inserted else { continue }
            items.append(b)
            added += 1
        }
        if added > 0 { persist() }
        return added
    }

    func search(_ text: String, limit: Int = 5) -> [Bookmark] {
        let terms = text.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        return items.filter { b in
            let hay = (b.title + " " + b.url).lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }.prefix(limit).map { $0 }
    }

    private func persist() { file.save(items) }

    private static func key(_ url: URL) -> String? { key(string: url.absoluteString) }
    private static func key(string: String) -> String? {
        var s = string
        if let h = s.firstIndex(of: "#") { s = String(s[..<h]) }
        while s.hasSuffix("/") { s.removeLast() }
        return s.lowercased()
    }
}
