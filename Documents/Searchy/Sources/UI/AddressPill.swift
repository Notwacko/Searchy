import SwiftUI

/// The address "pill": shows where you are, opens the command bar when clicked, and carries
/// the per-page actions (reader, bookmark, floating video, …).
struct AddressPill: View {
    let model: BrowserModel
    var floating = false
    @State private var hovering = false

    var body: some View {
        let tab = model.selectedTab
        HStack(spacing: 2) {
            HStack(spacing: 7) {
                leading(tab)
                label(tab)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .contentShape(Rectangle())
            .onTapGesture { model.openPalette(prefill: tab?.url?.absoluteString ?? "") }

            if let tab { Trailing(model: model, tab: tab) }
        }
        .frame(height: 34)
        .padding(.trailing, 4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.11 : 0.075)))
        .overlay(alignment: .bottomLeading) { progress(tab) }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(tab?.url?.absoluteString ?? "Search or enter address (⌘L)")
    }

    @ViewBuilder private func leading(_ tab: Tab?) -> some View {
        if let tab, !tab.isBlank {
            if tab.isOfflineCopy {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
            } else if tab.isPrivate {
                Image(systemName: "eye.slash.fill").foregroundStyle(.purple)
            } else if tab.url?.scheme == "http" {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if tab.url?.scheme == "https" {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).imageScale(.small)
            } else {
                Image(systemName: "doc").foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func label(_ tab: Tab?) -> some View {
        if let tab, tab.isOfflineCopy, let host = tab.host {
            HStack(spacing: 6) {
                Text(host).fontWeight(.medium)
                Text("saved copy").font(.caption.weight(.semibold)).foregroundStyle(.green)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.green.opacity(0.15)))
            }
            .lineLimit(1)
        } else if let tab, let url = tab.url, let host = tab.host {
            HStack(spacing: 6) {
                if tab.route.kind != .direct {
                    Image(systemName: tab.route.symbol).font(.caption.weight(.bold))
                        .foregroundStyle(tab.route.kind == .inspect ? Color.orange : tab.route.needsTunnel ? Color.green : Color.blue)
                        .help("Routed through \(tab.route.name)")
                }
                HStack(spacing: 0) {
                    Text(host).fontWeight(.medium)
                    let path = Self.path(of: url)
                    if !path.isEmpty { Text(path).foregroundStyle(.secondary) }
                }
            }
            .lineLimit(1).truncationMode(.middle)
        } else if let tab, let url = tab.url {
            Text(url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent).lineLimit(1)
        } else {
            Text(tab?.isPrivate == true ? "Private — search or enter address" : "Search or enter address").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func progress(_ tab: Tab?) -> some View {
        if let tab, tab.isLoading, tab.progress < 1 {
            GeometryReader { g in
                Capsule().fill(Color.accentColor)
                    .frame(width: max(8, g.size.width * tab.progress), height: 2)
                    .animation(.easeOut(duration: 0.25), value: tab.progress)
            }
            .frame(height: 2)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private static func path(of url: URL) -> String {
        var p = url.path
        if p == "/" { p = "" }
        if let q = url.query, !q.isEmpty, p.count < 24 { p += "?" + q }
        return p
    }

    private struct Trailing: View {
        let model: BrowserModel
        let tab: Tab

        var body: some View {
            HStack(spacing: 0) {
                if tab.hasPlayingVideo || tab.isPiPActive {
                    Button { tab.toggleFloatingVideo() } label: { Image(systemName: tab.isPiPActive ? "pip.exit" : "pip.enter") }
                        .buttonStyle(IconButtonStyle(size: 26)).help("Floating video (⇧⌘V)")
                }
                if tab.isReadable || tab.isReaderActive {
                    Button { tab.toggleReader() } label: { Image(systemName: tab.isReaderActive ? "doc.plaintext.fill" : "doc.plaintext") }
                        .buttonStyle(IconButtonStyle(size: 26)).help("Reading mode (⇧⌘R)")
                }
                if !tab.isBlank, let url = tab.url, tab.url?.scheme?.hasPrefix("http") == true {
                    let marked = BookmarkStore.shared.isBookmarked(url)
                    Button { BookmarkStore.shared.toggle(url: url, title: tab.displayTitle)
                        model.toast(marked ? "Bookmark removed" : "Bookmarked", symbol: marked ? "star.slash" : "star.fill") } label: {
                        Image(systemName: marked ? "star.fill" : "star").foregroundStyle(marked ? Color.yellow : Color.primary)
                    }
                    .buttonStyle(IconButtonStyle(size: 26)).help("Bookmark (⌘D)")
                }
                PageMenu(model: model, tab: tab)
            }
        }
    }
}

/// Everything you can do to the current page, in one menu.
struct PageMenu: View {
    let model: BrowserModel
    let tab: Tab

    var body: some View {
        Menu {
            Button("Reload", systemImage: "arrow.clockwise") { tab.reload() }
            Button("Find in Page…", systemImage: "magnifyingglass") { model.showFind() }
            Divider()
            Button("Hide Element…", systemImage: "eye.slash") { tab.togglePicker() }
            Button("Reading Mode", systemImage: "doc.plaintext") { tab.toggleReader() }
            Button("Floating Video", systemImage: "pip.enter") { tab.toggleFloatingVideo() }
            Button("Save for Offline", systemImage: "arrow.down.circle") { Task { await tab.saveForOffline() } }
            if tab.isOfflineCopy { Button("Open Live Page", systemImage: "globe") { tab.openLive() } }
            if let host = tab.host, FlightMode.shared.effective == .textOnly {
                let allowed = FlightMode.shared.imageAllowedHosts.contains(HiddenElementStore.key(host))
                Button(allowed ? "Hide Images on \(host)" : "Load Images on \(host)", systemImage: "photo") {
                    FlightMode.shared.setImagesAllowed(!allowed, on: host); tab.reload()
                }
            }
            if let host = tab.host {
                let allowed = SiteSettings.shared.adsAreAllowed(on: host)
                Button(allowed ? "Block Ads on \(host)" : "Allow Ads on \(host)", systemImage: allowed ? "shield.lefthalf.filled" : "shield.slash") {
                    SiteSettings.shared.setAdsAllowed(!allowed, on: host)
                    tab.reload()
                }
                let autoplay = SiteSettings.shared.autoplayIsAllowed(on: host)
                Button(autoplay ? "Stop Autoplay on \(host)" : "Allow Autoplay on \(host)", systemImage: autoplay ? "pause.circle" : "play.circle") {
                    SiteSettings.shared.setAutoplayAllowed(!autoplay, on: host)
                    tab.reload()
                }
                if !HiddenElementStore.shared.selectors(for: host).isEmpty {
                    Button("Show Hidden Elements on This Site", systemImage: "eye") {
                        HiddenElementStore.shared.removeAll(host: host)
                        tab.reload()
                    }
                }
            }
            RouteMenu(model: model, tab: tab)
            Divider()
            Button("Zoom In", systemImage: "plus.magnifyingglass") { tab.zoomIn() }
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { tab.zoomOut() }
            Button("Actual Size") { tab.zoomReset() }
            Divider()
            Button("Copy Link", systemImage: "link") { model.copyLink() }
            if let url = tab.url { ShareLink(item: url) }
            Button("Print…", systemImage: "printer") { model.printPage() }
            Divider()
            Button("Put Tab to Sleep", systemImage: "moon.zzz") { tab.sleep(force: true) }
            Divider()
            Button("Inspect Element", systemImage: "chevron.left.forwardslash.chevron.right") { tab.webView?.showInspector(console: false) }
            Button("Show JavaScript Console", systemImage: "terminal") { tab.webView?.showInspector(console: true) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(IconButtonStyle(size: 26))
        .fixedSize()
    }
}
