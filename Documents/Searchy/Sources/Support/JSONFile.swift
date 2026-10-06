import Foundation

/// A Codable value persisted as JSON. Saves are coalesced and written off the main thread.
@MainActor
final class JSONFile<Value: Codable & Sendable> {
    private let url: URL
    private var pending: Task<Void, Never>?

    init(_ name: String) { url = Paths.file(name) }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value, after delay: Duration = .milliseconds(800)) {
        pending?.cancel()
        let url = url
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(value) else { return }
                try? data.write(to: url, options: .atomic)
            }.value
        }
    }

    /// Writes immediately (used on quit).
    func saveNow(_ value: Value) {
        pending?.cancel()
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) }
    }
}
