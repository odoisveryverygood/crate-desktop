import Foundation

struct LoopRequest {
    var sampleStyle: Style
    var drumStyle: Style
    var instrument: String = "any"
    var mood: String? = nil
    var bars: Int = 4
    var bpm: Double? = nil
    var excludeID: String? = nil
    /// What the prompt says it should sound like (Vibes.from(prompt)): plugg, jazzy, dark… weighted by CLAP scores.
    var vibes: [String] = []
}

/// Prompt words → the CLAP vibe tags in vibes.json (tools/tag_loop_vibes.py).
enum Vibes {
    static let words: [(String, String)] = [
        ("plugg", "plugg"), ("pluggnb", "plugg"), ("dreamy", "plugg"), ("rage", "rage"), ("opium", "rage"),
        ("dark", "darktrap"), ("evil", "darktrap"), ("menacing", "darktrap"), ("sinister", "darktrap"),
        ("rnb", "rnbtrap"), ("r&b", "rnbtrap"), ("melodic", "rnbtrap"), ("emotional", "sad"),
        ("jazz", "jazzy"), ("jazzy", "jazzy"), ("neo soul", "jazzy"), ("rhodes", "jazzy"),
        ("lofi", "lofi"), ("lo-fi", "lofi"), ("dusty", "lofi"), ("soul", "soul"), ("soulful", "soul"),
        ("jersey", "jerseyclub"), ("club", "jerseyclub"), ("garage", "garage"), ("2-step", "garage"), ("2 step", "garage"),
        ("y2k", "garage"), ("kpop", "kpop"), ("k-pop", "kpop"), ("pop", "kpop"), ("newjeans", "garage"),
        ("new jeans", "garage"), ("afro", "afro"), ("afrobeats", "afro"), ("amapiano", "afro"), ("house", "house"),
        ("bells", "bells"), ("bell", "bells"), ("music box", "bells"), ("ambient", "ambient"), ("airy", "ambient"),
        ("sad", "sad"), ("melancholic", "sad"), ("happy", "happy"), ("uplifting", "happy"), ("bright", "happy"),
    ]

    static func from(_ prompt: String) -> [String] {
        let t = prompt.lowercased()
        var out: [String] = []
        for (w, tag) in words where KeywordParser.has(w, t) && !out.contains(tag) { out.append(tag) }
        return out
    }
}

/// The chosen loop cut to the requested span and chopped onto 16 bank-B pads (see `Chopper`).
struct ChopSet {
    var loop: LoopEntry
    var spanBars: Int
    var spanSec: Double
    /// Pad-order chop starts (seconds in the file).
    var starts: [Double]
    var sounds: [Int: PadSound]
    /// One entry per bar of the span (nil = unknown chord).
    var chords: [ChordInfo?]
    var bassPerBeat: [Int?]
    var keyPC: Int?
    var keyMinor: Bool
    var rootNote: Int
    var chordsLabel: String
    /// What each pad's chop is (start step on the span's grid, length, energy, attack, chroma, hero rank...).
    var info: [Int: ChopFeature] = [:]
    /// The span's 16th grid (step 0 = the span's first downbeat).
    var grid: ChopGrid? = nil
    var mode: ChopMode = .find
}

/// Local retrieval over the analyzed library: no model, < 5 ms, seeded for DIG AGAIN variety.
enum Retrieval {
    static func slotCategory(_ slot: String) -> String { ["kick2": "kick", "hat2": "hat", "perc2": "perc"][slot] ?? slot }

    /// Style kit target nudged by Jev/keyword scores (vintage → dust, brightness → brightness, energy → punch).
    static func kitTarget(_ lib: LibraryStore, style: Style, vintage: Double?, brightness: Double?, energy: Double?) -> KitTarget {
        var t = lib.styleInfo(style).kit
        if let v = vintage { t.dust = t.dust * 0.55 + v * 0.45 }
        if let b = brightness { t.brightness = t.brightness * 0.55 + b * 0.45 }
        if let e = energy { t.punch = t.punch * 0.55 + e * 0.45 }
        return t
    }

