import Foundation
import Observation

enum SpaceColor: String, Codable, CaseIterable, Sendable {
    case blue, purple, pink, red, orange, yellow, green, teal, graphite
}

/// A space is a separate set of tabs. "Isolated" spaces keep their own cookies (start afresh);
/// otherwise they share the default sign-ins.
nonisolated struct SpaceInfo: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var symbol: String
    var color: SpaceColor
    var isolated: Bool = false

    static let symbols = ["house.fill", "briefcase.fill", "book.fill", "graduationcap.fill", "gamecontroller.fill", "cart.fill",
                          "music.note", "film.fill", "paintbrush.fill", "hammer.fill", "leaf.fill", "airplane",
                          "heart.fill", "star.fill", "bolt.fill", "flame.fill", "moon.fill", "sun.max.fill",
                          "camera.fill", "globe.americas.fill", "flask.fill", "chart.line.uptrend.xyaxis", "bag.fill", "person.2.fill"]
}

@MainActor @Observable
final class SpaceModel: Identifiable {
    var info: SpaceInfo
    var pinned: [Tab] = []
    var tabs: [Tab] = []
    var selectedID: UUID?
    /// Most recently used tab ids, newest first. Decides what to show after a close.
    @ObservationIgnored var recent: [UUID] = []

    var id: UUID { info.id }

    init(_ info: SpaceInfo) { self.info = info }

    var allTabs: [Tab] { pinned + tabs }

    func tab(_ id: UUID?) -> Tab? {
        guard let id else { return nil }
        return pinned.first { $0.id == id } ?? tabs.first { $0.id == id }
    }

    func noteUsed(_ id: UUID) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 40 { recent.removeLast() }
    }
}
