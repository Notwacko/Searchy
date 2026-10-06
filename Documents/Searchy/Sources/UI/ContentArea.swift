import SwiftUI
import WebKit

/// Hosts a tab's WKWebView inside SwiftUI without ever re-creating it.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView?
    var focusOnChange = true

    func makeNSView(context: Context) -> WebContainer { WebContainer() }
    func updateNSView(_ view: WebContainer, context: Context) { view.show(webView, focus: focusOnChange) }

    final class WebContainer: NSView {
        private weak var shown: WKWebView?

        override var mouseDownCanMoveWindow: Bool { false }

        func show(_ web: WKWebView?, focus: Bool) {
            guard shown !== web else { return }
            shown?.removeFromSuperview()
            shown = web
            guard let web else { return }
            web.frame = bounds
            web.autoresizingMask = [.width, .height]
            addSubview(web)
            if focus { DispatchQueue.main.async { [weak web] in if let web, web.window?.firstResponder is NSText == false { web.window?.makeFirstResponder(web) } } }
        }
    }
}

struct ContentCard: View {
    let model: BrowserModel

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if let tab = model.selectedTab {
                if tab.isBlank {
                    NewTabPage(model: model, tab: tab)
                } else {
                    WebViewHost(webView: tab.webView, focusOnChange: !model.palette.isOpen)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.findVisible, let tab = model.selectedTab { FindBar(model: model, tab: tab).padding(12) }
        }
        .overlay(alignment: .top) {
            if let tab = model.selectedTab, tab.isPiPActive { FloatingBadge().padding(.top, 10).transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 3)
        .animation(.smooth(duration: 0.25), value: model.selectedTab?.isPiPActive)
    }
}

private struct FloatingBadge: View {
    var body: some View {
        Label("Playing in floating video", systemImage: "pip.fill")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Find in page

struct FindBar: View {
    let model: BrowserModel
    let tab: Tab
    @State private var text = ""
    @State private var noMatch = false
    @FocusState private var focused: Bool

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in page", text: $text)
                    .textFieldStyle(.plain)
                    .frame(width: 190)
                    .focused($focused)
                    .onSubmit { find(forward: true) }
                    .onChange(of: text) { _, _ in find(forward: true) }
                    .onKeyPress(.escape) { close(); return .handled }
                if noMatch && !text.isEmpty { Text("Not found").font(.caption).foregroundStyle(.red) }
                Button { find(forward: false) } label: { Image(systemName: "chevron.up") }.buttonStyle(IconButtonStyle(size: 24))
                Button { find(forward: true) } label: { Image(systemName: "chevron.down") }.buttonStyle(IconButtonStyle(size: 24))
                Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle(size: 24))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
        }
        .onAppear { focused = true }
        .onChange(of: model.findFocusToken) { _, _ in focused = true }
    }

    private func find(forward: Bool) {
        guard !text.isEmpty, let view = tab.webView else { noMatch = false; return }
        let config = WKFindConfiguration()
        config.backwards = !forward
        config.wraps = true
        Task { noMatch = !((try? await view.find(text, configuration: config))?.matchFound ?? true) }
    }

    private func close() {
        model.findVisible = false
        Task { _ = try? await tab.webView?.find("", configuration: WKFindConfiguration()) }
        tab.webView?.window?.makeFirstResponder(tab.webView)
    }
}

// MARK: - New tab page

struct NewTabPage: View {
    let model: BrowserModel
    let tab: Tab
    @State private var topSites: [HistoryEntry] = []

    var body: some View {
        let color = model.activeSpace.info.color.color
        ZStack {
            LinearGradient(colors: [color.opacity(tab.isPrivate ? 0.0 : 0.32), color.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if tab.isPrivate { LinearGradient(colors: [.purple.opacity(0.4), .indigo.opacity(0.12)], startPoint: .top, endPoint: .bottom) }
            VStack(spacing: 26) {
                Spacer(minLength: 40)
                TimelineView(.everyMinute) { context in
                    VStack(spacing: 4) {
                        Text(context.date, format: .dateTime.hour().minute())
                            .font(.system(size: 72, weight: .thin, design: .rounded)).monospacedDigit()
                        Text(greeting(context.date)).font(.title3).foregroundStyle(.secondary)
                    }
                }
                Button { model.openPalette() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: tab.isPrivate ? "eye.slash.fill" : "magnifyingglass").foregroundStyle(.secondary)
                        Text(tab.isPrivate ? "Search privately" : "Search \(Preferences.shared.searchEngine.name) or enter address")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("⌘L").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }
                    .font(.title3)
                    .padding(.horizontal, 20).frame(width: 560, height: 56)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                if tab.isPrivate {
                    Text("Private tab\nNo history, its own cookies, gone when you close it.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                } else if !tiles.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(104), spacing: 18), count: min(tiles.count, 6)), spacing: 18) {
                        ForEach(tiles, id: \.url) { tile in
                            SiteTile(title: tile.title, url: tile.url) {
                                if let u = URL(string: tile.url) { model.open(u) }
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                Spacer(minLength: 60)
            }
            .padding(30)
        }
        .task { topSites = await HistoryStore.shared.topSites(limit: 12) }
    }

    private struct Tile { var title: String; var url: String }

    private var tiles: [Tile] {
        var seen = Set<String>()
        var out: [Tile] = []
        for b in BookmarkStore.shared.favorites { if let h = URL(string: b.url)?.host, seen.insert(h).inserted { out.append(Tile(title: b.title, url: b.url)) } }
        for e in topSites { if let h = URL(string: e.url)?.host, seen.insert(h).inserted { out.append(Tile(title: e.title.isEmpty ? e.host : e.title, url: e.url)) } }
        return Array(out.prefix(12))
    }

    private func greeting(_ date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Still up?"
        }
    }
}

struct SiteTile: View {
    let title: String
    let url: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let host = URL(string: url)?.host?.strippingWWW
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
                    if let host, let icon = FaviconStore.shared.cached(host: host) {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    } else {
                        Text(String((host ?? title).first.map(String.init) ?? "•").uppercased())
                            .font(.title2.weight(.semibold)).foregroundStyle(Color.tint(forHost: host))
                    }
                }
                .frame(width: 64, height: 64)
                .scaleEffect(hovering ? 1.06 : 1)
                Text(title).font(.caption).lineLimit(1).frame(width: 96)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: hovering)
    }
}
