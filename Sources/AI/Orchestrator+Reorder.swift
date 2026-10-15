import Foundation

/// "put kick snare hat hat on the bottom row" / "swap pad 1 and 5": rearranges bank A.
/// Sounds, the running pattern and the slot map (BankA.slots, so later kits land in the same places) all move together.
extension Orchestrator {
    /// Spoken drum names → BankA slot lanes (first and second mention).
    private static let drumWords: [(words: [String], first: String, second: String)] = [
        (["kick", "kicks", "bd"], "kick", "kick2"),
        (["snare", "snares", "snr", "sd"], "snare", "clap"),
        (["clap", "claps"], "clap", "snare"),
        (["openhat", "ohat", "open"], "openhat", "hat2"),
        (["hat", "hats", "hihat", "hihats", "hh", "closedhat"], "hat", "openhat"),
        (["rim", "rimshot"], "rim", "rim"),
        (["perc", "percussion", "conga", "bongo"], "perc", "perc2"),
        (["shaker", "shakers"], "shaker", "shaker"),
        (["crash", "cymbal", "ride"], "cymbal", "cymbal"),
        (["808", "sub"], "808", "808"),
    ]

    /// New slot order for bank A, or nil when the prompt isn't a layout request.
    static func reorderRequest(_ prompt: String) -> [String]? {
        let p = prompt.lowercased()
            .replacingOccurrences(of: "open hat", with: "openhat")
            .replacingOccurrences(of: "hi-hat", with: "hihat")
            .replacingOccurrences(of: "hi hat", with: "hihat")
            .replacingOccurrences(of: "closed hat", with: "closedhat")
        let intent = ["reorder", "rearrange", "re-order", "swap", "layout", "bottom row", "bottom rack", "first row",
                      "move the", "put the", "put kick", "on the left", "order the", "arrange the pads", "pad order"]
        guard intent.contains(where: { p.contains($0) }) else { return nil }
        let words = p.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var order = BankA.slots

        // "swap pad 1 and 5" / "swap 3 with 9"
        if p.contains("swap") {
            let nums = words.compactMap(Int.init).filter { (1...16).contains($0) }
            if nums.count >= 2 { order.swapAt(nums[0] - 1, nums[1] - 1); return order }
        }
        // Named drums in the order spoken → pads 1, 2, 3 … (left to right, bottom row first)
        var wanted: [String] = []
        for w in words {
            guard let d = drumWords.first(where: { $0.words.contains(w) }) else { continue }
            let lane = wanted.contains(d.first) ? d.second : d.first
            if !wanted.contains(lane) { wanted.append(lane) }
        }
        guard !wanted.isEmpty else { return nil }
        let rest = order.filter { !wanted.contains($0) }
        order = wanted + rest
        return order
    }

    /// Moves every bank-A sound, lane and note to the pad its slot now lives on.
    func applyPadOrder(_ newSlots: [String]) async {
        let old = BankA.slots
        guard newSlots.count == old.count, Set(newSlots) == Set(old), newSlots != old else {
            state.addLog("PADS", "already in that order", tint: .grey)
            return
        }
        leaveSong()
        // oldIndex → newIndex
        var map: [Int: Int] = [:]
        for (i, lane) in old.enumerated() { if let j = newSlots.firstIndex(of: lane) { map[i] = j } }
        func move(_ pad: PadID) -> PadID { pad.bank == .a ? PadID(.a, map[pad.index] ?? pad.index) : pad }
        func remap(_ p: Pattern) -> Pattern {
            var q = p
            q.lanes = Dictionary(p.lanes.map { (move($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
            q.late = Dictionary(p.late.map { (move($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
            q.notes = Dictionary(p.notes.map { (move($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
            return q
        }

        var sounds: [Int: PadSound] = [:]
        for i in 0..<16 { if let s = state.sound(PadID(.a, i)), let j = map[i] { sounds[j] = s } }
        BankA.setSlots(newSlots)
        do { try await state.engine.loadBank(.a, sounds: sounds) } catch {
            state.addLog("PADS", "× couldn't move pads", tint: .red)
            return
        }
        for i in 0..<16 { state.sounds[PadID(.a, i)] = sounds[i] }
        let p = remap(state.engine.pattern)
        lastPattern = remap(lastPattern)
        state.engine.setPattern(p, timing: .now)
        if state.selectedPad.bank == .a { state.selectedPad = move(state.selectedPad) }
        let names = (0..<4).map { UIHelpers.bankANames[$0] }.joined(separator: " · ")
        state.addLog("PADS", "bottom row → \(names)", tint: .orange)
        DebugLog.event("pad_order", ["slots": newSlots.joined(separator: ",")])
    }
}
