import AppKit

/// `SEARCHY_HEADLESS=1` runs a fully working instance that is invisible: no Dock icon, no menu bar, a transparent
/// off-screen-to-the-eye window that never takes focus. Used by automated tests so they don't flash on the user's screen.
enum Headless {
    static let isOn = ProcessInfo.processInfo.environment["SEARCHY_HEADLESS"] == "1"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if Headless.isOn { NSApp.setActivationPolicy(.accessory) }
    }

    private var memoryPressure: DispatchSourceMemoryPressure?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG || SEARCHY_BRIDGE
        DebugBridge.start()
        #endif
        // When macOS is short on memory, put idle tabs to sleep instead of letting the system swap.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak source] in
            let critical = source?.data.contains(.critical) ?? false
            MainActor.assumeIsolated {
                for model in BrowserRegistry.shared.models { model.sleepIdleTabs(olderThan: critical ? 0 : 60) }
            }
        }
        source.resume()
        memoryPressure = source

        NetworkMonitor.shared.onRecovered = {
            for model in BrowserRegistry.shared.models { model.resumeStalledTabs() }
        }
        NetworkMonitor.shared.start()

        // Hand startup's freed allocations back, and again whenever the app goes to the background.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { MainActor.assumeIsolated { MemoryManager.relieve() } }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MemoryManager.relieve() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        BrowserRegistry.shared.primary?.saveSessionNow()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model = BrowserRegistry.shared.frontmost else { return }
        for url in urls { model.open(url, inNewTab: true) }
        if !Headless.isOn { NSApp.activate() }
    }
}
