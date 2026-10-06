import AppKit
import SwiftUI
import WebKit
import Observation

struct Toast: Identifiable {
    let id = UUID()
    var text: String
    var symbol: String
    var actionTitle: String?
    var action: (() -> Void)?
}

struct PaletteState {
    var isOpen = false
    /// Return opens in a new tab instead of the current one.
    var opensNewTab = false
    var prefill = ""
    /// A blank tab created just for this palette; closed again if the palette is dismissed untouched.
    var ephemeralTabID: UUID?
}

extension FocusedValues {
    @Entry var browser: BrowserModel?
}

/// Everything one browser window knows: its spaces and tabs, what's selected, and transient UI state.
@MainActor @Observable
final class BrowserModel {
    var spaces: [SpaceModel] = []
    var activeSpaceID: UUID
    /// Direction of the last space change, so the sidebar can slide the right way.
    var switchedForward = true

    var sidebarVisible = true
    var sidebarPeeking = false
    var palette = PaletteState()
    var findVisible = false
    var findFocusToken = 0
    var toasts: [Toast] = []
    var downloadsPopoverShown = false
    var spaceEditor: SpaceEditorRequest?
    var sheet: BrowserSheet?
    /// The network banner is dismissed per condition; it returns if the condition changes.
    var bannerDismissed: NetworkMonitor.Quality?

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var privateStore: WKWebsiteDataStore?
    @ObservationIgnored var recentlyClosed: [ClosedTab] = []
    @ObservationIgnored private var sleepTimer: Timer?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let sessionFile = JSONFile<SessionSnapshot>("Session.json")
    @ObservationIgnored private var closeObserver: NSObjectProtocol?

    // MARK: Creation

