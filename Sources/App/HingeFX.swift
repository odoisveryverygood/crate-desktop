import Foundation

/// Maps the hinge angle to the punch-in FX amount; snapping the hinge open fires the DROP.
/// Laptop/book rest angle ≈ 110°+ → no FX. Folding toward 65° ramps filter/crush/reverb up to a breakdown.
final class HingeFX {
    private let state: AppState
    var restAngle: Double = 110
    /// Full FX at 65°. Which display the app is on is the system's call (RootView follows the window size).
    var closedAngle: Double = 65
    private var lastDrop = Date.distantPast
    /// Hinge events right after launch (the simulator can start folded) must not fire a DROP.
    private let born = Date()

    init(state: AppState) { self.state = state }

    /// Closed (outer screen) → no FX, no DROP: closing the phone must never mute the beat.
    func released() {
        wasHigh = false
        leftHighAt = nil
        if state.punch != 0 { state.punch = 0; state.engine.setPunch(0) }
    }

    func update(angle: Double) {
        state.hingeAngle = angle
        var p = min(1, max(0, (restAngle - angle) / (restAngle - closedAngle)))
        if p < 0.04 { p = 0 }   // resting jitter around 110° is not an FX move
        apply(p)
    }

    private var wasHigh = false
    private var leftHighAt: Date?

    /// Also used by the PAD FX slider fallback on non-hinge devices.
    /// DROP = the punch goes from > 0.6 to < 0.1 within 0.45 s of starting to open (a snap), regardless of how
    /// long it was held folded (hinge events only arrive while it moves).
    func apply(_ p: Double) {
        let now = Date()
        if p > 0.6 {
            wasHigh = true
            leftHighAt = nil
        } else if wasHigh && leftHighAt == nil {
            leftHighAt = now
        }
        if p < 0.1, wasHigh, let t = leftHighAt {
            let fast = now.timeIntervalSince(t) < 0.45
            wasHigh = false
            leftHighAt = nil
            if fast, now.timeIntervalSince(lastDrop) > 1.0, now.timeIntervalSince(born) > 2.0 {
                lastDrop = now
                state.punch = 0
                state.engine.drop()
                state.addLog("DROP", "snap open", tint: .orange)
                DebugLog.event("drop", ["source": "hinge"])
                return
            }
        }
        guard abs(p - state.punch) > 0.005 || p == 0 || p == 1 else { return }
        state.punch = p
        state.engine.setPunch(p)
    }
}
