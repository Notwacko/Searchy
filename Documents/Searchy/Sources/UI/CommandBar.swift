import SwiftUI

struct PaletteItem: Identifiable {
    enum Icon { case symbol(String), favicon(String), tab(Tab) }

    let id: String
    var title: String
    var subtitle = ""
    var icon: Icon
    var hint = ""
    /// Called with `true` when ⌘ was held (open in a new tab).
    var run: (Bool) -> Void
    /// What Tab-completion puts in the field.
    var completion: String?
}

@MainActor @Observable
final class CommandBarModel {
    var query = "" { didSet { if query != oldValue { refresh() } } }
    private(set) var items: [PaletteItem] = []
    var selection = 0

    @ObservationIgnored weak var browser: BrowserModel?
    @ObservationIgnored private var primary: [PaletteItem] = []
    @ObservationIgnored private var local: [PaletteItem] = []
    @ObservationIgnored private var history: [PaletteItem] = []
    @ObservationIgnored private var suggestions: [PaletteItem] = []
    @ObservationIgnored private var content: [PaletteItem] = []
    @ObservationIgnored private var contentTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var suggestTask: Task<Void, Never>?

    func bind(_ browser: BrowserModel) {
        self.browser = browser
        query = browser.palette.prefill
        refresh()
    }

