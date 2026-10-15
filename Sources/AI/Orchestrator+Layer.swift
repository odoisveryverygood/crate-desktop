import Foundation

/// Surgical edits: add one part on top ("add a sax line", "add a shaker") or change one lane's density ("more hats").
/// Nothing outside the named part changes: no new kit, no new sample, no GPT rewrite of the other parts.
extension Orchestrator {
    /// A melodic loop layered over the beat (chopped onto free pads, played as pitched notes in the beat's key).
    struct Layer {
        var loopID: String
        var name: String
        var bank: Bank
        var pads: [Int]
        var instrument: String? = nil
    }

    func addLayer(_ plan: Plan, seed: UInt64, variant: Int, report: inout DigReport) async {
        if plan.instrument == "any", let cat = plan.category {
            addDrumLayer(cat, plan: plan, seed: seed)
        } else {
            await addLoopLayer(plan, seed: seed, variant: variant, report: &report)
        }
    }

    // MARK: melodic layer

    func addLoopLayer(_ plan: Plan, seed: UInt64, variant: Int, report: inout DigReport) async {
        guard let s = session else { return }
        let bars = lastPattern.bars
        // The layer's bank: D, unless D holds an imported song's chops (then B, which an import leaves empty).
        let keepAnother = KeywordParser.hasAny(["another", "second", "extra"], plan.prompt.lowercased())
        let replacing = keepAnother ? nil : s.activeLayers.last(where: {
            ($0.instrument ?? library.loop(id: $0.loopID)?.instrument) == plan.instrument
        })
        let preferred: Bank = chopBank == .d ? .b : .d
        let options = replacing.map { [$0.bank] } ?? [preferred, .c]
        guard let bank = options.first(where: { availableLayerPads($0, replacing: replacing).count >= 4 }) else {
            state.addLog("ERR", "no room for another layer · remove a part or undo", tint: .red)
            return
        }
        let pads = availableLayerPads(bank, replacing: replacing)
        guard pads.count >= 4 else {
            state.addLog("ERR", "bank \(bank.letter) is full · remove a part first", tint: .red)
            return
        }
        let n = 4 // one bar per pad leaves room for four independent parts in the free bank
        let exclude = Set([s.chops?.loop.id].compactMap { $0 } + s.activeLayers.map(\.loopID))
        let req = LoopRequest(sampleStyle: plan.sampleStyle ?? s.sampleStyle, drumStyle: s.drumStyle, instrument: plan.instrument,
                              mood: plan.mood, bars: bars, bpm: state.bpm, excludeID: nil, vibes: Vibes.from(plan.prompt))
        let ranked = Retrieval.rankedLoops(library, req, seed: seed).filter { !exclude.contains($0.id) }
        let key = Music.parseKey(state.scaleKey)
        // Re-rank the top candidates by how far they'd have to be pitched and stretched to sit in this beat.
        let scored = ranked.prefix(12).enumerated().map { i, l -> (LoopEntry, Int, Double) in
            let shift = Self.keyShift(from: Music.parseKey(l.key), to: key)
            let tempo = abs(l.bpm - state.bpm) / max(state.bpm, 1)
            return (l, shift, Double(i) * 0.15 + Double(abs(shift)) * 0.35 + tempo * 6)
        }.sorted { $0.2 < $1.2 }
        guard !scored.isEmpty else {
            state.addLog("ERR", "no \(plan.instrument) loop in the crates", tint: .red)
            return
        }
        let (loop, shift, _) = scored[variant % scored.count]
        let chops = Retrieval.chops(loop, lib: library, bars: min(bars, loop.bars, 4))
        var sounds = currentBank(bank)
        // A layer plays the loop through, so it's cut into n equal parts of the span at the chopper's nearest cuts
        // (FIND CHOPS puts heroes on pads 1–8, so pad order isn't time order).
        let cuts = chops.sounds.values.map(\.start).sorted()
        guard let proto = chops.sounds.values.min(by: { $0.start < $1.start }) else { return }
        let starts = (0..<n).map { k -> Double in
            let t = Double(k) * chops.spanSec / Double(n)
            return cuts.min { abs($0 - t) < abs($1 - t) }.flatMap { abs($0 - t) < 0.06 ? $0 : nil } ?? t
        }
        for k in 0..<n {
            var snd = proto
            snd.id = "\(loop.id)#L\(k)"
            snd.start = starts[k]
            snd.end = k + 1 < n ? starts[k + 1] : chops.spanSec
            snd.name = "\(Self.layerTag(plan.instrument)) \(k + 1)"
            snd.gain = 0.8
            sounds[pads[k]] = snd
        }
        let tL = Date()
        report.loadMs = await loadBanks([(bank, sounds)])
        report.loopID = loop.id
        var p = lastPattern
        if let old = replacing { for i in old.pads { p.lanes[PadID(old.bank, i)] = nil; p.notes[PadID(old.bank, i)] = nil } }
        let span = chops.spanBars, slot = Double(span * 16) / Double(n)
        let midi = chops.rootNote + shift
        var rep = 0
        while rep * span * 16 < bars * 16 {
            for k in 0..<n {
                let step = rep * span * 16 + Int((Double(k) * slot).rounded())
                guard step < bars * 16 else { break }
                p.notes[PadID(bank, pads[k]), default: []].append(NoteEvent(step: step, length: slot, midi: midi, velocity: 92))
            }
            rep += 1
        }
        var ns = s
        let layer = Layer(loopID: loop.id, name: loop.name, bank: bank, pads: Array(pads.prefix(n)), instrument: loop.instrument)
        ns.layers = s.activeLayers.filter { $0.loopID != replacing?.loopID || $0.bank != replacing?.bank || $0.pads != replacing?.pads }
        ns.layers.append(layer)
        ns.layer = layer
        session = ns
        apply(p, bpm: nil, swing: nil)
        state.selectedPad = PadID(bank, pads[0])
        let pitch = shift == 0 ? "in key" : String(format: "%+d st to %@", shift, state.scaleKey ?? "key")
        state.addLog("LAYER", "+ \(loop.name) · \(loop.instrument) on \(bank.letter)\(pads[0] + 1)… · \(pitch)", ms: Self.ms(tL),
                     tint: .blue)
        DebugLog.event("layer", ["loop": loop.id, "instrument": loop.instrument, "bank": bank.letter, "pads": n, "shift": shift,
                                 "loopBpm": loop.bpm, "bpm": state.bpm])
    }

