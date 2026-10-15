import Foundation
import Observation

/// The user's two privacy choices, persisted in UserDefaults:
/// - **AI consent** (App Review 5.1.2(i)): typed / spoken requests and a short description of the beat go to OpenAI and
///   TypeSafe (directly with Mac personal keys, otherwise through CRATE's server) only after "Allow" on the one-time sheet (`AIConsentSheet`). "Not now" keeps the AI
///   on the device (keyword parser + instant beat). Changeable later in the projects sheet.
/// - **Usage analytics** (first-party, default on): off = nothing is queued or uploaded and the queue is cleared.
@Observable
final class PrivacyChoices {
    static let shared = PrivacyChoices()

    enum AIConsent: String { case unknown, allowed, declined }

    private static let aiKey = "crateAIConsent"
    private static let analyticsKey = "crateAnalyticsOn"

    var aiConsent: AIConsent {
        didSet { UserDefaults.standard.set(aiConsent.rawValue, forKey: Self.aiKey) }
    }
    var analyticsOn: Bool {
        didSet {
            UserDefaults.standard.set(analyticsOn, forKey: Self.analyticsKey)
            if !analyticsOn { Analytics.shared.clearQueue() }
        }
    }
    /// The consent sheet is up (RootView presents it).
    var asking = false
    /// Requests waiting on the sheet's answer; they run either way (local-only after "Not now").
    @ObservationIgnored private var pending: [() -> Void] = []

    private init() {
        let d = UserDefaults.standard
        aiConsent = AIConsent(rawValue: d.string(forKey: Self.aiKey) ?? "") ?? .unknown
        analyticsOn = d.object(forKey: Self.analyticsKey) as? Bool ?? true
    }

    /// Thread-safe reads for the network clients (JevClient / OpenAIClient / Analytics run off the main thread).
    static var aiAllowed: Bool { UserDefaults.standard.string(forKey: aiKey) == AIConsent.allowed.rawValue }
    static var analyticsAllowed: Bool { UserDefaults.standard.object(forKey: analyticsKey) as? Bool ?? true }

    /// Run `action` (an AI request) once the user has answered the consent sheet; asks first if they never did.
    func beforeAI(_ action: @escaping () -> Void) {
        guard aiConsent == .unknown else { action(); return }
        pending.append(action)
        asking = true
    }

    func answer(allow: Bool) {
        aiConsent = allow ? .allowed : .declined
        asking = false
        Analytics.shared.track("ai_consent", ["allow": allow])
        let run = pending
        pending = []
        run.forEach { $0() }
    }
}
