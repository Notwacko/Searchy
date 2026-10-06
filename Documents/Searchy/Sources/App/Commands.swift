import SwiftUI

struct BrowserCommands: Commands {
    @FocusedValue(\.browser) private var browser
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // File
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { browser?.newTabWithPalette() }.keyboardShortcut("t")
            Button("New Window") { openWindow(id: "main") }.keyboardShortcut("n")
            Button("New Private Tab") { browser?.newPrivateTab() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Space…") {
                browser?.spaceEditor = SpaceEditorRequest(info: SpaceInfo(name: "New Space", symbol: "star.fill", color: .purple), isNew: true)
            }
            Divider()
            Button("Open Location…") { browser?.openPalette(prefill: browser?.selectedTab?.url?.absoluteString ?? "") }.keyboardShortcut("l")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { browser?.closeSelectedTab() }.keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w", modifiers: [.command, .shift])
            Button("Reopen Closed Tab") { browser?.reopenClosedTab() }.keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Print…") { browser?.printPage() }.keyboardShortcut("p")
        }

        // Edit → Find
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find in Page…") { browser?.showFind() }.keyboardShortcut("f")
            Button("Copy Link") { browser?.copyLink() }.keyboardShortcut("c", modifiers: [.command, .shift])
        }

        // View
        CommandGroup(replacing: .sidebar) {
            Button("Show/Hide Sidebar") { browser?.toggleSidebar() }.keyboardShortcut("s")
            Button(Preferences.shared.tabLayout == .sidebar ? "Tabs Across the Top" : "Tabs in the Sidebar") {
                Preferences.shared.tabLayout = Preferences.shared.tabLayout == .sidebar ? .top : .sidebar
            }
        }

        CommandMenu("Page") {
            Button("Reload") { browser?.selectedTab?.reload() }.keyboardShortcut("r")
            Button("Reload Without Cache") { browser?.selectedTab?.reload(fromOrigin: true) }.keyboardShortcut("r", modifiers: [.command, .option])
            Button("Stop") { browser?.selectedTab?.stop() }.keyboardShortcut(".")
            Divider()
            Button("Back") { browser?.selectedTab?.goBack() }.keyboardShortcut("[")
            Button("Forward") { browser?.selectedTab?.goForward() }.keyboardShortcut("]")
            Divider()
            Button("Reading Mode") { browser?.selectedTab?.toggleReader() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Hide Element…") { browser?.selectedTab?.togglePicker() }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Floating Video") { browser?.selectedTab?.toggleFloatingVideo() }.keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button("Zoom In") { browser?.selectedTab?.zoomIn() }.keyboardShortcut("+")
            Button("Zoom Out") { browser?.selectedTab?.zoomOut() }.keyboardShortcut("-")
            Button("Actual Size") { browser?.selectedTab?.zoomReset() }.keyboardShortcut("0")
        }

        CommandMenu("Tabs") {
            Button("Pin/Unpin Tab") { if let t = browser?.selectedTab { browser?.togglePin(t) } }.keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            Button("Next Tab") { browser?.cycleTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { browser?.cycleTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab") { browser?.cycleTab(1) }.keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { browser?.cycleTab(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            ForEach(1...9, id: \.self) { n in
                Button("Tab \(n)") { browser?.selectTab(number: n) }.keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
        }

        CommandMenu("Spaces") {
            Button("Next Space") { browser?.cycleSpace(1) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous Space") { browser?.cycleSpace(-1) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Divider()
            ForEach(1...6, id: \.self) { n in
                Button("Space \(n)") { browser?.switchSpace(number: n) }.keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.command, .option])
            }
        }

        CommandGroup(after: .toolbar) {
            Button("Show Bookmarks") { browser?.sheet = .bookmarks }.keyboardShortcut("b", modifiers: [.command, .option])
            Button("Show History") { browser?.sheet = .history }.keyboardShortcut("y")
            Button("Tab Memory…") { browser?.sheet = .memory }.keyboardShortcut("m", modifiers: [.command, .option])
            Button("Show Downloads") { browser?.downloadsPopoverShown.toggle() }.keyboardShortcut("l", modifiers: [.command, .option])
            Button("Bookmark This Page") {
                if let t = browser?.selectedTab, let u = t.url { BookmarkStore.shared.toggle(url: u, title: t.displayTitle); browser?.toast("Bookmark updated", symbol: "star.fill") }
            }.keyboardShortcut("d")
        }

        CommandMenu("Flight") {
            Button("Save Page for Offline") { Task { await browser?.selectedTab?.saveForOffline() } }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Prepare for Flight…") { browser?.sheet = .flightPrep }
            Button("Saved Pages") { browser?.sheet = .offline }.keyboardShortcut("o", modifiers: [.command, .option])
            Divider()
            Button("Lite Mode") { FlightMode.shared.level = FlightMode.shared.level == .lite ? .off : .lite }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Text-Only Mode") { FlightMode.shared.level = FlightMode.shared.level == .textOnly ? .off : .textOnly }
            Divider()
            Button("Network Doctor…") { browser?.sheet = .doctor }
        }

        CommandMenu("Develop") {
            Button("Inspect Element") { browser?.selectedTab?.webView?.showInspector(console: false) }.keyboardShortcut("i", modifiers: [.command, .option])
            Button("Show JavaScript Console") { browser?.selectedTab?.webView?.showInspector(console: true) }.keyboardShortcut("j", modifiers: [.command, .option])
        }
    }
}
