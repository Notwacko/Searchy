import Foundation

nonisolated struct TabSnapshot: Codable, Sendable {
    var id: UUID
    var url: String?
    var title: String
    var home: String?
    /// WebKit's opaque back/forward + scroll state, so a restored tab picks up exactly where it was.
    var state: Data?
    var route: UUID? = nil
}

nonisolated struct SpaceSnapshot: Codable, Sendable {
    var info: SpaceInfo
    var pinned: [TabSnapshot]
    var tabs: [TabSnapshot]
    var selected: UUID?
}

nonisolated struct SessionSnapshot: Codable, Sendable {
    var spaces: [SpaceSnapshot]
    var active: UUID
}

nonisolated struct ClosedTab: Sendable {
    var url: URL?
    var title: String
    var state: Data?
    var spaceID: UUID
}