    static func score(_ s: OneShot, style: Style, target t: KitTarget, rand: Double) -> Double {
        1.0 * s.style(style) + 0.35 * (1 - abs(s.dust - t.dust)) + 0.25 * (1 - abs(s.brightness - t.brightness))
            + 0.2 * (1 - abs(s.punch - t.punch)) + 0.08 * rand
    }

    /// Candidates of a category ranked best-first. `words` (prompt words) boost tag/name matches.
    static func ranked(_ lib: LibraryStore, category: String, style: Style, target: KitTarget,
                       rng: inout SeededRNG, words: [String] = []) -> [OneShot] {
        rankedScored(lib, category: category, style: style, target: target, rng: &rng, words: words).map(\.0)
    }

    /// Variety without losing quality: a seeded, rank-weighted pick among the top `top` candidates whose score is
    /// within `margin` of the best (so a clear winner still wins; near-ties rotate between digs).
    static func pickNearTop<T>(_ scored: [(T, Double)], rng: inout SeededRNG, top: Int = 4, margin: Double = 0.15) -> T? {
        guard let best = scored.first?.1 else { return nil }
        let pool = Array(scored.prefix(top).filter { $0.1 >= best - margin })
        let weights = [0.4, 0.27, 0.19, 0.14].prefix(pool.count)
        var r = rng.unit() * weights.reduce(0, +)
        for (i, w) in weights.enumerated() {
            r -= w
            if r <= 0 { return pool[i].0 }
        }
        return pool.last?.0
    }

    /// `ranked` with the scores, best first.
    static func rankedScored(_ lib: LibraryStore, category: String, style: Style, target: KitTarget,
                             rng: inout SeededRNG, words: [String] = []) -> [(OneShot, Double)] {
        var scored: [(OneShot, Double)] = []
        for s in lib.candidates(category) {
            var sc = score(s, style: style, target: target, rand: rng.unit())
            if !words.isEmpty {
                let hay = ((s.tags ?? []) + [s.name, s.source ?? ""]).joined(separator: " ").lowercased()
                for w in words where w.count >= 3 && hay.contains(w) { sc += 0.25 }
            }
            scored.append((s, sc))
        }
        scored.sort { $0.1 > $1.1 }
        return scored
    }

    static func padSound(_ s: OneShot, lib: LibraryStore) -> PadSound {
        let cat = Category(rawValue: s.category) ?? .perc
        var root = s.rootNote
        if root == nil, cat == .eight08 || cat == .bass { root = 36 }
        if root == nil, cat == .keys || cat == .synth { root = 60 }
        return PadSound(id: s.id, name: s.name.uppercased(), category: cat, fileURL: lib.fileURL(s.file),
                        rootNote: root, source: s.source ?? "")
    }

    /// Bank A: one sound per BankA slot; "2" slots get the runner-up (best unused).
    static func kit(_ lib: LibraryStore, style: Style, target: KitTarget, seed: UInt64) -> [Int: PadSound] {
        var rng = SeededRNG(seed: seed)
        var used = Set<String>()
        var out: [Int: PadSound] = [:]
        for (i, slot) in BankA.slots.enumerated() {
            let list = rankedScored(lib, category: slotCategory(slot), style: style, target: target, rng: &rng)
            let fresh = list.filter { !used.contains($0.0.id) }
            guard let pick = pickNearTop(fresh, rng: &rng) ?? list.first?.0 else { continue }
            used.insert(pick.id)
            out[i] = padSound(pick, lib: lib)
        }
        return out
    }

    /// Loop instruments that satisfy a requested instrument (nil = no filter).
    static func instrumentSet(_ inst: String) -> Set<String>? {
        switch inst {
        case "piano", "rhodes", "keys", "ep": return ["piano", "rhodes", "keys"]
        case "organ": return ["organ", "keys"]
        case "clav": return ["clav", "keys"]
        case "bell", "vibes": return ["bell", "vibes", "keys"]
        case "marimba", "steelpan", "pluck", "synth", "bass", "808": return [inst]
        case "horns", "horn", "sax", "flute", "trumpet", "brass": return ["sax", "flute", "horns"]
        case "guitar": return ["guitar"]
        case "strings": return ["strings"]
        case "pad": return ["pad"]
        case "break": return ["break"]
        case "vocal": return ["vocal"]
        default: return nil
        }
    }

