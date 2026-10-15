import Foundation

/// MUTE, MPC style (Track / Pad Mute): a muted pad is skipped by the sequencer, so it drops out of the beat right
/// away; hitting it live still plays it (a pad that makes no sound under your finger feels broken). Mutes are a
/// performance state, not an edit: no UNDO step, not written into the pattern, saved with the project.
enum BankMute { case none, some, all }

extension AppState {
    func isMuted(_ pad: PadID) -> Bool { mutedPads.contains(pad) }

    /// `.all` = every pad on the bank that has a sound is muted (an empty bank counts all 16).
    func bankMute(_ bank: Bank) -> BankMute {
        let pads = (0..<16).map { PadID(bank, $0) }
        let muted = pads.filter { mutedPads.contains($0) }
        if muted.isEmpty { return .none }
        let loaded = pads.filter { sound($0) != nil }
        let all = loaded.isEmpty ? muted.count == 16 : loaded.allSatisfy { mutedPads.contains($0) }
        return all ? .all : .some
    }

    func toggleMute(_ pad: PadID) {
        var m = mutedPads
        if m.contains(pad) { m.remove(pad) } else { m.insert(pad) }
        setMutes(m)
        DebugLog.event("mute", ["pad": pad.key, "on": m.contains(pad), "count": m.count])
    }

    /// The whole bank: fully muted → unmute all 16, otherwise mute all 16.
    func toggleMute(bank: Bank) {
        let mute = bankMute(bank) != .all
        var m = mutedPads.filter { $0.bank != bank }
        if mute { for i in 0..<16 { m.insert(PadID(bank, i)) } }
        setMutes(m)
        DebugLog.event("mute", ["bank": bank.letter, "on": mute, "count": m.count])
    }

    /// The one place mutes change: the UI state and the engine stay in step.
    func setMutes(_ pads: Set<PadID>) {
        if pads != mutedPads { mutedPads = pads }
        engine.setMuted(pads)
    }
}
