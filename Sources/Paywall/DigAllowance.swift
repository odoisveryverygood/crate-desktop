import Foundation

/// Counts the orchestrator's one timed JEV/KW plan per accepted DIG.
/// Timeout diagnostics have no duration and must not consume a second DIG.
final class DigAllowance {
    static let countKey = "crate.paywall.digCount.v1"
    static let seenKey = "crate.paywall.seenPlans.v1"
    private let defaults: UserDefaults
    private(set) var count: Int
    private var seen: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        count = max(0, defaults.integer(forKey: Self.countKey))
        seen = Set(defaults.stringArray(forKey: Self.seenKey) ?? [])
    }

    /// Returns true only when this snapshot contains a new plan at/after DIG 3.
    func consume(_ log: [LogLine]) -> Bool {
        let plans = Set(log.filter {
            ($0.tag == "JEV" || $0.tag == "KW") && $0.ms != nil
        }.map { $0.id.uuidString })
        let added = plans.subtracting(seen).count
        // Only the threshold matters; cap the persisted counter.
        count = min(3, count + added)
        seen = plans
        defaults.set(count, forKey: Self.countKey)
        defaults.set(Array(seen), forKey: Self.seenKey)
        return added > 0 && count >= 3
    }
}
