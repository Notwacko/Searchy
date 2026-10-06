import SwiftUI

struct SidebarView: View {
    let model: BrowserModel
    var floating = false
    @Namespace private var selection

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(model: model)
            AddressPill(model: model, floating: floating)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            ZStack {
                SpaceContent(model: model, space: model.activeSpace, selection: selection)
                    .id(model.activeSpaceID)
                    .transition(.push(from: model.switchedForward ? .trailing : .leading))
            }
            .clipped()
            SidebarFooter(model: model)
        }
        .onSpaceSwipe { model.cycleSpace($0) }
    }
}

// MARK: - Header

struct SidebarHeader: View {
    let model: BrowserModel

    var body: some View {
        HStack(spacing: 2) {
            Spacer().frame(width: Metrics.trafficLights)
            Button { model.toggleSidebar() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(IconButtonStyle()).help("Hide sidebar (⌘S)")
            Spacer(minLength: 0)
            NavButtons(tab: model.selectedTab)
        }
        .padding(.trailing, 8)
        .frame(height: Metrics.barHeight)
        .background(WindowDragArea())
    }
}

struct NavButtons: View {
    let tab: Tab?

    var body: some View {
        HStack(spacing: 0) {
            Button { tab?.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!(tab?.canGoBack ?? false)).help("Back (⌘[)")
            Button { tab?.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!(tab?.canGoForward ?? false)).help("Forward (⌘])")
            Button { (tab?.isLoading ?? false) ? tab?.stop() : tab?.reload() } label: {
                Image(systemName: (tab?.isLoading ?? false) ? "xmark" : "arrow.clockwise")
            }
            .help("Reload (⌘R)")
        }
        .buttonStyle(IconButtonStyle())
    }
}

// MARK: - Content

struct SpaceContent: View {
    let model: BrowserModel
    let space: SpaceModel
    var selection: Namespace.ID

    var body: some View {
        VStack(spacing: 0) {
            PinnedGrid(model: model, space: space)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(space.tabs) { tab in
                        TabRow(model: model, tab: tab, selected: space.selectedID == tab.id, namespace: selection)
                    }
                    Color.clear.frame(height: 40)
                        .dropDestination(for: String.self) { items, _ in
                            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                            model.move(id, before: nil, pinned: false); return true
                        }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)
        }
    }
}

struct PinnedGrid: View {
    let model: BrowserModel
    let space: SpaceModel

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.tileSize, maximum: 60), spacing: 8)], spacing: 8) {
                ForEach(space.pinned) { tab in
                    PinnedTile(model: model, tab: tab, selected: space.selectedID == tab.id)
                        .draggable(tab.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                            model.move(id, before: tab.id, pinned: true); return true
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, space.pinned.isEmpty ? 0 : 8)
            Color.clear.frame(height: space.pinned.isEmpty ? 6 : 0)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            model.move(id, before: nil, pinned: true); return true
        }
    }
}

struct PinnedTile: View {
    let model: BrowserModel
    let tab: Tab
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let tint = Color.tint(forHost: tab.host)
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(LinearGradient(colors: [tint, tint.opacity(0.68)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(tab.letter).font(.title3.weight(.semibold)).foregroundStyle(.white)
        }
        .frame(height: Metrics.tileSize)
        .opacity(tab.isSleeping ? 0.5 : 1)
        .scaleEffect(hovering && !selected ? 1.04 : 1)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.95), lineWidth: 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if tab.isPlayingAudio {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .padding(4).background(.black.opacity(0.35), in: Circle()).padding(3)
            }
        }
        .overlay(alignment: .bottom) {
            if tab.isLoading { ProgressView().controlSize(.mini).tint(.white).padding(3) }
        }
        .shadow(color: selected ? tint.opacity(0.5) : .clear, radius: 8, y: 2)
        .contentShape(Rectangle())
        .onTapGesture { model.select(tab) }
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: hovering)
        .animation(.snappy(duration: 0.25), value: selected)
        .help(tab.displayTitle + (tab.isSleeping ? " — asleep" : ""))
        .contextMenu {
            Button("Back to Pinned Page", systemImage: "arrow.uturn.backward") { tab.goHome() }.disabled(tab.pinnedHome == nil)
            Button("Put to Sleep", systemImage: "moon.zzz") { tab.sleep(force: true) }.disabled(tab.isSleeping)
            Button("Copy Link", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.url?.absoluteString ?? "", forType: .string)
            }
            Divider()
            Button("Unpin", systemImage: "pin.slash") { model.togglePin(tab) }
        }
    }
}