    /// The loop for a new beat / sample: a seeded pick among the near-best few (not always #1, so the same kind of
    /// prompt doesn't always land on the same record).
    static func loop(_ lib: LibraryStore, _ req: LoopRequest, seed: UInt64) -> LoopEntry? {
        var rng = SeededRNG(seed: seed ^ 0x100F_100F)
        return pickNearTop(tempoFit(lib, req, scoredLoops(lib, req, seed: seed)), rng: &rng, top: 4, margin: 0.15)
    }

    /// The beat plays at the loop's tempo, so a stated tempo ("NewJeans" = 136) or a club style's range is a hard
    /// filter when enough loops fit (a great-sounding 64 BPM loop must not turn a Jersey club beat into 64 BPM).
    static func tempoFit(_ lib: LibraryStore, _ req: LoopRequest, _ scored: [(LoopEntry, Double)]) -> [(LoopEntry, Double)] {
        let range: ClosedRange<Double>
        if let want = req.bpm {
            let exact = scored.filter { abs($0.0.bpm - want) < 0.01 }
            if !exact.isEmpty { return exact }
            range = (want - 5)...(want + 5)
        } else {
            let r = lib.styleInfo(req.drumStyle).bpmRange
            let pad: Double = [.house, .trap, .drill, .jerseyclub, .garage, .afrobeats, .kpop].contains(req.drumStyle) ? 4 : 8
            range = (r.lowerBound - pad)...(r.upperBound + pad)
        }
        let fit = scored.filter { range.contains($0.0.bpm) }
        return fit.count >= 2 ? fit : scored
    }

    /// Every candidate loop for the request, best first (the same scoring `loop` picks its winner by).
    static func rankedLoops(_ lib: LibraryStore, _ req: LoopRequest, seed: UInt64) -> [LoopEntry] {
        scoredLoops(lib, req, seed: seed).map(\.0)
    }

    static func scoredLoops(_ lib: LibraryStore, _ req: LoopRequest, seed: UInt64) -> [(LoopEntry, Double)] {
        var rng = SeededRNG(seed: seed ^ 0xA5A5_5A5A)
        var pool = lib.loops
        if let set = instrumentSet(req.instrument) {
            let exact = pool.filter { $0.instrument == req.instrument }
            let f = exact.isEmpty ? pool.filter { set.contains($0.instrument) } : exact
            if !f.isEmpty { pool = f }
        } else {
            let f = pool.filter { $0.instrument != "break" } // "any" = a melodic sample, not a drum break
            if !f.isEmpty { pool = f }
        }
        if let ex = req.excludeID, pool.count > 1 { pool.removeAll { $0.id == ex } }
        let range = lib.styleInfo(req.drumStyle).bpmRange
        let hipHop: Set<Style> = [.dilla, .jazzhop, .boombap, .lofi, .vintage]
        var scored: [(LoopEntry, Double)] = []
        for l in pool {
            var s = 1.0 * l.style(req.sampleStyle)
            if let m = req.mood { s += 0.3 * ((l.moods ?? []).contains(m) ? 1 : 0) }
            let fit: Double
            if let want = req.bpm {
                fit = max(0, 1 - abs(l.bpm - want) / 12)
            } else if range.contains(l.bpm) {
                fit = 1
            } else {
                let d = l.bpm < range.lowerBound ? range.lowerBound - l.bpm : l.bpm - range.upperBound
                fit = max(0, 1 - d / 15)
            }
            s += 0.3 * fit
            if req.bpm == nil, hipHop.contains(req.drumStyle), !(80...100).contains(l.bpm) { s -= 0.2 }
            s += 0.1 * (l.keyConfidence ?? 0)
            // How it actually sounds (CLAP): a plugg prompt wants loops that score high for plugg, not just "trap".
            if !req.vibes.isEmpty, let v = lib.vibes[l.id] {
                s += 0.45 * req.vibes.map { min(2.5, max(-2.5, v[$0] ?? 0)) }.reduce(0, +) / Double(req.vibes.count)
            }
            let cpb = l.chordsPerBar ?? []
            if !cpb.isEmpty { s += 0.1 * Double(cpb.compactMap { $0 }.count) / Double(cpb.count) } // chords feed the bass + lid
            s += 0.1 * (l.bars >= req.bars ? 1 : 0)
            if l.instrument == req.instrument { s += 0.35 } // an explicitly named instrument beats its neighbours
            s += 0.08 * rng.unit()
            scored.append((l, s))
        }
        // Stable: equal scores keep pool order, so the first of them wins as before.
        return scored.enumerated().sorted { a, b in a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset }
            .map(\.element)
    }

