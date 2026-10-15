import Foundation

/// What each AI change touched, in musician words ("hats", "sample", "bass"), so every prompt reports
/// "Changed hats · kept kick, snare, sample" and can be rated 👍 / 👎 and tracked (Analytics).
extension Orchestrator {
    struct BeatState {
        var pattern: Pattern
        var sounds: [PadID: String]
        var bpm: Double
        var swing: Double
        var key: String?
    }

    func beatState() -> BeatState {
        var ids: [PadID: String] = [:]
        for b in Bank.allCases { for i in 0..<16 { let p = PadID(b, i); if let s = state.sound(p) { ids[p] = s.id + "\(s.start)" } } }
        return BeatState(pattern: lastPattern, sounds: ids, bpm: state.bpm, swing: state.swing, key: state.scaleKey)
    }

    /// Musician name for the part a pad plays in this beat.
    func partName(_ pad: PadID) -> String {
        switch pad.bank {
        case .a:
            let slot = pad.index < BankA.slots.count ? BankA.slots[pad.index] : "perc"
            return ["kick": "kick", "kick2": "kick", "snare": "snare", "clap": "clap", "hat": "hats", "hat2": "hats",
                    "openhat": "open hat", "rim": "rim", "perc": "perc", "perc2": "perc", "shaker": "shaker",
                    "cymbal": "cymbal", "808": "808", "fx": "fx", "vocal": "vocal", "texture": "texture"][slot] ?? slot
        case .b, .d:
            if let l = session?.activeLayers.first(where: { $0.bank == pad.bank && $0.pads.contains(pad.index) }) {
                return Self.layerTag(l.instrument ?? library.loop(id: l.loopID)?.instrument ?? "layer").lowercased() + " line"
            }
            if pad.bank == chopBank { return "sample" }
            return "pad \(pad.bank.letter)\(pad.number)"
        case .c:
            return pad.index == 0 ? "bass" : pad.index == 1 ? "keys" : "synth"
        }
    }

    private func lastLayerInstrument() -> String {
        guard let id = session?.layer?.loopID else { return "layer" }
        return library.loops.first { $0.id == id }?.instrument ?? "layer"
    }

    /// Parts that differ between two beat states, and parts still playing that didn't.
    func diff(_ a: BeatState, _ b: BeatState) -> (changed: [String], kept: [String]) {
        var changed: [String] = [], playing: [String] = []
        func add(_ list: inout [String], _ s: String) { if !list.contains(s) { list.append(s) } }
        let pads = Set(a.pattern.lanes.keys).union(b.pattern.lanes.keys).union(a.pattern.notes.keys).union(b.pattern.notes.keys)
            .union(a.sounds.keys).union(b.sounds.keys)
        for pad in pads.sorted(by: { ($0.bank.rawValue, $0.index) < ($1.bank.rawValue, $1.index) }) {
            let la = a.pattern.lanes[pad] ?? [], lb = b.pattern.lanes[pad] ?? []
            let na = a.pattern.notes[pad] ?? [], nb = b.pattern.notes[pad] ?? []
            let usedA = !la.isEmpty || !na.isEmpty, usedB = !lb.isEmpty || !nb.isEmpty
            let name = partName(pad)
            // A pad that isn't in the beat yet still counts when its sound changed ("B13 ← piano loop").
            guard usedA || usedB else {
                if a.sounds[pad] != b.sounds[pad], b.sounds[pad] != nil { add(&changed, "\(pad.bank.letter)\(pad.number) ← \(state.sound(pad)?.name ?? "new sound")") }
                continue
            }
            let soundChanged = a.sounds[pad] != b.sounds[pad] && (usedA || usedB)
            if la != lb || na != nb || soundChanged || a.pattern.late[pad] != b.pattern.late[pad] {
                add(&changed, !usedA ? "added \(name)" : usedB ? name : "removed \(name)")
            } else if usedB {
                add(&playing, name)
            }
        }
        if abs(a.bpm - b.bpm) > 0.4 { changed.append("tempo \(Int(b.bpm.rounded()))") }
        if abs(a.swing - b.swing) > 0.4 { changed.append("swing") }
        if a.pattern.bars != b.pattern.bars { changed.append("\(b.pattern.bars) bars") }
        if a.key != b.key, b.key != nil { changed.append("key \(b.key ?? "")") }
        // From an empty crate, everything is new: "New beat · kick, snare, hats, sample, bass".
        let wasEmpty = !a.pattern.lanes.values.contains { !$0.isEmpty } && !a.pattern.notes.values.contains { !$0.isEmpty }
        if wasEmpty, changed.contains(where: { $0.hasPrefix("added ") }) {
            let parts = changed.filter { $0.hasPrefix("added ") }.map { String($0.dropFirst(6)) }
            return (parts.isEmpty ? [] : ["new beat"] + parts, [])
        }
        let kept = playing.filter { p in !changed.contains(p) && !changed.contains("removed \(p)") && !changed.contains("added \(p)") }
        return (changed, kept)
    }

