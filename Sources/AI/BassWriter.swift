import Foundation

/// Rule-based bassline: grooves.json bassRhythms[style] over the loop's chord roots, octave-folded to the pad.
enum BassWriter {
    struct Harmony {
        var chords: [ChordInfo?] = []
        var bassPerBeat: [Int?] = []
        var keyPC: Int? = nil
        var keyMinor = true
        var spanBars: Int { max(1, max(chords.count, bassPerBeat.count / 4)) }

        init(chords: [ChordInfo?] = [], bassPerBeat: [Int?] = [], keyPC: Int? = nil, keyMinor: Bool = true) {
            self.chords = chords; self.bassPerBeat = bassPerBeat; self.keyPC = keyPC; self.keyMinor = keyMinor
        }
        init(_ c: ChopSet) {
            self.init(chords: c.chords, bassPerBeat: c.bassPerBeat, keyPC: c.keyPC, keyMinor: c.keyMinor)
        }

        /// Root pitch class + quality for a pattern bar: chordsPerBar → bassPerBeat → key tonic.
        func root(bar: Int) -> (pc: Int, minor: Bool) {
            let b = bar % spanBars
            if b < chords.count, let c = chords[b] { return (c.pc, c.minor) }
            let beats = bassPerBeat.count >= (b + 1) * 4 ? Array(bassPerBeat[(b * 4)..<(b * 4 + 4)]) : []
            if let m = beats.compactMap({ $0 }).first { return (((m % 12) + 12) % 12, keyMinor) }
            return (keyPC ?? 9, keyMinor)
        }
    }

    static func write(rhythm: BassRhythm, bars: Int, harmony h: Harmony, kicks: [Hit], padRoot: Int?) -> [NoteEvent] {
        var notes: [NoteEvent] = []
        let fold = padRoot ?? 36
        for bar in 0..<max(1, bars) {
            let (pc, minor) = h.root(bar: bar)
            let root = 36 + pc // C2...B2, inside the 33–52 register
            let next = 36 + h.root(bar: (bar + 1) % max(1, bars)).pc
            let nextNear = Music.fold(next, near: root)
            for n in rhythm.notes where n.step >= 0 && n.step < 16 {
                var midi: Int
                switch n.deg.lowercased() {
                case "3": midi = root + (minor ? 3 : 4)
                case "5": midi = root + 7
                case "b7": midi = root + 10
                case "8": midi = root + 12
                case "appr": midi = nextNear > root ? nextNear - 1 : nextNear < root ? nextNear + 1 : root - 2
                default: midi = root
                }
                while midi > 52 { midi -= 12 }
                while midi < 33 { midi += 12 }
                notes.append(NoteEvent(step: bar * 16 + n.step, length: max(0.5, n.len), midi: Music.fold(midi, near: fold),
                                       velocity: max(1, min(127, n.vel))))
            }
        }
        if rhythm.followKick {
            let starts = Set(notes.map(\.step))
            let sortedStarts = notes.map(\.step).sorted()
            for k in kicks where k.step < bars * 16 && !starts.contains(k.step) {
                let (pc, _) = h.root(bar: k.step / 16)
                let nextStart = sortedStarts.first { $0 > k.step } ?? (k.step + 4)
                let len = Double(max(1, min(4, nextStart - k.step)))
                notes.append(NoteEvent(step: k.step, length: len, midi: Music.fold(36 + pc, near: fold),
                                       velocity: max(1, min(127, Int(Double(k.velocity) * 0.95)))))
            }
        }
        return notes.sorted { $0.step < $1.step }
    }

    /// The bass rhythm each style uses now (set when a new beat is built; edits and sample swaps keep it).
    private(set) static var current: [Style: String] = [:]

    /// New beat: a seeded pick among the style's bass rhythm variants (styles[style].basses), never the same twice in a row.
    @discardableResult
    static func pickRhythm(_ lib: LibraryStore, style: Style, seed: UInt64) -> String? {
        let info = lib.styleInfo(style)
        let keys = (info.basses ?? [info.bass ?? style.rawValue]).filter { lib.grooves.bassRhythms[$0] != nil }
        guard !keys.isEmpty else { return nil }
        var pool = keys
        if keys.count > 1, let last = current[style] { pool.removeAll { $0 == last } }
        var rng = SeededRNG(seed: seed ^ 0xBA55_BA55)
        let pick = pool[Int(rng.next() % UInt64(pool.count))]
        current[style] = pick
        return pick
    }

    /// Rhythm for a style (its current pick, else grooves.json styles[style].bass → bassRhythms), with a plain root fallback.
    static func rhythm(_ lib: LibraryStore, style: Style) -> BassRhythm {
        let key = current[style] ?? lib.styleInfo(style).bass ?? style.rawValue
        return lib.grooves.bassRhythms[key] ?? lib.grooves.bassRhythms[style.rawValue]
            ?? BassRhythm(notes: [BassRhythmNote(step: 0, len: 6, deg: "R", vel: 104),
                                  BassRhythmNote(step: 8, len: 4, deg: "5", vel: 90)], followKick: false)
    }
}
