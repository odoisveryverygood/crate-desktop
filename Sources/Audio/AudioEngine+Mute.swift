import Foundation

extension AudioEngine {
    /// MUTE: the sequencer skips these pads (and a muted pad stops choking others). Hits of a newly muted pad that are
    /// already scheduled inside the look-ahead are cancelled, so the mute is heard at once. Live hits still play.
    func setMuted(_ pads: Set<PadID>) {
        q.async {
            let added = pads.subtracting(self.mutedQ)
            self.mutedQ = pads
            guard !added.isEmpty else { return }
            let now = Clock.now()
            for v in self.allVoices where !v.live && v.startAt > now + 0.002 {
                if let p = v.pad, added.contains(p) { self.cancel(v) }
            }
        }
    }
}