    /// Hold a pad, "add a clean guitar sound here": one bar of a matching library loop on that pad, pitched into the
    /// beat's key when played from KEYS. Nothing else changes.
    func padLoop(_ plan: Plan, pad: PadID, seed: UInt64, variant: Int, report: inout DigReport) async {
        let s = session
        let req = LoopRequest(sampleStyle: plan.sampleStyle ?? s?.sampleStyle ?? .jazzhop, drumStyle: s?.drumStyle ?? .boombap,
                              instrument: plan.instrument, mood: plan.mood, bars: 1, bpm: state.bpm, excludeID: nil, vibes: Vibes.from(plan.prompt))
        let current = state.sound(pad)?.id.split(separator: "#").first.map(String.init)
        let ranked = Retrieval.rankedLoops(library, req, seed: seed).filter { $0.id != current }
        guard !ranked.isEmpty else {
            state.addLog("ERR", "no \(plan.instrument) in the crates", tint: .red)
            return
        }
        let loop = ranked[variant % min(ranked.count, 6)]
        let chops = Retrieval.chops(loop, lib: library, bars: 1)
        guard var snd = chops.sounds.values.min(by: { $0.start < $1.start }) else { return }
        snd.start = 0
        snd.end = chops.spanSec
        snd.name = "\(Self.layerTag(loop.instrument)) \(loop.name.split(separator: " ").first ?? "")"
        snd.id = "\(loop.id)#bar"
        var bank = currentBank(pad.bank)
        bank[pad.index] = snd
        report.loadMs = await loadBanks([(pad.bank, bank)])
        report.loopID = loop.id
        state.bank = pad.bank
        state.selectedPad = pad
        state.engine.trigger(pad, velocity: 110, semitones: 0)
        state.addLog("PAD", "\(pad.bank.letter)\(pad.number) ← \(loop.name) · 1 bar of \(loop.instrument) · \(loop.key ?? "?")",
                     ms: report.loadMs, tint: .blue)
    }