    init(restore: Bool) {
        var built: [SpaceModel] = []
        var active: UUID?
        if restore, Preferences.shared.restoreSession, let snap = sessionFile.load(), !snap.spaces.isEmpty {
            built = snap.spaces.map { Self.space(from: $0) }
            active = snap.active
        }
        if built.isEmpty {
            let home = SpaceModel(SpaceInfo(name: "Home", symbol: "house.fill", color: .blue))
            built = [home]
        }
        spaces = built
        activeSpaceID = built.contains { $0.id == active } ? active! : built[0].id
        for tab in spaces.flatMap(\.allTabs) { tab.model = self }
        if activeSpace.allTabs.isEmpty { newTab(select: true) }
        else if activeSpace.selectedID == nil || activeSpace.tab(activeSpace.selectedID) == nil {
            activeSpace.selectedID = (activeSpace.tabs.first ?? activeSpace.pinned.first)?.id
        }
        selectedTab?.activate()
        BrowserRegistry.shared.register(self)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleepIdleTabs() }
        }
    }

    private static func space(from snap: SpaceSnapshot) -> SpaceModel {
        let space = SpaceModel(snap.info)
        func make(_ s: TabSnapshot, pinned: Bool) -> Tab {
            let tab = Tab(id: s.id, spaceID: snap.info.id, url: s.url.flatMap(URL.init(string:)), title: s.title)
            tab.savedState = s.state
            tab.isPinned = pinned
            tab.pinnedHome = s.home.flatMap(URL.init(string:))
            tab.routeID = s.route
            return tab
        }
        space.pinned = snap.pinned.map { make($0, pinned: true) }
        space.tabs = snap.tabs.map { make($0, pinned: false) }
        space.selectedID = snap.selected
        if let s = snap.selected { space.recent = [s] }
        return space
    }

    // MARK: Accessors

    var activeSpace: SpaceModel { spaces.first { $0.id == activeSpaceID } ?? spaces[0] }
    var selectedTab: Tab? { activeSpace.tab(activeSpace.selectedID) }
    var allTabs: [Tab] { spaces.flatMap(\.allTabs) }
    func space(of tab: Tab) -> SpaceModel? { spaces.first { $0.id == tab.spaceID } }
    private func index(of space: SpaceModel) -> Int { spaces.firstIndex { $0 === space } ?? 0 }

    func dataStore(for tab: Tab) -> WKWebsiteDataStore {
        if tab.isPrivate {
            if privateStore == nil { privateStore = .nonPersistent() }
            return privateStore!
        }
        let info = space(of: tab)?.info ?? spaces[0].info
        return WebEngine.shared.dataStore(for: info, privateStore: nil, route: tab.route)
    }

    // MARK: Tabs

    @discardableResult
    func newTab(url: URL? = nil, select: Bool = true, isPrivate: Bool = false, in space: SpaceModel? = nil,
                after anchor: Tab? = nil) -> Tab {
        let space = space ?? activeSpace
        let tab = Tab(spaceID: space.id, url: url, isPrivate: isPrivate)
        tab.model = self
        let anchor = anchor ?? space.tab(space.selectedID)
        if let anchor, !anchor.isPinned, let i = space.tabs.firstIndex(where: { $0 === anchor }) {
            space.tabs.insert(tab, at: i + 1)
        } else if anchor?.isPinned == true {
            space.tabs.insert(tab, at: 0)
        } else {
            space.tabs.append(tab)
        }
        if select { self.select(tab) }
        sessionDirty()
        return tab
    }

    /// ⌘T: a fresh blank tab with the command bar open.
    func newTabWithPalette() {
        let tab = newTab()
        openPalette(prefill: "", newTab: false, ephemeral: tab)
    }

    func newPrivateTab() {
        let tab = newTab(isPrivate: true)
        openPalette(prefill: "", newTab: false, ephemeral: tab)
    }

    func select(_ tab: Tab) {
        guard let space = space(of: tab) else { return }
        let previous = selectedTab
        if previous !== tab { previous?.deactivate() }
        if space.id != activeSpaceID {
            switchedForward = index(of: space) > index(of: activeSpace)
            activeSpaceID = space.id
        }
        space.selectedID = tab.id
        space.noteUsed(tab.id)
        tab.activate()
        findVisible = false
        sessionDirty()
    }

    func close(_ tab: Tab, remember: Bool = true) {
        guard let space = space(of: tab) else { return }
        let wasSelected = space.selectedID == tab.id
        if tab.isPinned {
            // A pinned tab never leaves: closing just puts it to sleep.
            tab.sleep(force: true)
            if wasSelected && space.id == activeSpaceID { selectAfterClosing(tab, in: space, near: nil) }
            sessionDirty()
            return
        }
        if remember, !tab.isPrivate, tab.url != nil {
            recentlyClosed.append(ClosedTab(url: tab.url, title: tab.title, state: tab.snapshot().state, spaceID: space.id))
            if recentlyClosed.count > 25 { recentlyClosed.removeFirst() }
        }
        let position = space.tabs.firstIndex { $0 === tab }
        space.tabs.removeAll { $0 === tab }
        space.recent.removeAll { $0 == tab.id }
        tab.sleep(force: true)
        tab.model = nil
        if wasSelected {
            space.selectedID = nil
            if space.id == activeSpaceID { selectAfterClosing(tab, in: space, near: position) }
        }
        if tab.isPrivate && !allTabs.contains(where: \.isPrivate) { privateStore = nil }
        sessionDirty()
    }

    func closeSelectedTab() {
        if let tab = selectedTab { close(tab) } else { window?.performClose(nil) }
    }

    private func selectAfterClosing(_ closed: Tab, in space: SpaceModel, near position: Int?) {
        let candidates = space.recent.compactMap { id in space.tab(id) }.filter { $0 !== closed }
        if let next = candidates.first { select(next); return }
        let tabs = space.tabs
        if let position, !tabs.isEmpty { select(tabs[min(position, tabs.count - 1)]); return }
        if let next = tabs.first ?? space.pinned.first(where: { $0 !== closed }) { select(next); return }
        newTab()
    }

    func reopenClosedTab() {
        guard let closed = recentlyClosed.popLast() else { return }
        let space = spaces.first { $0.id == closed.spaceID } ?? activeSpace
        let tab = newTab(url: closed.url, select: false, in: space)
        tab.title = closed.title
        tab.savedState = closed.state
        select(tab)
    }

    func togglePin(_ tab: Tab) {
        guard let space = space(of: tab), !tab.isPrivate else { return }
        withAnimation(.snappy(duration: 0.3)) {
            if tab.isPinned {
                space.pinned.removeAll { $0 === tab }
                tab.isPinned = false
                tab.pinnedHome = nil
                space.tabs.insert(tab, at: 0)
            } else {
                space.tabs.removeAll { $0 === tab }
                tab.isPinned = true
                tab.pinnedHome = tab.url
                space.pinned.append(tab)
            }
        }
        sessionDirty()
    }

    /// Drag-and-drop reordering within a space. `target == nil` appends.
    func move(_ id: UUID, before target: UUID?, pinned: Bool) {
        let space = activeSpace
        guard let tab = space.tab(id), id != target else { return }
        if tab.isPrivate && pinned { return }
        withAnimation(.snappy(duration: 0.3)) {
            space.pinned.removeAll { $0 === tab }
            space.tabs.removeAll { $0 === tab }
            tab.isPinned = pinned
            if pinned && tab.pinnedHome == nil { tab.pinnedHome = tab.url }
            if !pinned { tab.pinnedHome = nil }
            if pinned {
                if let target, let i = space.pinned.firstIndex(where: { $0.id == target }) { space.pinned.insert(tab, at: i) }
                else { space.pinned.append(tab) }
            } else {
                if let target, let i = space.tabs.firstIndex(where: { $0.id == target }) { space.tabs.insert(tab, at: i) }
                else { space.tabs.append(tab) }
            }
        }
        sessionDirty()
    }

    func move(_ tab: Tab, toSpace dest: SpaceModel) {
        guard let source = space(of: tab), source !== dest, !tab.isPrivate else { return }
        let wasSelected = source.selectedID == tab.id
        source.pinned.removeAll { $0 === tab }
        source.tabs.removeAll { $0 === tab }
        source.recent.removeAll { $0 == tab.id }
        // Cookies live in the space's data store, so the page reloads in its new home.
        let url = tab.webView?.url ?? tab.url
        tab.sleep(force: true)
        tab.savedState = nil
        tab.url = url
        tab.spaceID = dest.id
        tab.isPinned = false
        tab.pinnedHome = nil
        dest.tabs.append(tab)
        if wasSelected, source.id == activeSpaceID { selectAfterClosing(tab, in: source, near: nil) }
        sessionDirty()
    }

    func selectTab(number: Int) {
        let all = activeSpace.allTabs
        guard !all.isEmpty else { return }
        select(number >= 9 ? all[all.count - 1] : all[min(number - 1, all.count - 1)])
    }

    func cycleTab(_ delta: Int) {
        let all = activeSpace.allTabs
        guard all.count > 1, let current = selectedTab, let i = all.firstIndex(where: { $0 === current }) else { return }
        select(all[(i + delta + all.count) % all.count])
    }

    // MARK: Links & popups

    func openLink(_ url: URL, from tab: Tab, background: Bool) {
        let new = newTab(url: url, select: !background, isPrivate: tab.isPrivate, in: space(of: tab), after: tab)
        if background { new.wake() }
    }

    func openPopup(configuration: WKWebViewConfiguration, from tab: Tab) -> Tab {
        let new = newTab(url: nil, select: false, isPrivate: tab.isPrivate, in: space(of: tab), after: tab)
        new.wake(configuration: configuration)
        select(new)
        return new
    }

    /// Opens something typed or clicked in Searchy's own UI.
    func open(_ url: URL, inNewTab: Bool = false) {
        guard let tab = selectedTab, !inNewTab else { newTab(url: url); return }
        // Navigating a pinned tab to a different site opens a new tab instead of replacing the pin.
        if tab.isPinned, let host = url.host?.strippingWWW, host != tab.pinnedHome?.host?.strippingWWW { newTab(url: url); return }
        tab.load(url)
    }

    func navigate(_ input: String, inNewTab: Bool = false) {
        if let (quick, rest) = QuickSearch.match(input.trimmingCharacters(in: .whitespaces)), let url = quick.url(for: rest) {
            open(url, inNewTab: inNewTab)
            return
        }
        open(Omnibox.resolve(input, engine: Preferences.shared.searchEngine), inNewTab: inNewTab)
    }

    // MARK: Command bar

    func openPalette(prefill: String = "", newTab: Bool = false, ephemeral: Tab? = nil) {
        palette = PaletteState(isOpen: true, opensNewTab: newTab, prefill: prefill, ephemeralTabID: ephemeral?.id)
    }

    func closePalette(committed: Bool = false) {
        let ephemeral = palette.ephemeralTabID
        palette = PaletteState()
        if !committed, let id = ephemeral, let tab = allTabs.first(where: { $0.id == id }), tab.isBlank {
            close(tab, remember: false)
        }
    }

    // MARK: Spaces

    func switchSpace(to id: UUID) {
        guard id != activeSpaceID, let target = spaces.first(where: { $0.id == id }) else { return }
        selectedTab?.deactivate()
        switchedForward = index(of: target) > index(of: activeSpace)
        activeSpaceID = id
        if target.allTabs.isEmpty { newTab(select: true) }
        else if let tab = target.tab(target.selectedID) ?? target.tabs.first ?? target.pinned.first { select(tab) }
        sessionDirty()
    }

    func cycleSpace(_ delta: Int) {
        guard spaces.count > 1 else { return }
        let i = index(of: activeSpace)
        let next = i + delta
        guard spaces.indices.contains(next) else { return }
        withAnimation(.smooth(duration: 0.35)) { switchSpace(to: spaces[next].id) }
    }

    func switchSpace(number: Int) {
        guard spaces.indices.contains(number - 1) else { return }
        withAnimation(.smooth(duration: 0.35)) { switchSpace(to: spaces[number - 1].id) }
    }

    @discardableResult
    func addSpace(_ info: SpaceInfo) -> SpaceModel {
        let space = SpaceModel(info)
        spaces.append(space)
        withAnimation(.smooth(duration: 0.35)) { switchSpace(to: space.id) }
        return space
    }

    func update(_ info: SpaceInfo) {
        guard let space = spaces.first(where: { $0.id == info.id }) else { return }
        space.info = info
        sessionDirty()
    }

    func removeSpace(_ id: UUID) {
        guard spaces.count > 1, let space = spaces.first(where: { $0.id == id }) else { return }
        if space.id == activeSpaceID { cycleSpace(index(of: space) > 0 ? -1 : 1) }
        for tab in space.allTabs { tab.sleep(force: true); tab.model = nil }
        spaces.removeAll { $0 === space }
        if space.info.isolated { WebEngine.shared.removeDataStore(for: space.info) }
        sessionDirty()
    }

    // MARK: Network resilience

    /// Opens the Wi-Fi sign-in page in a tab that allows plain HTTP and ignores blockers.
    func openPortal() {
        let target = NetworkMonitor.shared.portalURL ?? URL(string: "http://captive.apple.com/hotspot-detect.html")!
        let tab = newTab(url: nil, select: false)
        tab.isPortal = true
        select(tab)
        tab.load(target)
        // Once the portal lets traffic through, say so.
        Task {
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(3))
                NetworkMonitor.shared.recheck()
                try? await Task.sleep(for: .seconds(1.5))
                if NetworkMonitor.shared.quality != .captive { break }
            }
        }
    }

    /// Reloads tabs whose last load failed because the network was down.
    func resumeStalledTabs() {
        let stalled = allTabs.filter { $0.stalled && !$0.isPrivate }
        guard !stalled.isEmpty else { return }
        for tab in stalled { tab.stalled = false; if tab.webView != nil || tab === selectedTab { tab.reload(fromOrigin: false) } }
        toast("Back online — reloaded \(stalled.count) tab\(stalled.count == 1 ? "" : "s")", symbol: "wifi")
    }

    /// Handles the buttons on error pages (`searchy-action://retry?u=…`).
    func handleAction(_ url: URL, from tab: Tab) {
        let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "u" }?.value.flatMap(URL.init(string:))
        switch url.host {
        case "retry":
            if let target { tab.load(target) } else { tab.reload() }
        case "offline":
            if let target, let item = OfflineStore.shared.item(for: target) { tab.loadOfflineCopy(item) }
        case "lite":
            FlightMode.shared.level = .lite
            Task {
                await ContentBlocker.shared.rebuildLite()
                if let target { tab.load(target) }
            }
        case "doctor":
            sheet = .doctor
        case "portal":
            openPortal()
        default:
            break
        }
    }

    // MARK: Toasts

    func toast(_ text: String, symbol: String = "checkmark.circle.fill", actionTitle: String? = nil, action: (() -> Void)? = nil) {
        let toast = Toast(text: text, symbol: symbol, actionTitle: actionTitle, action: action)
        withAnimation(.snappy) { toasts.append(toast) }
        Task {
            try? await Task.sleep(for: .seconds(actionTitle == nil ? 2.6 : 5))
            withAnimation(.snappy) { toasts.removeAll { $0.id == toast.id } }
        }
    }

    func dismiss(_ toast: Toast) { withAnimation(.snappy) { toasts.removeAll { $0.id == toast.id } } }

    // MARK: Page actions on the selected tab

    func copyLink() {
        guard let url = selectedTab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        toast("Link copied", symbol: "link")
    }

    func printPage() {
        guard let view = selectedTab?.webView, let window else { return }
        let op = view.printOperation(with: NSPrintInfo.shared)
        op.view?.frame = view.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func toggleSidebar() {
        withAnimation(.smooth(duration: 0.3)) {
            sidebarVisible.toggle()
            sidebarPeeking = false
        }
    }

    func showFind() {
        findVisible = true
        findFocusToken += 1
    }

    func credentialsSubmitted(from tab: Tab, body: [String: Any]) {
        // Filled in with the password manager.
    }

    // MARK: Sleep & memory

    /// Releases memory held by background tabs:
    ///  1. tabs idle longer than the sleep timeout,
    ///  2. heavy tabs (over 300 MB) after a minute out of sight,
    ///  3. the least recently used tabs, if all web processes together exceed the memory budget.
    /// Tabs that are playing audio, floating, or loading are never touched.
    func sleepIdleTabs(olderThan override: TimeInterval? = nil) {
        let minutes = Preferences.shared.sleepAfterMinutes
        let now = Date()
        let current = selectedTab
        let candidates = allTabs.filter { $0 !== current && $0.webView != nil && !$0.isLoading && !$0.isPlayingAudio && !$0.isPiPActive }

        if let override {
            for tab in candidates where now.timeIntervalSince(tab.lastActive) >= override { tab.sleep() }
        } else {
            if minutes > 0 {
                for tab in candidates where now.timeIntervalSince(tab.lastActive) > Double(minutes) * 60 { tab.sleep() }
            }
            for tab in candidates where tab.webView != nil && now.timeIntervalSince(tab.lastActive) > 60 && tab.sampleMemory() > 300 << 20 { tab.sleep() }
            let live = allTabs.filter { $0.webView != nil }
            var total = live.reduce(UInt64(0)) { $0 + $1.sampleMemory() }
            let budget = MemoryManager.budgetBytes
            if total > budget {
                for tab in candidates.sorted(by: { $0.lastActive < $1.lastActive }) where tab.webView != nil {
                    total -= min(total, tab.memoryBytes)
                    tab.sleep()
                    if total <= budget { break }
                }
            }
        }
        MemoryManager.relieve()
    }

    // MARK: Session

    func sessionDirty() {
        guard BrowserRegistry.shared.primary === self else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            sessionFile.save(snapshot(), after: .milliseconds(10))
            try? await Task.sleep(for: .seconds(1))
            MemoryManager.relieve()
        }
    }

    func snapshot() -> SessionSnapshot {
        SessionSnapshot(
            spaces: spaces.map { s in
                SpaceSnapshot(info: s.info,
                              pinned: s.pinned.map { $0.snapshot() },
                              tabs: s.tabs.filter { !$0.isPrivate && $0.url != nil || ($0.isBlank && !$0.isPrivate) }.map { $0.snapshot() },
                              selected: s.selectedID)
            },
            active: activeSpaceID)
    }

    func saveSessionNow() {
        guard BrowserRegistry.shared.primary === self else { return }
        sessionFile.saveNow(snapshot())
    }

    func attach(window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    func shutdown() {
        saveSessionNow()
        sleepTimer?.invalidate()
        for tab in allTabs { tab.sleep(force: true) }
        BrowserRegistry.shared.unregister(self)
    }
}

/// Which sheet (if any) a window is showing.
enum BrowserSheet: Identifiable {
    case passwords, bookmarks, history, importer, extensions, memory, offline, flightPrep, doctor, routes
    var id: Self { self }
}

struct SpaceEditorRequest: Identifiable {
    let id = UUID()
    var info: SpaceInfo
    var isNew: Bool
}

// MARK: - Registry

@MainActor
final class BrowserRegistry {
    static let shared = BrowserRegistry()

    private struct Weak { weak var model: BrowserModel? }
    private var entries: [Weak] = []

    var models: [BrowserModel] { entries.compactMap(\.model) }
    var isEmpty: Bool { models.isEmpty }
    /// The oldest window owns the saved session.
    var primary: BrowserModel? { models.first }
    var frontmost: BrowserModel? {
        models.first { $0.window?.isKeyWindow == true } ?? models.first { $0.window?.isMainWindow == true } ?? models.first
    }

    func register(_ model: BrowserModel) {
        entries.removeAll { $0.model == nil }
        entries.append(Weak(model: model))
    }

    func unregister(_ model: BrowserModel) { entries.removeAll { $0.model == nil || $0.model === model } }
}
