import Foundation
import Observation

/// Small per-site settings: page zoom and "allow ads here".
@MainActor @Observable
final class SiteSettings {
    static let shared = SiteSettings()

    private(set) var zoom: [String: Double]
    private(set) var adsAllowed: Set<String>
    private(set) var autoplayAllowed: Set<String>
    @ObservationIgnored var onAdAllowlistChange: (() -> Void)?

    private init() {
        let d = UserDefaults.standard
        zoom = d.dictionary(forKey: "siteZoom") as? [String: Double] ?? [:]
        adsAllowed = Set(d.stringArray(forKey: "adsAllowedHosts") ?? [])
        autoplayAllowed = Set(d.stringArray(forKey: "autoplayAllowedHosts") ?? [])
    }

    func zoom(for host: String?) -> Double { host.flatMap { zoom[HiddenElementStore.key($0)] } ?? 1.0 }

    func setZoom(_ value: Double, for host: String?) {
        guard let host else { return }
        let k = HiddenElementStore.key(host)
        if abs(value - 1) < 0.01 { zoom[k] = nil } else { zoom[k] = value }
        UserDefaults.standard.set(zoom, forKey: "siteZoom")
    }

    func adsAreAllowed(on host: String?) -> Bool { host.map { adsAllowed.contains(HiddenElementStore.key($0)) } ?? false }

    func setAdsAllowed(_ allowed: Bool, on host: String) {
        let k = HiddenElementStore.key(host)
        if allowed { adsAllowed.insert(k) } else { adsAllowed.remove(k) }
        UserDefaults.standard.set(Array(adsAllowed).sorted(), forKey: "adsAllowedHosts")
        onAdAllowlistChange?()
    }

    func autoplayIsAllowed(on host: String?) -> Bool {
        guard let host else { return false }
        let h = HiddenElementStore.key(host)
        return autoplayAllowed.contains(h) || WebEngine.autoplayHosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    func setAutoplayAllowed(_ allowed: Bool, on host: String) {
        let k = HiddenElementStore.key(host)
        if allowed { autoplayAllowed.insert(k) } else { autoplayAllowed.remove(k) }
        UserDefaults.standard.set(Array(autoplayAllowed).sorted(), forKey: "autoplayAllowedHosts")
    }
}
