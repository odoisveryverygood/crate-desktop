/// SwiftUI resets GestureState for both release and cancellation. Only onEnded commits a take.
struct SampleHoldState {
    private var holding = false
    private var ended = false

    mutating func begin() -> Bool {
        guard !holding else { return false }
        holding = true
        ended = false
        return true
    }

    mutating func finish() -> Bool {
        guard holding else { return false }
        ended = true
        return true
    }

    /// True means the gesture vanished without a normal end; discard rather than chop.
    mutating func reset() -> Bool {
        let cancelled = holding && !ended
        holding = false
        ended = false
        return cancelled
    }
}