    private var text: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    func refresh() {
        guard let browser else { return }
        historyTask?.cancel(); suggestTask?.cancel(); contentTask?.cancel()
        history = []; suggestions = []; content = []
        let q = text
        let engine = Preferences.shared.searchEngine
        let newTabDefault = browser.palette.opensNewTab

        // Primary action for exactly what was typed.
        primary = []
        if !q.isEmpty {
            if let (quick, rest) = QuickSearch.match(q), let url = quick.url(for: rest) {
                primary = [PaletteItem(id: "quick", title: "Search \(quick.name) for “\(rest)”", subtitle: url.host ?? "",
                                       icon: .symbol("magnifyingglass"), hint: "↩") { [weak self] newTab in
                    self?.go(url, newTab: newTab || newTabDefault) }]
            } else {
                switch Omnibox.classify(q) {
                case .url(let url):
                    primary = [PaletteItem(id: "go", title: url.host?.strippingWWW ?? url.absoluteString, subtitle: url.absoluteString,
                                           icon: .favicon(url.host ?? ""), hint: "Go") { [weak self] newTab in
                        self?.go(url, newTab: newTab || newTabDefault) }]
                case .search(let s):
                    primary = [PaletteItem(id: "search", title: "Search for “\(s)”", subtitle: engine.name,
                                           icon: .symbol("magnifyingglass"), hint: "↩") { [weak self] newTab in
                        self?.go(engine.searchURL(for: s), newTab: newTab || newTabDefault) }]
                }
            }
        }

        // Open tabs.
        local = []
        let tabs = browser.allTabs.filter { !$0.isBlank && $0.id != browser.palette.ephemeralTabID }
        let matchingTabs = q.isEmpty ? Array(browser.activeSpace.allTabs.filter { !$0.isBlank }.prefix(6))
                                     : tabs.filter { matches($0.title + " " + ($0.url?.absoluteString ?? ""), q) }.prefix(3).map { $0 }
        for tab in matchingTabs where tab.id != browser.selectedTab?.id || !q.isEmpty {
            local.append(PaletteItem(id: "tab-\(tab.id)", title: tab.displayTitle, subtitle: tab.url?.host?.strippingWWW ?? "",
                                     icon: .tab(tab), hint: "Switch to Tab") { [weak self] _ in
                self?.browser?.closePalette(committed: true)
                self?.browser?.select(tab)
            })
        }
        if !q.isEmpty {
            for b in BookmarkStore.shared.search(q, limit: 3) {
                guard let url = URL(string: b.url) else { continue }
                local.append(PaletteItem(id: "bm-\(b.id)", title: b.title, subtitle: url.host?.strippingWWW ?? b.url,
                                         icon: .favicon(url.host ?? ""), hint: "Bookmark") { [weak self] newTab in
                    self?.go(url, newTab: newTab || newTabDefault) })
            }
            for o in OfflineStore.shared.search(q, limit: 3) {
                guard let url = URL(string: o.url) else { continue }
                local.append(PaletteItem(id: "off-\(o.id)", title: o.title, subtitle: o.host, icon: .symbol("arrow.down.circle"), hint: "Saved page") { [weak self] newTab in
                    guard let browser = self?.browser else { return }
                    browser.closePalette(committed: true)
                    let tab = (newTab || newTabDefault || browser.selectedTab == nil) ? browser.newTab() : browser.selectedTab!
                    _ = url
                    tab.loadOfflineCopy(o)
                })
            }
            local += commands(matching: q)
        }
        selection = 0
        rebuild()
        guard !q.isEmpty else { return }

        historyTask = Task { [weak self] in
            let hits = await HistoryStore.shared.search(q, limit: 5)
            guard !Task.isCancelled, let self else { return }
            self.history = hits.compactMap { e in
                guard let url = URL(string: e.url) else { return nil }
                return PaletteItem(id: "h-\(e.id)", title: e.title.isEmpty ? e.host : e.title, subtitle: e.host,
                                   icon: .favicon(url.host ?? ""), hint: "History") { [weak self] newTab in
                    self?.go(url, newTab: newTab || newTabDefault) }
            }
            self.rebuild()
        }
        if Preferences.shared.indexPages, q.count >= 3 {
            contentTask = Task { [weak self] in
                let hits = await ContentIndex.shared.search(q, limit: 4)
                guard !Task.isCancelled, let self else { return }
                self.content = hits.compactMap { h in
                    guard let url = URL(string: h.url) else { return nil }
                    return PaletteItem(id: "c-\(h.id)", title: h.title.isEmpty ? h.host : h.title, subtitle: h.snippet.isEmpty ? h.host : h.snippet,
                                       icon: .favicon(url.host ?? ""), hint: "In page text") { [weak self] newTab in
                        self?.go(url, newTab: newTab || newTabDefault) }
                }
                self.rebuild()
            }
        }
        if Preferences.shared.searchSuggestions, q.count >= 2, !browser.isPrivateSelected, !FlightMode.shared.isActive, NetworkMonitor.shared.isOnline {
            suggestTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled else { return }
                let list = await Suggestions.fetch(q, engine: engine)
                guard !Task.isCancelled, let self else { return }
                self.suggestions = list.filter { $0.caseInsensitiveCompare(q) != .orderedSame }.map { s in
                    PaletteItem(id: "s-\(s)", title: s, icon: .symbol("magnifyingglass"), hint: "Search", run: { [weak self] newTab in
                        self?.go(engine.searchURL(for: s), newTab: newTab || newTabDefault) }, completion: s)
                }
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        var seen = Set<String>()
        items = (primary + local + history + content + suggestions).filter { seen.insert($0.id).inserted }
        selection = min(selection, max(items.count - 1, 0))
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = (selection + delta + items.count) % items.count
    }

    func submit(newTab: Bool) {
        guard let browser else { return }
        if items.indices.contains(selection) { items[selection].run(newTab) }
        else if !text.isEmpty { go(Omnibox.resolve(text, engine: Preferences.shared.searchEngine), newTab: newTab || browser.palette.opensNewTab) }
    }

    func complete() {
        if items.indices.contains(selection), let c = items[selection].completion { query = c }
    }

    private func go(_ url: URL, newTab: Bool) {
        guard let browser else { return }
        let ephemeral = browser.palette.ephemeralTabID.flatMap { id in browser.allTabs.first { $0.id == id } }
        browser.closePalette(committed: true)
        if let ephemeral, ephemeral.isBlank, !newTab { browser.select(ephemeral); ephemeral.load(url) }
        else { browser.open(url, inNewTab: newTab) }
    }

    private func matches(_ haystack: String, _ query: String) -> Bool {
        let h = haystack.lowercased()
        return query.lowercased().split(separator: " ").allSatisfy { h.contains($0) }
    }

    // MARK: Commands

    private struct Command { var name: String; var symbol: String; var run: (BrowserModel) -> Void }

    private func commands(matching q: String) -> [PaletteItem] {
        guard q.count >= 2, let browser else { return [] }
        let all: [Command] = [
            .init(name: "New Private Tab", symbol: "eye.slash") { $0.newPrivateTab() },
            .init(name: "New Space", symbol: "square.on.square") { $0.spaceEditor = SpaceEditorRequest(info: SpaceInfo(name: "New Space", symbol: "star.fill", color: .purple), isNew: true) },
            .init(name: "Reading Mode", symbol: "doc.plaintext") { $0.selectedTab?.toggleReader() },
            .init(name: "Hide Element", symbol: "eye.slash") { $0.selectedTab?.togglePicker() },
            .init(name: "Floating Video", symbol: "pip.enter") { $0.selectedTab?.toggleFloatingVideo() },
            .init(name: "Toggle Sidebar", symbol: "sidebar.left") { $0.toggleSidebar() },
            .init(name: "Find in Page", symbol: "magnifyingglass") { $0.showFind() },
            .init(name: "Bookmarks", symbol: "star") { $0.sheet = .bookmarks },
            .init(name: "History", symbol: "clock") { $0.sheet = .history },
            .init(name: "Reopen Closed Tab", symbol: "arrow.uturn.backward") { $0.reopenClosedTab() },
            .init(name: "Copy Link", symbol: "link") { $0.copyLink() },
            .init(name: "Settings", symbol: "gearshape") { _ in NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) },
        ]
        return all.filter { matches($0.name, q) }.prefix(3).map { c in
            PaletteItem(id: "cmd-\(c.name)", title: c.name, icon: .symbol(c.symbol), hint: "Command") { [weak self] _ in
                guard let browser = self?.browser else { return }
                browser.closePalette(committed: true)
                c.run(browser)
            }
        }
    }
}