    /// Records (or updates) the change a prompt made and logs it for analytics.
    func recordChange(id: String, prompt: String, scope: String, before: BeatState, gpt: Bool = false, ms: Int? = nil) {
        let d = diff(before, beatState())
        let note = state.log.last?.text ?? ""
        let prev = AIChangeLog.shared.items.first { $0.id == id }
        var c = prev ?? AIChange(id: id, prompt: prompt, scope: scope, at: Date(), changed: [], kept: [], note: "")
        c.changed = d.changed
        c.kept = d.kept
        c.note = note
        c.gpt = gpt || (prev?.gpt ?? false)
        AIChangeLog.shared.record(c)
        var props: [String: Any] = ["change": id, "prompt": prompt, "scope": scope, "changed": d.changed, "kept": d.kept,
                                    "n_changed": d.changed.count, "bpm": Int(state.bpm.rounded())]
        if let ms { props["ms"] = ms }
        Analytics.shared.track(gpt ? "ai_gpt_applied" : "ai_applied", props)
    }

    // MARK: targeted requests (hold a pad / a bank and talk)

    /// "add a rusty drum here" on a held pad, "add some nujabes drums" on a held bank: the request only touches that pad /
    /// bank. Pads take a single library sound; banks map to the part that bank holds.
    func digTargeted(_ text: String, pad: PadID?, bank: Bank?) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // "I like that one", "nice", "keep it": a reaction, not a request. Nothing changes; it counts as a 👍.
        if Self.isPraise(t) {
            if let c = AIChangeLog.shared.latest { AIChangeLog.shared.rate(c.id, 1, reason: "said: \(t)") }
            state.addLog("👍", "kept it · \(t)", tint: .grey)
            Analytics.shared.track("voice_praise", ["text": t])
            return
        }
        Analytics.shared.track("voice_request", ["text": t, "pad": pad.map { "\($0.bank.letter)\($0.number)" } ?? "",
                                                 "bank": bank?.letter ?? ""])
        if let pad {
            state.selectedPad = pad
            state.bank = pad.bank
            forcedPad = pad
            defer { forcedPad = nil }
            await dig(KeywordParser.isAdd(t.lowercased()) || t.split(separator: " ").count > 1 ? "\(t) · this pad" : "\(t) this pad")
            return
        }
        guard let bank else { await dig(t); return }
        // "clear it", "empty this", "wipe the bank": that bank only (handleCommand reads forcedBank).
        let lw = t.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        if lw.contains(where: ["clear", "empty", "wipe", "reset", "erase", "delete", "remove"].contains) {
            forcedBank = bank
            defer { forcedBank = nil }
            await dig(t)
            return
        }
        switch bank {
        case .a: await dig(t.lowercased().contains("drum") ? t : "\(t) drums")
        case .b: await dig(session == nil ? t : "\(t) sample")
        case .c: await dig(t.lowercased().contains("bass") || t.lowercased().contains("keys") ? t : "\(t) bassline")
        case .d: await dig(session == nil ? t : "add \(t)")
        }
    }

    /// Short reactions that shouldn't change the beat.
    static func isPraise(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        guard t.split(separator: " ").count <= 6 else { return false }
        let change = ["but", "more", "less", "change", "add", "make", "swap", "another", "different", "instead", "no "]
        if change.contains(where: { t.contains($0) }) { return false }
        // "sick snare", "fire piano" name a sound: that's a request.
        if !KeywordParser.drumCategories(t).isEmpty || KeywordParser.instruments.contains(where: { KeywordParser.has($0.0, t) })
            || KeywordParser.hasAny(KeywordParser.drumWords + KeywordParser.melodicWords, t) { return false }
        let praise = ["i like", "like that", "love that", "love it", "nice", "keep it", "keep that", "perfect", "that's it",
                      "thats it", "good", "great", "sick", "fire", "dope", "yes", "yeah", "that one"]
        return praise.contains(where: { t.contains($0) })
    }
}
