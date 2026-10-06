import SwiftUI

@main
struct SearchyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        _ = WebEngine.shared
    }

    var body: some Scene {
        WindowGroup(id: "main") { WindowRoot() }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1280, height: 820)
            .commands { BrowserCommands() }

        Settings { SettingsView() }
    }
}

/// Creates a window's model exactly once (the first window restores the saved session).
@MainActor
private final class ModelHolder {
    lazy var model = BrowserModel(restore: BrowserRegistry.shared.isEmpty)
}

private struct WindowRoot: View {
    @State private var holder = ModelHolder()
    var body: some View { RootView(model: holder.model) }
}