    /// Pads in `bank` a layer may use: empty, or not playing in the beat, or the previous layer's own pads.
    func layerPads(_ bank: Bank) -> [Int] {
        availableLayerPads(bank, replacing: session?.layer)
    }

    /// Leave existing parts and playable bass/keys intact when adding another layer.
    func availableLayerPads(_ bank: Bank, replacing: Layer?) -> [Int] {
        let pat = lastPattern
        let own = Set(replacing?.bank == bank ? replacing?.pads ?? [] : [])
        return (0..<16).filter { i in
            let pad = PadID(bank, i)
            if own.contains(i) { return true }
            if bank == .c && i < 4 { return false }
            if let sound = state.sound(pad), !sound.id.contains("#L") { return false }
            let used = !(pat.lanes[pad]?.isEmpty ?? true) || !(pat.notes[pad]?.isEmpty ?? true)
            return !used
        }
    }

    func currentBank(_ bank: Bank) -> [Int: PadSound] {
        var out: [Int: PadSound] = [:]
        for i in 0..<16 { if let s = state.sound(PadID(bank, i)) { out[i] = s } }
        return out
    }

    /// Semitones (−5…+6) that move a loop's key onto the beat's key, comparing relative majors (Am ≡ C).
    static func keyShift(from: (pc: Int, minor: Bool)?, to: (pc: Int, minor: Bool)?) -> Int {
        guard let f = from, let t = to else { return 0 }
        let a = f.minor ? (f.pc + 3) % 12 : f.pc
        let b = t.minor ? (t.pc + 3) % 12 : t.pc
        var d = (b - a + 12) % 12
        if d > 6 { d -= 12 }
        return d
    }

    static func layerTag(_ instrument: String) -> String {
        ["horns": "SAX", "sax": "SAX", "flute": "FLUTE", "piano": "PNO", "rhodes": "RHDS", "keys": "KEYS", "guitar": "GTR", "strings": "STR", "pad": "PAD",
         "vibes": "VIBE", "vocal": "VOX", "break": "BRK"][instrument] ?? "LAYR"
    }

    // MARK: drum layer

    /// "add a shaker": a lane on that slot (its kit sound, or a fresh one if the slot is empty). Other lanes don't move.
    func addDrumLayer(_ cat: String, plan: Plan, seed: UInt64) {
        guard let pad = BankA.pad(forLane: cat) else {
            state.addLog("ERR", "no \(cat) slot", tint: .red)
            return
        }
        var p = lastPattern
        if !(p.lanes[pad]?.isEmpty ?? true) {
            // Already playing: "add a shaker" with a shaker in the beat means more of it.
            var more = plan
            more.direction = 1
            more.category = cat
            laneEdit(more)
            return
        }
        if state.sound(pad) == nil, let snd = Retrieval.single(library, category: Retrieval.slotCategory(cat),
                                                                 style: session?.drumStyle ?? .boombap, prompt: plan.prompt, seed: seed) {
            var bank = currentBank(.a)
            bank[pad.index] = snd
            Task { _ = await self.loadBanks([(.a, bank)]) }
        }
        p.lanes[pad] = Self.layerLane(cat, bars: p.bars, house: session?.drumStyle == .house)
        apply(p, bpm: nil, swing: nil)
        state.selectedPad = pad
        state.addLog("SEQ", "+ \(cat.uppercased()) lane · \(state.sound(pad)?.name ?? cat) · nothing else changed", tint: .orange)
    }