extension BrowserModel {
    var isPrivateSelected: Bool { selectedTab?.isPrivate ?? false }
}

struct CommandBar: View {
    let model: BrowserModel
    @State private var vm = CommandBarModel()

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.22).ignoresSafeArea()
                .onTapGesture { model.closePalette() }
                .transition(.opacity)
            GlassEffectContainer {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                        CommandField(text: $vm.query,
                                     placeholder: model.palette.opensNewTab ? "Search or enter address (new tab)" : "Search or enter address",
                                     onMove: { vm.move($0) },
                                     onSubmit: { flags in vm.submit(newTab: flags.contains(.command)) },
                                     onCancel: { model.closePalette() },
                                     onTab: { vm.complete() })
                            .frame(height: 28)
                        if model.isPrivateSelected { Image(systemName: "eye.slash.fill").foregroundStyle(.purple) }
                    }
                    .padding(.horizontal, 18).frame(height: 56)

                    if !vm.items.isEmpty {
                        Divider().opacity(0.5)
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(spacing: 2) {
                                    ForEach(Array(vm.items.enumerated()), id: \.element.id) { index, item in
                                        PaletteRow(item: item, selected: index == vm.selection)
                                            .id(item.id)
                                            .onTapGesture { vm.selection = index; vm.submit(newTab: NSEvent.modifierFlags.contains(.command)) }
                                    }
                                }
                                .padding(8)
                            }
                            .frame(maxHeight: 396)
                            .scrollIndicators(.never)
                            .onChange(of: vm.selection) { _, new in
                                if vm.items.indices.contains(new) { proxy.scrollTo(vm.items[new].id) }
                            }
                        }
                    }
                }
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
            }
            .frame(width: 660)
            .shadow(color: .black.opacity(0.28), radius: 30, y: 12)
            .padding(.top, 90)
            .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
        }
        .onAppear { vm.bind(model) }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if selected && !item.hint.isEmpty {
                Text(item.hint).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        switch item.icon {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
        case .favicon(let host):
            if let image = FaviconStore.shared.cached(host: host.strippingWWW) ?? FaviconStore.shared.cached(host: host) {
                Image(nsImage: image).resizable().interpolation(.high).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "globe").foregroundStyle(.secondary)
            }
        case .tab(let tab):
            if let image = tab.favicon {
                Image(nsImage: image).resizable().interpolation(.high).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "macwindow").foregroundStyle(.secondary)
            }
        }
    }
}

/// An NSTextField so we get select-all-on-focus and arrow/return/escape handling for free.
struct CommandField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onMove: (Int) -> Void
    var onSubmit: (NSEvent.ModifierFlags) -> Void
    var onCancel: () -> Void
    var onTab: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.stringValue = text
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandField
        init(_ parent: CommandField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(NSApp.currentEvent?.modifierFlags ?? [])
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            case #selector(NSResponder.insertTab(_:)): parent.onTab()
            default: return false
            }
            return true
        }
    }
}
