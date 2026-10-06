import SwiftUI

/// Slim strip shown when the sidebar is folded away (or the top layout is used):
/// room for the traffic lights, navigation and a compact address pill.
struct CompactBar: View {
    let model: BrowserModel

    var body: some View {
        HStack(spacing: 2) {
            Spacer().frame(width: Metrics.trafficLights)
            if Preferences.shared.tabLayout == .sidebar {
                Button { model.toggleSidebar() } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(IconButtonStyle()).help("Show sidebar (⌘S)")
            }
            NavButtons(tab: model.selectedTab)
            Spacer(minLength: 8)
            AddressPill(model: model).frame(maxWidth: 480)
            Spacer(minLength: 8)
            FlightButton(model: model)
            Button { model.newTabWithPalette() } label: { Image(systemName: "plus") }.buttonStyle(IconButtonStyle()).help("New tab (⌘T)")
            DownloadsButton(model: model)
            MoreMenu(model: model)
        }
        .padding(.trailing, 10)
        .frame(height: Metrics.barHeight + 4)
        .background(WindowDragArea())
    }
}

/// Tabs across the top: pinned letters first, then flexible tab chips.
struct TopTabStrip: View {
    let model: BrowserModel
    @Namespace private var selection

    var body: some View {
        let space = model.activeSpace
        HStack(spacing: 6) {
            Spacer().frame(width: Metrics.trafficLights - 6)
            GeometryReader { geo in
                let count = max(space.tabs.count, 1)
                let fixed = CGFloat(space.pinned.count) * 36
                let width = min(220, max(110, (geo.size.width - fixed - 8) / CGFloat(count)))
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(space.pinned) { tab in
                            TopPinned(model: model, tab: tab, selected: space.selectedID == tab.id)
                        }
                        if !space.pinned.isEmpty { Divider().frame(height: 18).padding(.horizontal, 2) }
                        ForEach(space.tabs) { tab in
                            TopTab(model: model, tab: tab, selected: space.selectedID == tab.id, namespace: selection)
                                .frame(width: width)
                        }
                    }
                    .padding(.vertical, 5)
                }
                .scrollIndicators(.never)
            }
            Button { model.newTabWithPalette() } label: { Image(systemName: "plus") }.buttonStyle(IconButtonStyle()).help("New tab (⌘T)")
            SpaceSwitcher(model: model)
        }
        .padding(.trailing, 10)
        .frame(height: Metrics.barHeight + 2)
        .background(WindowDragArea())
        .onSpaceSwipe { model.cycleSpace($0) }
    }
}

private struct TopPinned: View {
    let model: BrowserModel
    let tab: Tab
    let selected: Bool

    var body: some View {
        let tint = Color.tint(forHost: tab.host)
        Text(tab.letter).font(.callout.weight(.semibold)).foregroundStyle(.white)
            .frame(width: 30, height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.gradient))
            .opacity(tab.isSleeping ? 0.5 : 1)
            .overlay { if selected { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.9), lineWidth: 1.5) } }
            .contentShape(Rectangle())
            .onTapGesture { model.select(tab) }
            .help(tab.displayTitle)
            .contextMenu { TabMenu(model: model, tab: tab) }
    }
}

private struct TopTab: View {
    let model: BrowserModel
    let tab: Tab
    let selected: Bool
    var namespace: Namespace.ID
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            TabIcon(tab: tab)
            Text(tab.displayTitle).lineLimit(1).foregroundStyle(tab.isPrivate ? Color.purple : Color.primary)
                .opacity(tab.isSleeping && !selected ? 0.6 : 1)
            Spacer(minLength: 0)
            if hovering || selected {
                Button { model.close(tab) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(IconButtonStyle(size: 18))
            }
        }
        .padding(.horizontal, 9).frame(height: 28)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.14)).matchedGeometryEffect(id: "sel", in: namespace)
            } else if hovering {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.25)) { model.select(tab) } }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(model: model, tab: tab) }
    }
}

struct TopToolbar: View {
    let model: BrowserModel

    var body: some View {
        HStack(spacing: 6) {
            NavButtons(tab: model.selectedTab)
            Spacer(minLength: 8)
            AddressPill(model: model).frame(maxWidth: 640)
            Spacer(minLength: 8)
            FlightButton(model: model)
            DownloadsButton(model: model)
            MoreMenu(model: model)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }
}

struct ToastLayer: View {
    let model: BrowserModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.toasts) { toast in
                HStack(spacing: 10) {
                    Image(systemName: toast.symbol).foregroundStyle(.tint)
                    Text(toast.text).font(.callout.weight(.medium))
                    if let title = toast.actionTitle, let action = toast.action {
                        Button(title) { action(); model.dismiss(toast) }
                            .buttonStyle(.plain).font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(!model.toasts.isEmpty)
    }
}
