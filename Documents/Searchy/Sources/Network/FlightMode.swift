import Foundation
import Observation

enum LiteLevel: Int, CaseIterable, Identifiable {
    case off, lite, textOnly
    var id: Int { rawValue }

    var title: String {
        switch self { case .off: "Off"; case .lite: "Lite"; case .textOnly: "Text only" }
    }
    var symbol: String {
        switch self { case .off: "bolt.horizontal"; case .lite: "leaf"; case .textOnly: "text.alignleft" }
    }
    var detail: String {
        switch self {
        case .off: "Pages load normally."
        case .lite: "No video, audio or web fonts, and nothing plays by itself. Typically cuts data use by half or more."
        case .textOnly: "Also drops images and embedded frames. Pages become fast, plain and tiny."
        }
    }
}

/// "Flight mode" for the web: when the connection is slow, metered or restricted (airplane wifi, hotel portals,
/// tethering) Searchy cuts what pages download and switches to saved copies.
@MainActor @Observable
final class FlightMode {
    static let shared = FlightMode()

    /// What the person chose.
    var level: LiteLevel { didSet { UserDefaults.standard.set(level.rawValue, forKey: "liteLevel"); changed(from: oldValue.rawValue == 0 ? effectiveBefore : nil) } }
    /// Let Searchy turn Lite mode on by itself when the network is poor.
    var auto: Bool { didSet { UserDefaults.standard.set(auto, forKey: "liteAuto"); networkChanged() } }
    /// Prefer saved copies of pages while offline or very slow.
    var preferOffline: Bool { didSet { UserDefaults.standard.set(preferOffline, forKey: "preferOffline") } }

    private(set) var autoEngaged = false
    private(set) var imageAllowedHosts: Set<String>
    @ObservationIgnored private var effectiveBefore: LiteLevel = .off

    private init() {
        let d = UserDefaults.standard
        level = LiteLevel(rawValue: d.integer(forKey: "liteLevel")) ?? .off
        auto = d.object(forKey: "liteAuto") as? Bool ?? true
        preferOffline = d.object(forKey: "preferOffline") as? Bool ?? true
        imageAllowedHosts = Set(d.stringArray(forKey: "liteImageHosts") ?? [])
        effectiveBefore = effective
    }

    var effective: LiteLevel { level != .off ? level : (auto && autoEngaged ? .lite : .off) }
    var isActive: Bool { effective != .off }

    /// Called by the network monitor whenever it learns something new.
    func networkChanged() {
        let n = NetworkMonitor.shared
        let poor = auto && (n.quality == .slow || n.quality == .restricted || n.isConstrained || n.isExpensive)
        let good = n.quality == .good && !n.isConstrained && !n.isExpensive
        let before = effective
        if poor, !autoEngaged {
            autoEngaged = true
            if level == .off {
                announce("\(n.quality == .restricted ? "Restricted network" : "Slow connection") — Lite mode is on to save data.", off: true)
            }
        } else if good, autoEngaged {
            autoEngaged = false
            if level == .off { announce("Connection looks good — Lite mode is off.", off: false) }
        }
        if effective != before { applyRules() }
        effectiveBefore = effective
    }

    private func changed(from _: LiteLevel?) {
        if effective != effectiveBefore { applyRules() }
        effectiveBefore = effective
    }

    private func applyRules() { Task { await ContentBlocker.shared.rebuildLite() } }

    private func announce(_ text: String, off: Bool) {
        BrowserRegistry.shared.frontmost?.toast(text, symbol: off ? "leaf.fill" : "bolt.fill", actionTitle: off ? "Turn Off" : nil) { [weak self] in
            self?.auto = false
        }
    }

    func setImagesAllowed(_ allowed: Bool, on host: String) {
        let k = HiddenElementStore.key(host)
        if allowed { imageAllowedHosts.insert(k) } else { imageAllowedHosts.remove(k) }
        UserDefaults.standard.set(Array(imageAllowedHosts).sorted(), forKey: "liteImageHosts")
        applyRules()
    }
}