    /// The span of a loop that gets chopped: its first `requested` bars (the whole loop if it's shorter).
    static func span(_ loop: LoopEntry, bars requested: Int) -> (bars: Int, sec: Double) {
        let span = max(1, min(requested, loop.bars))
        var spanSec: Double
        if span >= loop.bars {
            spanSec = loop.durationSec
        } else if let beats = loop.beatsSec, beats.count > span * 4 {
            spanSec = beats[span * 4]
        } else {
            spanSec = Double(span) * loop.secondsPerBar
        }
        return (span, min(max(spanSec, 0.1), loop.durationSec))
    }

    /// A library loop's 16th grid: its analysed beats (else its bpm) from 0 s.
    static func grid(_ loop: LoopEntry) -> ChopGrid {
        let beats = (loop.beatsSec ?? []).filter { $0.isFinite }
        let step = 60 / max(1, loop.bpm) / 4
        if beats.count >= 4, (beats.first ?? 1) < 0.05 { return ChopGrid(origin: 0, stepSec: step, beats: beats) }
        return ChopGrid(origin: 0, stepSec: step)
    }

    /// The first `bars` of the loop chopped onto 16 pads: FIND by default (cuts on note boundaries, heroes on pads
    /// 1–8; see `Chopper`). `seed` ≠ 0 re-rolls; `keep` = favourite pads that stay as they are.
    static func chops(_ loop: LoopEntry, lib: LibraryStore, bars requested: Int, mode: ChopMode = .find, seed: UInt64 = 0,
                      keep: [Int: PadSound] = [:]) -> ChopSet {
        let (span, spanSec) = self.span(loop, bars: requested)
        let url = lib.fileURL(loop.file)
        let grid = self.grid(loop)
        let spanSteps = span * 16
        let need = mode == .slice8 ? min(loop.durationSec, grid.time(Double(2 * spanSteps)) + 0.05) : spanSec + 0.05
        var info: [Int: ChopFeature] = [:]
        if let sig = try? ChopSignal.load(url: url, start: 0, duration: need) {
            info = Chopper.chop(sig, grid: grid, spanSteps: spanSteps, mode: mode == .song ? .find : mode, seed: seed,
                                keep: keep.mapValues { ($0.start, $0.end ?? loop.durationSec) })
        }
        let key = Music.parseKey(loop.key)
        let root = 60 + (key?.pc ?? 0)
        let short = loop.name.split(separator: " ").first.map(String.init) ?? "CHOP"
        var sounds: [Int: PadSound] = keep
        if info.count + keep.count < 8 {
            // Unreadable audio: the old equal slicing.
            info = [:]
            let starts = equalStarts(loop, spanSec: spanSec, span: span)
            for i in 0..<16 where keep[i] == nil {
                info[i] = ChopFeature(start: starts[i], end: i < 15 ? starts[i + 1] : spanSec, step: i * span, steps: span)
            }
        }
        let tag = mode == .find && seed == 0 ? "" : "~\(mode.rawValue)"
        for (i, c) in info where keep[i] == nil {
            sounds[i] = PadSound(id: "\(loop.id)#\(i)\(tag)@\(Int((c.start * 1000).rounded()))", name: "\(short) \(i + 1)",
                                 category: .chop, fileURL: url, start: c.start, end: c.end, rootNote: root,
                                 source: loop.source ?? loop.name)
        }
        let cpb = loop.chordsPerBar ?? []
        let chords: [ChordInfo?] = (0..<span).map { b in b < cpb.count ? ChordInfo.parse(cpb[b]) : nil }
        let bpb = Array((loop.bassPerBeat ?? []).prefix(span * 4))
        var names: [String] = []
        for c in chords.compactMap({ $0?.symbol }) where names.last != c { names.append(c) }
        let label = names.isEmpty ? (loop.key ?? "") : names.joined(separator: "–")
        let starts = (0..<16).map { sounds[$0]?.start ?? 0 }
        return ChopSet(loop: loop, spanBars: span, spanSec: spanSec, starts: starts, sounds: sounds, chords: chords,
                       bassPerBeat: bpb, keyPC: key?.pc, keyMinor: key?.minor ?? true, rootNote: root, chordsLabel: label,
                       info: info, grid: grid, mode: mode)
    }

