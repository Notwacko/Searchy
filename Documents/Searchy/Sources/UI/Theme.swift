import SwiftUI
import AppKit

extension SpaceColor {
    var color: Color {
        switch self {
        case .blue: Color(red: 0.22, green: 0.52, blue: 1.00)
        case .purple: Color(red: 0.62, green: 0.38, blue: 0.98)
        case .pink: Color(red: 1.00, green: 0.36, blue: 0.62)
        case .red: Color(red: 1.00, green: 0.30, blue: 0.30)
        case .orange: Color(red: 1.00, green: 0.58, blue: 0.16)
        case .yellow: Color(red: 0.98, green: 0.80, blue: 0.16)
        case .green: Color(red: 0.20, green: 0.78, blue: 0.40)
        case .teal: Color(red: 0.18, green: 0.74, blue: 0.80)
        case .graphite: Color(red: 0.55, green: 0.57, blue: 0.62)
        }
    }

    var title: String { rawValue.capitalized }
}

enum Metrics {
    static let cardRadius: CGFloat = 14
    static let rowHeight: CGFloat = 34
    static let tileSize: CGFloat = 46
    static let barHeight: CGFloat = 38
    /// Space reserved for the window's traffic lights.
    static let trafficLights: CGFloat = 78
}

extension Color {
    /// A stable, pleasant tint for a site, used by pinned letter tiles.
    static func tint(forHost host: String?) -> Color {
        guard let host, !host.isEmpty else { return .gray }
        var hash: UInt64 = 5381
        for b in host.utf8 { hash = (hash &* 33) &+ UInt64(b) }
        let hue = Double(hash % 360) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.82)
    }
}

/// A flat, borderless icon button with a soft hover state — the sidebar's workhorse.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.09 : 0)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Lets the window be dragged from empty chrome, and zooms it on double-click.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil) } else { super.mouseDown(with: event) }
        }
    }
}

/// Hands the hosting NSWindow to SwiftUI and gives it Searchy's chrome.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AccessorView()
        view.onWindow = onWindow
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class AccessorView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            guard let window else { return }
            DispatchQueue.main.async { [onWindow] in onWindow?(window) }
        }
    }
}

extension NSWindow {
    func applySearchyChrome() {
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        styleMask.insert(.fullSizeContentView)
        tabbingMode = .disallowed
        isMovableByWindowBackground = false
        minSize = NSSize(width: 760, height: 480)
        toolbar = nil
        if Headless.isOn {
            // Still a live, rendering window (WebKit needs one) — just invisible and unreachable.
            alphaValue = 0
            ignoresMouseEvents = true
            hasShadow = false
            collectionBehavior.insert([.stationary, .ignoresCycle, .transient])
            orderBack(nil)
        }
    }
}

/// Two-finger horizontal swipes over a region (trackpad only). Never steals clicks.
struct SwipeCatcher: NSViewRepresentable {
    var onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onSwipe = onSwipe
        return view
    }
    func updateNSView(_ nsView: CatcherView, context: Context) { nsView.onSwipe = onSwipe }

    final class CatcherView: NSView {
        var onSwipe: ((Int) -> Void)?
        nonisolated(unsafe) private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var fired = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                nonisolated(unsafe) let ev = event
                let consume = MainActor.assumeIsolated { self?.handle(ev) ?? false }
                return consume ? nil : event
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        /// Returns true when the event was a horizontal swipe we consumed.
        private func handle(_ event: NSEvent) -> Bool {
            guard event.window === window, event.hasPreciseScrollingDeltas, event.momentumPhase == [] else { return false }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return false }
            if event.phase.contains(.began) { accumulated = 0; fired = false }
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return false }
            accumulated += event.scrollingDeltaX
            if !fired, abs(accumulated) > 80 {
                fired = true
                onSwipe?(accumulated < 0 ? 1 : -1)
            }
            return true
        }
    }
}

extension View {
    func onSpaceSwipe(_ perform: @escaping (Int) -> Void) -> some View {
        background(SwipeCatcher(onSwipe: perform))
    }
}
