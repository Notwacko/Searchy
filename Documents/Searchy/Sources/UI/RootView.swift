import SwiftUI

struct RootView: View {
    @Bindable var model: BrowserModel
    private let prefs = Preferences.shared

    var body: some View {
        ZStack {
            Backdrop(space: model.activeSpace)
            Group {
                if prefs.tabLayout == .sidebar { SidebarLayout(model: model) } else { TopLayout(model: model) }
            }
            NetworkBanner(model: model)
            if model.palette.isOpen { CommandBar(model: model) }
            ToastLayer(model: model)
        }
        .animation(.smooth(duration: 0.28), value: model.palette.isOpen)
        .frame(minWidth: 760, minHeight: 480)
        .containerBackground(.thinMaterial, for: .window)
        .background(WindowAccessor { window in
            window.applySearchyChrome()
            model.attach(window: window)
        })
        .focusedSceneValue(\.browser, model)
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .bookmarks: BookmarksSheet(model: model)
            case .history: HistorySheet(model: model)
            case .memory: MemorySheet(model: model)
            case .offline: OfflineSheet(model: model)
            case .flightPrep: FlightPrepSheet(model: model)
            case .doctor: NetworkDoctorSheet(model: model)
            case .routes: RoutesSheet(model: model)
            default: ComingSoonSheet(title: "Not available yet")
            }
        }
        .sheet(item: $model.spaceEditor) { request in SpaceEditor(model: model, request: request) }
    }
}

/// A soft wash of the active space's color behind the glass.
struct Backdrop: View {
    let space: SpaceModel

    var body: some View {
        LinearGradient(colors: [space.info.color.color.opacity(0.22), space.info.color.color.opacity(0.04)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
            .animation(.smooth(duration: 0.5), value: space.info.color)
            .allowsHitTesting(false)
    }
}

struct SidebarLayout: View {
    let model: BrowserModel
    private let prefs = Preferences.shared

    var body: some View {
        HStack(spacing: 0) {
            if model.sidebarVisible {
                SidebarView(model: model)
                    .frame(width: prefs.sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                SidebarResizer()
            }
            VStack(spacing: 0) {
                if !model.sidebarVisible { CompactBar(model: model) }
                ContentCard(model: model)
                    .padding(.top, model.sidebarVisible ? 8 : 0)
                    .padding(.leading, model.sidebarVisible ? 0 : 8)
                    .padding(.trailing, 8).padding(.bottom, 8)
            }
        }
        .overlay(alignment: .leading) {
            if !model.sidebarVisible { PeekSidebar(model: model) }
        }
    }
}

/// With the sidebar folded away, touching the left edge slides it back over the page.
struct PeekSidebar: View {
    let model: BrowserModel
    private let prefs = Preferences.shared

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear.frame(width: 7).contentShape(Rectangle())
                .onHover { if $0 { withAnimation(.smooth(duration: 0.28)) { model.sidebarPeeking = true } } }
            if model.sidebarPeeking {
                SidebarView(model: model, floating: true)
                    .frame(width: prefs.sidebarWidth)
                    .padding(.bottom, 8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .padding(8)
                    .shadow(color: .black.opacity(0.25), radius: 24, x: 6)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .onHover { inside in
                        if !inside { Task { try? await Task.sleep(for: .milliseconds(350))
                            withAnimation(.smooth(duration: 0.28)) { model.sidebarPeeking = false } } }
                    }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct SidebarResizer: View {
    @State private var startWidth: Double?

    var body: some View {
        Color.clear.frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = startWidth ?? Preferences.shared.sidebarWidth
                    startWidth = start
                    Preferences.shared.sidebarWidth = min(380, max(200, start + value.translation.width))
                }
                .onEnded { _ in startWidth = nil })
    }
}

struct TopLayout: View {
    let model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            if model.sidebarVisible {
                TopTabStrip(model: model)
                TopToolbar(model: model)
            } else {
                CompactBar(model: model)
            }
            ContentCard(model: model)
                .padding(.horizontal, 8).padding(.bottom, 8)
        }
    }
}

struct ComingSoonSheet: View {
    let title: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.headline)
            Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(30).frame(width: 320)
    }
}