struct TabRow: View {
    let model: BrowserModel
    let tab: Tab
    let selected: Bool
    var namespace: Namespace.ID
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            TabIcon(tab: tab)
            Text(tab.displayTitle)
                .lineLimit(1)
                .foregroundStyle(tab.isPrivate ? Color.purple : Color.primary)
                .opacity(tab.isSleeping && !selected ? 0.6 : 1)
            Spacer(minLength: 0)
            if tab.isPlayingAudio {
                Image(systemName: "speaker.wave.2.fill").font(.caption2).foregroundStyle(.secondary)
            }
            if hovering || selected {
                Button { model.close(tab) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(IconButtonStyle(size: 20))
                    .help("Close tab (⌘W)")
            }
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: Metrics.rowHeight)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.13))
                    .matchedGeometryEffect(id: "selection", in: namespace)
            } else if hovering {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.25)) { model.select(tab) } }
        .onHover { hovering = $0 }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            model.move(id, before: tab.id, pinned: false); return true
        }
        .contextMenu { TabMenu(model: model, tab: tab) }
    }
}

struct TabIcon: View {
    let tab: Tab

    var body: some View {
        ZStack {
            if tab.isLoading && tab.progress < 1 {
                ProgressView().controlSize(.mini).scaleEffect(0.8)
            } else if tab.isPrivate {
                Image(systemName: "eye.slash.fill").foregroundStyle(.purple)
            } else if let icon = tab.favicon {
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                    .saturation(tab.isSleeping ? 0.4 : 1)
            } else if tab.isBlank {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
            } else {
                Image(systemName: "globe").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .frame(width: 16, height: 16)
    }
}

struct TabMenu: View {
    let model: BrowserModel
    let tab: Tab

    var body: some View {
        if !tab.isPrivate {
            Button(tab.isPinned ? "Unpin" : "Pin Tab", systemImage: tab.isPinned ? "pin.slash" : "pin") { model.togglePin(tab) }
        }
        Button("Duplicate", systemImage: "plus.square.on.square") {
            if let url = tab.url { model.newTab(url: url, isPrivate: tab.isPrivate, after: tab) }
        }
        Button("Copy Link", systemImage: "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.url?.absoluteString ?? "", forType: .string)
        }
        if model.spaces.count > 1 && !tab.isPrivate {
            Menu("Move to Space", systemImage: "square.on.square") {
                ForEach(model.spaces.filter { $0.id != tab.spaceID }) { s in
                    Button(s.info.name, systemImage: s.info.symbol) { model.move(tab, toSpace: s) }
                }
            }
        }
        RouteMenu(model: model, tab: tab)
        Divider()
        Button("Put to Sleep", systemImage: "moon.zzz") { tab.sleep(force: true) }.disabled(tab.isSleeping)
        Button("Close Tab", systemImage: "xmark") { model.close(tab) }
        if !tab.isPinned, let space = model.space(of: tab) {
            Button("Close Other Tabs") { for t in space.tabs where t !== tab { model.close(t) } }
            Button("Close Tabs Below") {
                if let i = space.tabs.firstIndex(where: { $0 === tab }) { for t in space.tabs[(i + 1)...] { model.close(t) } }
            }
        }
    }
}

// MARK: - Footer

struct SidebarFooter: View {
    let model: BrowserModel

    var body: some View {
        VStack(spacing: 6) {
            Button { model.newTabWithPalette() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "plus").frame(width: 16)
                    Text("New Tab")
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: Metrics.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            .padding(.horizontal, 8)

            HStack(spacing: 2) {
                SpaceSwitcher(model: model)
                Spacer(minLength: 0)
                FlightButton(model: model)
                DownloadsButton(model: model)
                MoreMenu(model: model)
            }
            .padding(.horizontal, 10)
        }
        .padding(.top, 6)
    }
}

struct RowButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0)))
            .onHover { hovering = $0 }
    }
}