    /// The old chop: 16 equal slices of the span, each snapped to an analysed onset within 40 ms (the analysed
    /// `slices16Sec` when the span is the whole loop). The fallback, and the "before" in tools/chop-harness.
    static func equalStarts(_ loop: LoopEntry, spanSec: Double, span: Int) -> [Double] {
        var starts: [Double]
        if span >= loop.bars, let s16 = loop.slices16Sec, s16.count == 16 {
            starts = s16
        } else {
            let onsets = loop.onsetsSec ?? []
            starts = (0..<16).map { i in
                let t = Double(i) * spanSec / 16
                if let near = onsets.min(by: { abs($0 - t) < abs($1 - t) }), abs(near - t) <= 0.04 { return near }
                return t
            }
        }
        for i in 1..<16 where starts[i] <= starts[i - 1] { starts[i] = starts[i - 1] + 0.005 }
        return starts
    }

    /// Bank C: 0 = bass (808 for trap/drill), 1 = keys, 2 = synth, 3 = 808 alt.
    static func bankC(_ lib: LibraryStore, style: Style, target: KitTarget, seed: UInt64) -> [Int: PadSound] {
        var rng = SeededRNG(seed: seed ^ 0xC0C0_C0C0)
        var out: [Int: PadSound] = [:]
        let bassCat = [.trap, .drill, .jerseyclub].contains(style) ? "808" : "bass"
        let bass = ranked(lib, category: bassCat, style: style, target: target, rng: &rng).first
            ?? ranked(lib, category: "808", style: style, target: target, rng: &rng).first
        if let b = bass { out[0] = padSound(b, lib: lib) }
        if ChordWriter.midiStyles.contains(style), let stab = chordStab(lib) {
            out[1] = stab
        } else if let k = ranked(lib, category: "keys", style: style, target: target, rng: &rng).first {
            out[1] = padSound(k, lib: lib)
        }
        if let s = ranked(lib, category: "synth", style: style, target: target, rng: &rng).first { out[2] = padSound(s, lib: lib) }
        if let alt = ranked(lib, category: "808", style: style, target: target, rng: &rng).first(where: { $0.id != bass?.id }) {
            out[3] = padSound(alt, lib: lib)
        }
        return out
    }

    /// Single-note keys one-shots for MIDI chord stabs, pitch measured offline (librosa pyin median and CQT peak agree;
    /// the pack's rootNote tag is an octave off for KY08). Chord one-shots are excluded: they'd stack into mud.
    static let chordStabs: [(id: String, root: Int)] = [("KY08", 72), ("KY06", 63)] // Rhodes C5, vibraphone Eb4

    static func chordStab(_ lib: LibraryStore) -> PadSound? {
        let pool = lib.candidates("keys") + lib.candidates("synth")
        for (id, root) in chordStabs {
            guard let s = pool.first(where: { $0.id == id }) else { continue }
            var ps = padSound(s, lib: lib)
            ps.rootNote = root
            return ps
        }
        return nil
    }

    /// Best library match for a single-sound request (category from Jev `route` or keywords).
    /// The best match for a described sound; `exclude` (what's on the pad now) is skipped so asking again changes it.
    static func single(_ lib: LibraryStore, category: String, style: Style, prompt: String, seed: UInt64,
                       exclude: String? = nil) -> PadSound? {
        var rng = SeededRNG(seed: seed ^ 0x51_51)
        let words = prompt.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let target = lib.styleInfo(style).kit
        return ranked(lib, category: category, style: style, target: target, rng: &rng, words: words)
            .first { $0.id != exclude }
            .map { padSound($0, lib: lib) }
    }
}
