import Foundation

/// Groove templates + chops → Core.Pattern lanes. All pure and instant.
enum PatternBuilder {
    static let hipHop: Set<Style> = [.dilla, .jazzhop, .boombap, .lofi, .vintage, .rnb]

    static func defaultLaidback(_ s: Style) -> Double {
        switch s {
        case .dilla: return 0.8
        case .jazzhop, .lofi: return 0.6
        case .rnb: return 0.5
        case .boombap, .vintage: return 0.4
        case .house: return 0.2
        case .garage, .afrobeats: return 0.3
        case .trap, .drill, .jerseyclub, .kpop: return 0.1
        }
    }

    /// The style's grooves (grooves.json styles[style].grooves, else every template of that style).
    static func grooves(_ lib: LibraryStore, style: Style) -> [GrooveTemplate] {
        let list = lib.styleInfo(style).grooves.compactMap { lib.grooves.groove(id: $0) }
        return list.isEmpty ? lib.grooves.grooves.filter { $0.style == style.rawValue } : list
    }

    /// Recently used groove ids per style (newest last): a new beat never repeats the last few of its style.
    private(set) static var recent: [Style: [String]] = [:]
    /// The groove the last beat was built on (crate://groovecheck).
    private(set) static var lastPick: GrooveTemplate?

    /// A seeded random groove of the style that isn't one of the last few used for it (DIG AGAIN / the same prompt
    /// walks to a different one; a new prompt lands anywhere in the style).
    static func groove(_ lib: LibraryStore, style: Style, seed: UInt64) -> GrooveTemplate? {
        let list = grooves(lib, style: style)
        guard !list.isEmpty else { lastPick = lib.grooves.grooves.first; return lastPick }
        let avoid = Set((recent[style] ?? []).suffix(min(3, list.count - 1)))
        var pool = list.filter { !avoid.contains($0.id) }
        if pool.isEmpty { pool = list }
        var rng = SeededRNG(seed: seed ^ 0x6A09_E667_F3BC_C908)
        let pick = pool[Int(rng.next() % UInt64(pool.count))]
        recent[style, default: []].append(pick.id)
        if (recent[style]?.count ?? 0) > 8 { recent[style]?.removeFirst() }
        lastPick = pick
        DebugLog.event("groove", ["style": style.rawValue, "id": pick.id, "name": pick.name, "of": list.count,
                                  "hash": signature(pick)])
        return pick
    }

    /// Old entry point (callers that still pass a repeat count): a fresh random pick, never the last few.
    static func groove(_ lib: LibraryStore, style: Style, variant: Int) -> GrooveTemplate? {
        groove(lib, style: style, seed: UInt64(truncatingIfNeeded: abs(variant)) &* 0x9E37_79B9
            &+ UInt64(Date().timeIntervalSince1970 * 1000))
    }

