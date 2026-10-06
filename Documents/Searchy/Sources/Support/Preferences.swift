import Foundation
import Observation

enum TabLayout: String, CaseIterable, Identifiable {
    case sidebar, top
    var id: String { rawValue }
    var title: String { self == .sidebar ? "Sidebar" : "Top strip" }
}

enum ReaderTheme: String, CaseIterable, Identifiable {
    case auto, light, sepia, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum ReaderFont: String, CaseIterable, Identifiable {
    case serif, sans
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// User preferences, backed by UserDefaults. Observable so views update live.
@Observable
final class Preferences {
    static let shared = Preferences()

    var searchEngineID: String { didSet { set(searchEngineID, "searchEngine") } }
    var tabLayout: TabLayout { didSet { set(tabLayout.rawValue, "tabLayout") } }
    var sidebarWidth: Double { didSet { set(sidebarWidth, "sidebarWidth") } }
    var sleepAfterMinutes: Int { didSet { set(sleepAfterMinutes, "sleepAfterMinutes") } }
    var blockAds: Bool { didSet { set(blockAds, "blockAds") } }
    var autoFloatVideo: Bool { didSet { set(autoFloatVideo, "autoFloatVideo") } }
    var offerToSavePasswords: Bool { didSet { set(offerToSavePasswords, "offerToSavePasswords") } }
    var offerToFillPasswords: Bool { didSet { set(offerToFillPasswords, "offerToFillPasswords") } }
    var touchIDToFill: Bool { didSet { set(touchIDToFill, "touchIDToFill") } }
    var searchSuggestions: Bool { didSet { set(searchSuggestions, "searchSuggestions") } }
    var restoreSession: Bool { didSet { set(restoreSession, "restoreSession") } }
    /// 0 = automatic (a share of installed RAM).
    var memoryBudgetMB: Int { didSet { set(memoryBudgetMB, "memoryBudgetMB") } }
    var stopAutoplay: Bool { didSet { set(stopAutoplay, "stopAutoplay") } }
    /// Keep a private full-text index of pages read, for searching by content.
    var indexPages: Bool { didSet { set(indexPages, "indexPages") } }
    var readerTheme: ReaderTheme { didSet { set(readerTheme.rawValue, "readerTheme") } }
    var readerFont: ReaderFont { didSet { set(readerFont.rawValue, "readerFont") } }
    var readerSize: Double { didSet { set(readerSize, "readerSize") } }

    var searchEngine: SearchEngine { SearchEngine.named(searchEngineID) }

    private init() {
        let d = UserDefaults.standard
        searchEngineID = d.string(forKey: "searchEngine") ?? "google"
        tabLayout = TabLayout(rawValue: d.string(forKey: "tabLayout") ?? "") ?? .top
        sidebarWidth = d.object(forKey: "sidebarWidth") as? Double ?? 264
        sleepAfterMinutes = d.object(forKey: "sleepAfterMinutes") as? Int ?? 10
        blockAds = d.object(forKey: "blockAds") as? Bool ?? true
        autoFloatVideo = d.object(forKey: "autoFloatVideo") as? Bool ?? true
        offerToSavePasswords = d.object(forKey: "offerToSavePasswords") as? Bool ?? true
        offerToFillPasswords = d.object(forKey: "offerToFillPasswords") as? Bool ?? true
        touchIDToFill = d.object(forKey: "touchIDToFill") as? Bool ?? false
        searchSuggestions = d.object(forKey: "searchSuggestions") as? Bool ?? true
        restoreSession = d.object(forKey: "restoreSession") as? Bool ?? true
        memoryBudgetMB = d.object(forKey: "memoryBudgetMB") as? Int ?? 0
        stopAutoplay = d.object(forKey: "stopAutoplay") as? Bool ?? true
        indexPages = d.object(forKey: "indexPages") as? Bool ?? true
        readerTheme = ReaderTheme(rawValue: d.string(forKey: "readerTheme") ?? "") ?? .auto
        readerFont = ReaderFont(rawValue: d.string(forKey: "readerFont") ?? "") ?? .serif
        readerSize = d.object(forKey: "readerSize") as? Double ?? 19
    }

    private func set(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }
}
