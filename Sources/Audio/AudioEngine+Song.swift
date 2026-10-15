import Foundation

// SONG mode cueing: swap a pattern in on the next bar line and carry on from a chosen bar there (the song's start, a
// section's ▶, or back to the loop). The plain `.nextBar` swap keeps the absolute step count, so a 36-bar song
// swapped in after 13 bars of a 4-bar loop would start at bar 14; this lands it exactly where it was asked to.

extension AudioEngine {
    func setPattern(_ p: Pattern, fromBar bar: Int) {
        stateLock.withLock {
            shared.pattern = p
            shared.startBar = max(0, bar)
            shared.cue = shared.playing ? (max(0, bar), .infinity) : nil
        }
        q.async { self.cueOnQ(p, bar: max(0, bar)) }
    }

    /// The bar a SONG cue in flight lands on (nil when none is waiting or its downbeat has passed).
    func cuedBar() -> Int? {
        stateLock.withLock {
            guard let c = shared.cue, Clock.now() < c.until else { return nil }
            return c.bar
        }
    }

    /// Stopped: `p` now (PLAY starts at `bar`). Counting in: `p` now and the take starts at `bar`. Playing: `p` waits
    /// for the next bar line that isn't scheduled yet, and the timeline continues there from `bar`'s downbeat.
    func cueOnQ(_ p: Pattern, bar: Int) {
        let c = CompiledPattern(p)
        guard playingQ else {
            active = c
            pending = nil
            cueWaiting = false
            stateLock.withLock { shared.cue = nil }
            logPatternApplied(c)
            return
        }
        if nextStep < startStepQ {
            active = c
            pending = nil
            cueWaiting = false
            stateLock.withLock { shared.cue = nil }
            logPatternApplied(c)
            jumpOnQ(toBar: bar)
            return
        }
        pending = c
        cueWaiting = true
        let total = c.total
        let at = (nextStep + 15) / 16 * 16
        let target = (bar * 16) % total
        let to = at + (((target - at) % total) + total) % total
        pendingJump = (at, to)
        let until = stepTime(at) + 0.05
        stateLock.withLock { shared.cue = (bar, until) }
        DebugLog.event("song_cue", ["bar": bar + 1, "at": at, "to": to, "bars": p.bars,
                                    "in_ms": Int(((stepTime(at) - Clock.now()) * 1000).rounded())])
    }
}
