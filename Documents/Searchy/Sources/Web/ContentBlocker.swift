import Foundation
import WebKit
import CryptoKit
import os

/// Builds and caches the WebKit content rule lists:
///  • `ads`    — network-level blocking of ad/tracker requests (plus a few cosmetic rules)
///  • `hidden` — "hide anything" selectors, per site
/// Lists are compiled once and persisted by WebKit, so later launches just look them up.
@MainActor
final class ContentBlocker {
    static let shared = ContentBlocker()

    private(set) var adList: WKContentRuleList?
    private(set) var hiddenList: WKContentRuleList?
    private(set) var liteList: WKContentRuleList?
    /// Called after either list changed, so live tabs can swap rules.
    var onChange: ((_ old: [WKContentRuleList], _ new: [WKContentRuleList]) -> Void)?

    /// True once the first compile/lookup has finished. Tabs hold their first load until then,
    /// so nothing slips past the blocker at launch.
    private(set) var isReady = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReady() async {
        if isReady { return }
        Task { await warmUp() }   // first page load kicks off the (cached) lookup
        await withCheckedContinuation { waiters.append($0) }
    }

    private let store = WKContentRuleListStore.default()!
    private let log = Logger(subsystem: "app.searchy", category: "blocker")
    private var warming = false

    var activeLists: [WKContentRuleList] {
        var out: [WKContentRuleList] = []
        if Preferences.shared.blockAds, let adList { out.append(adList) }
        if let hiddenList { out.append(hiddenList) }
        if let liteList, FlightMode.shared.isActive { out.append(liteList) }
        return out
    }

    func warmUp() async {
        guard !warming else { return }
        warming = true
        let before = activeLists
        async let ads: Void = rebuildAds()
        async let hidden: Void = rebuildHidden()
        async let lite: Void = rebuildLite()
        _ = await (ads, hidden, lite)
        warming = false
        onChange?(before, activeLists)
        isReady = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func rebuildAds() async {
        let before = activeLists
        let json = Self.adRulesJSON(allowlist: SiteSettings.shared.adsAllowed)
        adList = await compile(json, prefix: "searchy.ads")
        if !warming { onChange?(before, activeLists) }
    }

    /// Data-saving rules for the current Lite level; nil when Lite is off.
    func rebuildLite() async {
        let before = activeLists
        let level = FlightMode.shared.effective
        if level == .off { liteList = nil }
        else { liteList = await compile(Self.liteRulesJSON(level: level, allowImages: FlightMode.shared.imageAllowedHosts), prefix: "searchy.lite") }
        if !warming { onChange?(before, activeLists) }
    }

    func rebuildHidden() async {
        let before = activeLists
        let rules = HiddenElementStore.shared.rules
        guard !rules.isEmpty else {
            hiddenList = nil
            if !warming { onChange?(before, activeLists) }
            return
        }
        var json = Self.hiddenRulesJSON(rules)
        var list = await compile(json, prefix: "searchy.hidden")
        if list == nil {
            // One bad selector would poison the whole list — keep only the ones WebKit accepts.
            json = await Self.onlyValid(rules: rules, store: store)
            list = await compile(json, prefix: "searchy.hidden")
        }
        hiddenList = list
        if !warming { onChange?(before, activeLists) }
    }

    // MARK: Compilation

    private func compile(_ json: String, prefix: String) async -> WKContentRuleList? {
        let digest = SHA256.hash(data: Data(json.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let id = "\(prefix).\(digest)"
        if let existing = try? await store.contentRuleList(forIdentifier: id) { return existing }
        do {
            let list = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json)
            await removeStale(prefix: prefix, keep: id)
            return list
        } catch {
            log.error("Rule list \(prefix, privacy: .public) failed to compile: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func removeStale(prefix: String, keep: String) async {
        guard let ids = await store.availableIdentifiers() else { return }
        for id in ids where id.hasPrefix(prefix + ".") && id != keep {
            try? await store.removeContentRuleList(forIdentifier: id)
        }
    }

    // MARK: Rule generation

    nonisolated static func adRulesJSON(allowlist: Set<String>) -> String {
        var rules: [[String: Any]] = []
        for domain in BlockLists.domains {
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            rules.append([
                "trigger": ["url-filter": "^[a-z]+://([a-z0-9-]+\\.)*\(escaped)[/:]", "load-type": ["third-party"]],
                "action": ["type": "block"],
            ])
        }
        for pattern in BlockLists.scriptPatterns {
            rules.append(["trigger": ["url-filter": pattern, "resource-type": ["script"]], "action": ["type": "block"]])
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": BlockLists.cosmetic.joined(separator: ", ")],
        ])
        if !allowlist.isEmpty {
            // Must live in the same list: ignore-previous-rules only reaches rules before it.
            rules.append([
                "trigger": ["url-filter": ".*", "if-domain": allowlist.sorted().map { "*" + $0 }],
                "action": ["type": "ignore-previous-rules"],
            ])
        }
        return encode(rules)
    }

    nonisolated static func liteRulesJSON(level: LiteLevel, allowImages: Set<String>) -> String {
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*", "resource-type": ["media", "font"]], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*", "resource-type": ["ping"], "load-type": ["third-party"]], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": "video, audio, [autoplay]"]],
        ]
        if level == .textOnly {
            rules += [
                ["trigger": ["url-filter": ".*", "resource-type": ["image", "svg-document"]], "action": ["type": "block"]],
                ["trigger": ["url-filter": ".*", "resource-type": ["document"], "load-type": ["third-party"]], "action": ["type": "block"]],
                ["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": "picture, iframe, canvas"]],
            ]
        }
        if !allowImages.isEmpty {
            rules.append(["trigger": ["url-filter": ".*", "resource-type": ["image", "svg-document"], "if-domain": allowImages.sorted().map { "*" + $0 }],
                          "action": ["type": "ignore-previous-rules"]])
        }
        return encode(rules)
    }

    nonisolated static func hiddenRulesJSON(_ rules: [String: [String]]) -> String {
        encode(rules.sorted { $0.key < $1.key }.compactMap { host, selectors in
            guard !selectors.isEmpty else { return nil }
            return [
                "trigger": ["url-filter": ".*", "if-domain": ["*" + host]],
                "action": ["type": "css-display-none", "selector": selectors.joined(separator: ", ")],
            ]
        })
    }

    private static func onlyValid(rules: [String: [String]], store: WKContentRuleListStore) async -> String {
        var good: [String: [String]] = [:]
        for (host, selectors) in rules {
            for selector in selectors {
                let probe = hiddenRulesJSON([host: [selector]])
                if (try? await store.compileContentRuleList(forIdentifier: "searchy.probe", encodedContentRuleList: probe)) != nil {
                    good[host, default: []].append(selector)
                }
            }
        }
        try? await store.removeContentRuleList(forIdentifier: "searchy.probe")
        return hiddenRulesJSON(good)
    }

    private nonisolated static func encode(_ rules: [[String: Any]]) -> String {
        guard !rules.isEmpty, let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            // WebKit rejects an empty list; a harmless rule keeps compilation valid.
            return #"[{"trigger":{"url-filter":"^https://searchy\\.invalid/"},"action":{"type":"block"}}]"#
        }
        return s
    }
}