    /// Short stable hash of a groove's rhythm (lane steps + velocities), for the harness.
    static func signature(_ g: GrooveTemplate) -> String {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for lane in g.lanes.keys.sorted() {
            for b in lane.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01B3 }
            for hit in g.lanes[lane] ?? [] {
                for v in hit.prefix(2) { h = (h ^ UInt64(max(0, Int(v)))) &* 0x100_0000_01B3 }
            }
        }
        return String(h, radix: 16)
    }

    /// Hash of a pattern's bank-A lanes (what actually plays), for crate://groovecheck.
    static func drumHash(_ p: Pattern) -> String {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for (pad, hits) in p.lanes.sorted(by: { $0.key.index < $1.key.index }) where pad.bank == .a {
            h = (h ^ UInt64(pad.index + 1)) &* 0x100_0000_01B3
            for x in hits { h = (h ^ UInt64(max(0, x.step * 131 + x.velocity))) &* 0x100_0000_01B3 }
        }
        return String(h, radix: 16)
    }

    static func swing(style: Style, groove: GrooveTemplate?, laidback: Double, lib: LibraryStore) -> Double {
        var s = groove?.swing ?? lib.styleInfo(style).swing
        if hipHop.contains(style) { s += (laidback - defaultLaidback(style)) * 8 }
        return min(66, max(50, s.rounded()))
    }

    /// Groove tiled to `bars`, lanes → bank-A pads, micro offsets × (0.5 + laidback).
    static func drums(_ g: GrooveTemplate, bars: Int, laidback: Double) -> [PadID: [Hit]] {
        var lanes: [PadID: [Hit]] = [:]
        let total = bars * 16
        let tSteps = max(1, g.bars) * 16
        let scale = 0.5 + max(0, min(1, laidback))
        for (lane, hits) in g.lanes {
            guard let pad = BankA.pad(forLane: lane) else { continue }
            var out: [Hit] = []
            var rep = 0
            while rep * tSteps < total {
                for h in hits where h.count >= 2 && Int(h[0]) < tSteps {
                    let step = Int(h[0]) + rep * tSteps
                    guard step < total else { continue }
                    let off = (h.count > 2 ? h[2] : 0) * scale
                    let rat = h.count > 3 ? max(1, min(4, Int(h[3]))) : 1
                    out.append(Hit(step: step, velocity: max(1, min(127, Int(h[1]))), offset: max(-0.5, min(0.5, off)), ratchet: rat))
                }
                rep += 1
            }
            if !out.isEmpty { lanes[pad] = out.sorted { $0.step < $1.step } }
        }
        return lanes
    }

    /// Chops in original order (the loop as recorded): each pad at its chop's grid step, nudged by an offset so it
    /// starts exactly where it was (incl. undoing the pattern's swing on odd steps), repeated every span. Pads are
    /// hero-ordered (FIND), so the order comes from `info`, not from the pad index. FLIP IT (FlipBuilder) re-sequences.
    static func chops(_ c: ChopSet, bars: Int, swing: Double, bank: Bank = .b, velocity: Int = 100) -> [PadID: [Hit]] {
        var lanes: [PadID: [Hit]] = [:]
        let spanSteps = max(1, c.spanBars) * 16, total = max(1, bars) * 16
        let grid = c.grid ?? ChopGrid(origin: 0, stepSec: 60 / max(1, c.loop.bpm) / 4)
        let swingSteps = max(0, 2 * swing / 100 - 1)
        var placed: [(pad: Int, step: Int, offset: Double)] = []
        for (pad, s) in c.sounds where c.info[pad]?.tile != false {
            let info = c.info[pad]
            var step = info?.step ?? pad * max(1, c.spanBars)
            guard step >= 0, step < spanSteps else { continue }
            var off = (s.start - grid.time(Double(step))) / max(0.01, grid.stepLength(at: Double(step)))
            if step % 2 == 1 { off -= swingSteps }
            if off > 0.5 { step += 1; off -= 1 } else if off < -0.5 { step -= 1; off += 1 }
            guard step >= 0, step < spanSteps else { continue }
            placed.append((pad, step, max(-0.5, min(0.5, (off * 100).rounded() / 100))))
        }
        var rep = 0
        while rep * spanSteps < total {
            for p in placed where rep * spanSteps + p.step < total {
                lanes[PadID(bank, p.pad), default: []].append(Hit(step: rep * spanSteps + p.step, velocity: velocity, offset: p.offset))
            }
            rep += 1
        }
        return lanes.mapValues { $0.sorted { $0.step < $1.step } }
    }

    /// Repeat (or cut) an existing pattern to a new bar count.
    static func retile(_ p: Pattern, to bars: Int) -> Pattern {
        guard bars > 0, bars != p.bars else { return p }
        var out = p
        out.bars = bars
        let src = max(1, p.bars) * 16, total = bars * 16
        out.lanes = p.lanes.mapValues { hits in
            var r: [Hit] = []
            var rep = 0
            while rep * src < total {
                for h in hits where h.step < src && h.step + rep * src < total { var x = h; x.step += rep * src; r.append(x) }
                rep += 1
            }
            return r
        }
        out.notes = p.notes.mapValues { notes in
            var r: [NoteEvent] = []
            var rep = 0
            while rep * src < total {
                for n in notes where n.step < src && n.step + rep * src < total { var x = n; x.step += rep * src; r.append(x) }
                rep += 1
            }
            return r
        }
        return out
    }

    static func hitCount(_ p: Pattern) -> Int { p.lanes.values.reduce(0) { $0 + $1.count } }
    static func noteCount(_ p: Pattern) -> Int { p.notes.values.reduce(0) { $0 + $1.count } }

    static func kickSteps(_ lanes: [PadID: [Hit]]) -> [Hit] {
        ((lanes[PadID(.a, 0)] ?? []) + (lanes[PadID(.a, 1)] ?? [])).sorted { $0.step < $1.step }
    }

    /// Bank-A lanes as 16-char bar strings (X x g r .) for the OpenAI template.
    static func laneStrings(_ p: Pattern, maxBars: Int = 8) -> [String: [String]] {
        var out: [String: [String]] = [:]
        let bars = max(1, min(p.bars, maxBars))
        for (pad, hits) in p.lanes where pad.bank == .a && !hits.isEmpty && pad.index < 12 {
            var grid = Array(repeating: Array(repeating: Character("."), count: 16), count: bars)
            for h in hits where h.step >= 0 && h.step < bars * 16 {
                let c: Character = h.ratchet > 1 ? "r" : h.velocity >= 105 ? "X" : h.velocity >= 60 ? "x" : "g"
                grid[h.step / 16][h.step % 16] = c
            }
            out[BankA.slots[pad.index]] = grid.map { String($0) }
        }
        return out
    }
}
