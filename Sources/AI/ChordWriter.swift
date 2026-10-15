import Foundation

/// Rule-based chord stabs for MIDI-only beats (house): a classic deep-house progression in the key, voiced as
/// 3–4-note close voicings (MIDI 55–76, smooth voice leading), written as NoteEvents on bank C pad 1 (the keys
/// one-shot, polyphonic in the engine). Pure and instant; GPT may rewrite it via the arrangement's "chords".
enum ChordWriter {
    static let pad = PadID(.c, 1)
    /// Styles that get MIDI keys (no sample) when the prompt names no sample/instrument.
    static let midiStyles: Set<Style> = [.house]
    static let range = 55...76

    struct Chord {
        var symbol: String
        var pc: Int
        var minor: Bool
        var voicing: [Int]
    }

    struct Progression {
        var key: String       // "Am" / "C" (state.scaleKey format)
        var keyPC: Int
        var minor: Bool
        var chords: [Chord]   // one per bar
        var label: String { chords.map(\.symbol).joined(separator: "–") }
        var harmony: BassWriter.Harmony {
            BassWriter.Harmony(chords: chords.map { ChordInfo(pc: $0.pc, minor: $0.minor, symbol: $0.symbol) },
                               keyPC: keyPC, keyMinor: minor)
        }
    }

    /// Degree template relative to the minor tonic: (semitones, suffix, minor?, chord tones above the root).
    /// Deep house i9 – VImaj9 – IIImaj9 – VII6 (Am9–Fmaj9–Cmaj9–G6 in A minor / C major). Rootless voicings:
    /// the bass plays the roots.
    private static let deepHouse: [(Int, String, Bool, [Int])] = [
        (0, "m9", true, [3, 7, 10, 14]),
        (8, "maj9", false, [4, 7, 11, 14]),
        (3, "maj9", false, [4, 7, 11, 14]),
        (10, "6", false, [4, 7, 9, 12]),
    ]

    /// Progression for a key (nil = the style default, A minor). Major keys use their relative minor's progression.
    static func progression(style: Style, key: (pc: Int, minor: Bool)?) -> Progression {
        let k = key ?? (9, true)
        let tonic = k.minor ? k.pc : (k.pc + 9) % 12
        var chords: [Chord] = []
        var prev: [Int]? = nil
        for (deg, suffix, minor, tones) in deepHouse {
            let root = (tonic + deg) % 12
            let pcs = tones.map { (root + $0) % 12 }
            let v = place(pcs, after: prev)
            chords.append(Chord(symbol: Music.noteNames[root] + suffix, pc: root, minor: minor, voicing: v))
            prev = v
        }
        let keyName = Music.noteNames[k.pc] + (k.minor ? "m" : "")
        return Progression(key: keyName, keyPC: k.pc, minor: k.minor, chords: chords)
    }

    /// Close-position voicing of `pcs` inside 55–76, nearest to the previous chord (first chord centred on ~E4).
    static func place(_ pcs: [Int], after prev: [Int]?) -> [Int] {
        var best: [Int] = []
        var bestCost = Double.infinity
        var uniq: [Int] = []
        for p in pcs where !uniq.contains(p) { uniq.append(p) }
        guard !uniq.isEmpty else { return [] }
        for rot in 0..<uniq.count {
            let order = Array(uniq[rot...] + uniq[..<rot])
            for base in range.lowerBound...(range.lowerBound + 11) where base % 12 == order[0] {
                var v = [base]
                for pc in order.dropFirst() {
                    var m = v.last! + 1
                    while m % 12 != pc { m += 1 }
                    v.append(m)
                }
                guard let top = v.last, top <= range.upperBound else { continue }
                var cost: Double
                if let p = prev, p.count == v.count {
                    cost = zip(p, v).reduce(0) { $0 + Double(abs($1.0 - $1.1)) }
                    if p == v { cost += 16 } // same stab twice in a row sounds static: move it
                } else {
                    cost = abs(Double(v.reduce(0, +)) / Double(v.count) - 65.5)
                }
                if cost < bestCost { bestCost = cost; best = v }
            }
        }
        return best
    }