    /// A simple idiomatic part for a drum slot that wasn't playing.
    static func layerLane(_ cat: String, bars: Int, house: Bool) -> [Hit] {
        var hits: [Hit] = []
        for b in 0..<bars {
            let o = b * 16
            switch cat {
            case "shaker":
                for s in stride(from: 0, to: 16, by: 2) { hits.append(Hit(step: o + s, velocity: s % 4 == 2 ? 78 : 58)) }
                for s in [3, 11] { hits.append(Hit(step: o + s, velocity: 44)) }
            case "hat":
                for s in stride(from: 0, to: 16, by: 2) { hits.append(Hit(step: o + s, velocity: s % 4 == 0 ? 86 : 64)) }
            case "openhat":
                if house { for s in [2, 6, 10, 14] { hits.append(Hit(step: o + s, velocity: 84)) } }
                else { hits.append(Hit(step: o + 14, velocity: 82)) }
            case "cymbal":
                if b % 4 == 0 { hits.append(Hit(step: o, velocity: 100)) }
            case "rim":
                for s in [3, 10] { hits.append(Hit(step: o + s, velocity: 70)) }
            case "clap", "snare":
                for s in [4, 12] { hits.append(Hit(step: o + s, velocity: 96)) }
            case "kick", "kick2":
                for s in [0, 10] { hits.append(Hit(step: o + s, velocity: 110)) }
            case "texture", "vocal":
                if b % 2 == 0 { hits.append(Hit(step: o, velocity: 80)) }
            case "fx":
                if b == bars - 1 { hits.append(Hit(step: o, velocity: 90)) }
            default: // perc, tambourine, congas
                for s in [3, 7, 10, 14] { hits.append(Hit(step: o + s, velocity: s == 10 ? 76 : 60)) }
            }
        }
        return hits
    }

    // MARK: lane density

    /// "more hats" fills the gaps of that lane at half the spacing; "simpler kick" drops its weakest off-beat hits.
    func laneEdit(_ plan: Plan) {
        guard let cat = plan.category else { return }
        let pads = [cat, cat == "hat" ? "hat2" : cat == "kick" ? "kick2" : cat == "perc" ? "perc2" : ""]
            .compactMap(BankA.pad(forLane:))
        var p = lastPattern
        guard let pad = pads.first(where: { !(p.lanes[$0]?.isEmpty ?? true) }), let hits = p.lanes[pad] else {
            if plan.direction > 0 {
                var add = plan
                add.direction = 0
                addDrumLayer(cat, plan: add, seed: Self.fnv(plan.prompt))
            } else {
                state.addLog("SEQ", "\(cat.uppercased()) isn't in the beat", tint: .grey)
            }
            return
        }
        let before = hits.count
        p.lanes[pad] = plan.direction > 0 ? Self.denser(hits, total: p.totalSteps) : Self.sparser(hits)
        apply(p, bpm: nil, swing: nil)
        state.selectedPad = pad
        let after = p.lanes[pad]?.count ?? 0
        state.addLog("SEQ", "\(plan.direction > 0 ? "BUSIER" : "SIMPLER") \(cat.uppercased()) · \(before) → \(after) hits · nothing else changed",
                     tint: .orange)
        DebugLog.event("lane_edit", ["lane": cat, "dir": plan.direction, "before": before, "after": after])
    }

    static func denser(_ hits: [Hit], total: Int) -> [Hit] {
        let steps = Set(hits.map(\.step))
        let sorted = steps.sorted()
        // The lane's usual spacing (most common gap): 4 = quarters, 2 = 8ths, 1 = 16ths.
        var gaps: [Int: Int] = [:]
        for (a, b) in zip(sorted, sorted.dropFirst()) { gaps[b - a, default: 0] += 1 }
        let gap = gaps.max { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }?.key ?? 4
        let base = hits.map(\.velocity).max() ?? 90
        if gap <= 1 {
            // Already 16ths: hat rolls (ratchets) on the last beat of every other bar.
            return hits.map { h in var h = h; if h.step % 32 >= 28 { h.ratchet = 2 }; return h }
        }
        let grid = max(1, gap / 2)
        var out = hits
        for s in Swift.stride(from: 0, to: total, by: grid) where !steps.contains(s) {
            // Only fill between existing hits of the same bar region (don't invent hits in a silent bar).
            let bar = s / 16
            guard sorted.contains(where: { $0 / 16 == bar }) else { continue }
            out.append(Hit(step: s, velocity: Int(Double(base) * 0.62)))
        }
        return out.sorted { $0.step < $1.step }
    }

    static func sparser(_ hits: [Hit]) -> [Hit] {
        // Keep the beats (every 4th step); drop half of the rest, softest first.
        let off = hits.enumerated().filter { $0.element.step % 4 != 0 }.sorted { $0.element.velocity < $1.element.velocity }
        if off.isEmpty {
            // Only beat hits: keep 1 and 3.
            return hits.filter { $0.step % 8 == 0 }
        }
        let drop = Set(off.prefix(max(1, (off.count + 1) / 2)).map(\.offset))
        return hits.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }
}
