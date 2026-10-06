import Foundation
import Observation

/// CSS selectors the user has hidden, per site. Applied by the content blocker before the page paints.
@MainActor @Observable
final class HiddenElementStore {
    static let shared = HiddenElementStore()

    private(set) var rules: [String: [String]] = [:]
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let file = JSONFile<[String: [String]]>("HiddenElements.json")

    private init() { rules = file.load() ?? [:] }

    var totalCount: Int { rules.values.reduce(0) { $0 + $1.count } }

    func selectors(for host: String) -> [String] { rules[Self.key(host)] ?? [] }

    func add(_ selector: String, host: String) {
        let k = Self.key(host)
        guard !(rules[k] ?? []).contains(selector) else { return }
        rules[k, default: []].append(selector)
        changed()
    }

    func remove(_ selector: String, host: String) {
        let k = Self.key(host)
        rules[k]?.removeAll { $0 == selector }
        if rules[k]?.isEmpty == true { rules[k] = nil }
        changed()
    }

    func removeAll(host: String) {
        rules[Self.key(host)] = nil
        changed()
    }

    func removeEverything() { rules = [:]; changed() }

    static func key(_ host: String) -> String { host.lowercased().strippingWWW }

    private func changed() {
        file.save(rules)
        onChange?()
    }
}