    /// House: offbeat 1/8 stabs (steps 2, 6, 10, 14) — the classic pumping deep-house chord.
    static func write(_ prog: Progression, bars: Int, style: Style) -> [NoteEvent] {
        guard !prog.chords.isEmpty else { return [] }
        let steps: [(Int, Double, Int)] = [(2, 2, 84), (6, 2, 76), (10, 2, 84), (14, 2, 76)]
        var out: [NoteEvent] = []
        for bar in 0..<max(1, bars) {
            let c = prog.chords[bar % prog.chords.count]
            for (s, len, vel) in steps {
                for m in c.voicing { out.append(NoteEvent(step: bar * 16 + s, length: len, midi: m, velocity: vel)) }
            }
        }
        return out
    }

    /// "in F minor", "in Gm", "in eb", "in C major" → key. A bare letter needs a quality ("in a club" is not a key).
    static func keyFromPrompt(_ prompt: String) -> (pc: Int, minor: Bool)? {
        let text = prompt.lowercased()
        let patterns = ["(?<![a-z])in ([a-g])([#b♯♭]?)\\s*(minor|min|major|maj|m)(?![a-z])",
                        "(?<![a-z])in ([a-g])([#b♯♭])(?![a-z0-9])"]
        for pat in patterns {
            guard let r = try? NSRegularExpression(pattern: pat),
                  let m = r.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { continue }
            let ns = text as NSString
            let letter = ns.substring(with: m.range(at: 1)).uppercased()
            let acc = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
            let qual = m.numberOfRanges > 3 && m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : ""
            let accSym = acc == "#" || acc == "♯" ? "#" : acc == "b" || acc == "♭" ? "b" : ""
            guard let k = Music.parseKey(letter + accSym + (qual.hasPrefix("m") && !qual.hasPrefix("maj") ? "m" : "")) else { continue }
            return k
        }
        return nil
    }

    /// Prompt asks for MIDI keys only: a MIDI style and no sample/instrument words ("chords"/"stabs" are fine).
    static func wantsMidiOnly(_ prompt: String, style: Style) -> Bool {
        guard midiStyles.contains(style) else { return false }
        let text = KeywordParser.normalize(prompt)
        let sampleWords = KeywordParser.melodicWords.filter { $0 != "chords" && $0 != "keys" }
        return !KeywordParser.hasAny(sampleWords, text)
    }

    /// GPT "chords" → pad-1 NoteEvents: ≤ 4 distinct notes folded into 55–76, tiled over `bars`.
    static func events(from chords: [Arrangement.ChordHit], bars: Int) -> [NoteEvent] {
        let valid = chords.filter { $0.bar >= 0 && $0.bar < bars && (0..<16).contains($0.step) && !$0.notes.isEmpty }
        guard !valid.isEmpty else { return [] }
        let span = max(1, (valid.map(\.bar).max() ?? 0) + 1)
        let total = bars * 16
        var out: [NoteEvent] = []
        var rep = 0
        while rep * span < bars {
            for c in valid {
                let step = (rep * span + c.bar) * 16 + c.step
                guard step < total else { continue }
                var notes: [Int] = []
                for n in c.notes {
                    var m = n
                    while m > range.upperBound { m -= 12 }
                    while m < range.lowerBound { m += 12 }
                    if !notes.contains(m) { notes.append(m) }
                }
                for m in notes.sorted().prefix(4) {
                    out.append(NoteEvent(step: step, length: max(0.5, min(8, c.len)), midi: m, velocity: max(1, min(110, c.vel))))
                }
            }
            rep += 1
        }
        return out.sorted { $0.step < $1.step }
    }
}
