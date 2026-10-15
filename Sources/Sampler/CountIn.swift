import Foundation

/// ● REC from stop: one bar of count-in clicks, then play + record. The engine runs the count-in on its own clock:
/// the clicks are scheduled like steps of the bar before the loop (in the engine graph, after the master tap, so they
/// are never bounced), the loop's downbeat lands exactly one bar after the first click, and recording is armed the
/// whole time, so a hit played a hair before the downbeat still lands on step 1. This class only mirrors the beats
/// left into the UI (`tick`) and reports the downbeat (`done`).
@MainActor
final class CountIn {
    static let shared = CountIn()
    private(set) var isCounting = false

    /// `tick(n)` on each click (n = beats left, 4…1), then `done()` on the downbeat; `cancelled()` if the transport
    /// stopped first (STOP, PLAY/PAUSE, a project switch …). Restarting replaces the last one.
    func start(_ state: AppState, beats: Int = 4, tick: @escaping (Int) -> Void, done: @escaping () -> Void,
               cancelled: @escaping () -> Void) {
        isCounting = true
        let engine = state.engine
        engine.onCountIn = { [weak self] n in
            guard let self, self.isCounting else { return }
            if n > 0 {
                tick(n)
            } else {
                self.isCounting = false
                if n == 0 { done() } else { cancelled() }
            }
        }
        engine.setRecording(true)   // armed through the count-in (the REC key lights on the downbeat)
        engine.play(countIn: beats)
        state.isPlaying = true
        DebugLog.event("count_in", ["bpm": engine.bpm, "beats": beats, "fromBar": engine.startBar + 1,
                                    "click": engine.metronome])
        if !(engine is AudioEngine) {   // previews: no clock to count with
            isCounting = false
            done()
        }
    }

    func cancel() {
        isCounting = false
    }
}