struct SpaceSwitcher: View {
    let model: BrowserModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.spaces) { space in
                let active = space.id == model.activeSpaceID
                Button {
                    withAnimation(.smooth(duration: 0.35)) { model.switchSpace(to: space.id) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: space.info.symbol)
                        if active { Text(space.info.name).lineLimit(1).transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading))) }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? space.info.color.color : Color.secondary)
                    .padding(.horizontal, active ? 10 : 7)
                    .frame(height: 28)
                    .background(Capsule().fill(active ? space.info.color.color.opacity(0.18) : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(space.info.name)
                .contextMenu {
                    Button("Edit Space…", systemImage: "pencil") { model.spaceEditor = SpaceEditorRequest(info: space.info, isNew: false) }
                    if model.spaces.count > 1 {
                        Divider()
                        Button("Delete Space", systemImage: "trash", role: .destructive) { model.removeSpace(space.id) }
                    }
                }
            }
            Button {
                let info = SpaceInfo(name: "New Space", symbol: SpaceInfo.symbols.randomElement() ?? "star.fill",
                                     color: SpaceColor.allCases.randomElement() ?? .blue)
                model.spaceEditor = SpaceEditorRequest(info: info, isNew: true)
            } label: { Image(systemName: "plus") }
                .buttonStyle(IconButtonStyle(size: 26)).help("New space")
        }
        .animation(.smooth(duration: 0.3), value: model.activeSpaceID)
    }
}

struct DownloadsButton: View {
    let model: BrowserModel
    private let manager = DownloadManager.shared

    var body: some View {
        if !manager.items.isEmpty {
            @Bindable var model = model
            Button { model.downloadsPopoverShown.toggle() } label: {
                ZStack {
                    if manager.activeCount > 0 {
                        Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
                        Circle().trim(from: 0, to: manager.items.first(where: { $0.state == .running })?.fraction ?? 0)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                            .padding(0)
                    }
                    Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
                }
                .frame(width: 18, height: 18)
            }
            .buttonStyle(IconButtonStyle(size: 28))
            .popover(isPresented: $model.downloadsPopoverShown, arrowEdge: .top) { DownloadsList() }
            .help("Downloads")
        }
    }
}

struct DownloadsList: View {
    private let manager = DownloadManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear") { manager.clearFinished() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(14)
            Divider()
            if manager.items.isEmpty {
                Text("No downloads").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
            } else {
                ScrollView {
                    VStack(spacing: 0) { ForEach(manager.items) { DownloadRow(item: $0) } }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 320)
    }
}

struct DownloadRow: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill").foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename).lineLimit(1)
                switch item.state {
                case .running: ProgressView(value: item.fraction).controlSize(.small)
                case .finished: Text("Done").font(.caption).foregroundStyle(.secondary)
                case .failed(let why): Text(why).font(.caption).foregroundStyle(.red).lineLimit(1)
                case .cancelled: Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if item.state == .running {
                Button { item.cancel() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
            } else if item.state == .finished {
                Button { item.reveal() } label: { Image(systemName: "magnifyingglass.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { item.open() }
    }
}

struct MoreMenu: View {
    let model: BrowserModel

    var body: some View {
        Menu {
            Button("Bookmarks", systemImage: "star") { model.sheet = .bookmarks }
            Button("History", systemImage: "clock") { model.sheet = .history }
            Button("Tab Memory…", systemImage: "memorychip") { model.sheet = .memory }
            Divider()
            Button(Preferences.shared.tabLayout == .sidebar ? "Tabs Across the Top" : "Tabs in the Sidebar", systemImage: "rectangle.split.2x1") {
                Preferences.shared.tabLayout = Preferences.shared.tabLayout == .sidebar ? .top : .sidebar
            }
            SettingsLink { Label("Settings…", systemImage: "gearshape") }
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.button).menuIndicator(.hidden)
            .buttonStyle(IconButtonStyle(size: 28))
            .fixedSize()
    }
}
