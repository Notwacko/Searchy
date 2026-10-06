import AppKit
import WebKit

/// WKWebView with Searchy's context-menu changes.
final class SearchyWebView: WKWebView {
    weak var tab: Tab?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            // WebKit says "window"; Searchy opens tabs.
            if item.title.contains("in New Window") { item.title = item.title.replacingOccurrences(of: "New Window", with: "New Tab") }
        }
        if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
        let hide = NSMenuItem(title: "Hide Element…", action: #selector(startPicker), keyEquivalent: "")
        hide.target = self
        hide.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
        menu.addItem(hide)
        let reader = NSMenuItem(title: "Reading Mode", action: #selector(toggleReader), keyEquivalent: "")
        reader.target = self
        reader.image = NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: nil)
        menu.addItem(reader)
    }

    @objc private func startPicker() { tab?.togglePicker() }
    @objc private func toggleReader() { tab?.toggleReader() }

    /// Let Searchy's own menu shortcuts win over web content for ⌘-combinations the page doesn't need.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        super.performKeyEquivalent(with: event)
    }

    // MARK: Developer tools

    /// Shows WebKit's inspector, optionally focused on the console (⌥⌘J).
    func showInspector(console: Bool) {
        let inspectorSel = NSSelectorFromString("_inspector")
        guard responds(to: inspectorSel), let inspector = perform(inspectorSel)?.takeUnretainedValue() as? NSObject else { return }
        let sel = NSSelectorFromString(console ? "showConsole" : "show")
        if inspector.responds(to: sel) { inspector.perform(sel) }
    }
}
