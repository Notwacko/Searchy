import WebKit

/// Chrome-extension support (WKWebExtension). Filled in by the extensions milestone.
@MainActor
final class ExtensionManager {
    static let shared = ExtensionManager()
    private init() {}

    func attach(to config: WKWebViewConfiguration) {}
}
