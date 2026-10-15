import Foundation

// SONG arranging, FL-Studio style, as a bank × section grid: each bank (A drums, B sample, C bass · keys, D layer)
// has numbered variations of its part, and each song section says which variation every bank plays (0 = off).
// PATTERN mode plays the *edit* variation of every bank (the live pattern every existing tool edits); SONG mode
// plays the sections end to end as one long pattern. The edits live in AI/Orchestrator+Arrange.swift.
// (Named SongArrangement: `Arrangement` is GPT's arrangement reply.)

/// Bank keys encode as JSON object keys ("0"…"3"), so `[Bank: …]` stays readable in saved projects.
extension Bank: CodingKeyRepresentable {}

/// One bank's part of a beat: the lanes / notes / late of that bank's pads (keyed by pad index), steps relative to
/// the variation's own length `bars`.
struct BankSeq: Hashable, Codable {
    var bars: Int = 1
    var lanes: [Int: [Hit]] = [:]
    var notes: [Int: [NoteEvent]] = [:]
    var late: [Int: Double] = [:]

    var isEmpty: Bool { !lanes.values.contains { !$0.isEmpty } && !notes.values.contains { !$0.isEmpty } }
    var hitCount: Int { lanes.values.reduce(0) { $0 + $1.count } + notes.values.reduce(0) { $0 + $1.count } }

    /// `bank`'s part of a pattern.
    static func capture(_ p: Pattern, bank: Bank) -> BankSeq {
        var s = BankSeq(bars: max(1, p.bars))
        for (pad, hits) in p.lanes where pad.bank == bank && !hits.isEmpty { s.lanes[pad.index] = hits }
        for (pad, notes) in p.notes where pad.bank == bank && !notes.isEmpty { s.notes[pad.index] = notes }
        for (pad, v) in p.late where pad.bank == bank && (s.lanes[pad.index] != nil || s.notes[pad.index] != nil) {
            s.late[pad.index] = v
        }
        return s
    }

    /// Writes this part into `p` at step `offset`, repeated (tiled) to fill `length` steps. Notes that would ring past
    /// the end are cut there, so a section never bleeds into the next.
    func write(into p: inout Pattern, bank: Bank, offset: Int, length: Int) {
        let src = max(1, bars) * 16
        guard length > 0 else { return }
        let reps = (length + src - 1) / src
        for (i, hits) in lanes where !hits.isEmpty {
            let pad = PadID(bank, i)
            var out: [Hit] = []
            for k in 0..<reps {
                for h in hits where h.step >= 0 && h.step < src && k * src + h.step < length {
                    var x = h
                    x.step = offset + k * src + h.step
                    out.append(x)
                }
            }
            guard !out.isEmpty else { continue }
            p.lanes[pad, default: []].append(contentsOf: out)
            if let l = late[i], p.late[pad] == nil { p.late[pad] = l }
        }
        for (i, notes) in notes where !notes.isEmpty {
            let pad = PadID(bank, i)
            var out: [NoteEvent] = []
            for k in 0..<reps {
                for n in notes where n.step >= 0 && n.step < src && k * src + n.step < length {
                    var x = n
                    let local = k * src + n.step
                    x.step = offset + local
                    x.length = min(n.length, Double(length - local))
                    out.append(x)
                }
            }
            guard !out.isEmpty else { continue }
            p.notes[pad, default: []].append(contentsOf: out)
            if let l = late[i], p.late[pad] == nil { p.late[pad] = l }
        }
    }

    /// Replaces `bank`'s part of `p` with this one, tiled to the pattern's length.
    func replace(in p: inout Pattern, bank: Bank) {
        p.lanes = p.lanes.filter { $0.key.bank != bank }
        p.notes = p.notes.filter { $0.key.bank != bank }
        p.late = p.late.filter { $0.key.bank != bank }
        write(into: &p, bank: bank, offset: 0, length: max(1, p.bars) * 16)
    }
}

/// One column of the song: a name, a length (4 or 8 bars) and the variation each bank plays (0 / absent = off).
struct SongSection: Hashable, Codable, Identifiable {
    var id = UUID()
    var name: String
    var bars: Int
    var parts: [Bank: Int] = [:]

    static let names = ["INTRO", "VERSE", "HOOK", "BRIDGE", "OUTRO", "DROP"]

    /// The header's short name (the column is narrow).
    var short: String { name == "BRIDGE" ? "BRDG" : name }

    func part(_ b: Bank) -> Int { parts[b] ?? 0 }
}

struct SongArrangement: Hashable, Codable {
    var sections: [SongSection] = []
    /// Per bank, its variations (index 0 = variation 1).
    var variations: [Bank: [BankSeq]] = [:]
    /// Per bank, the variation PATTERN mode plays and edits (1-based; absent = 1).
    var editVar: [Bank: Int] = [:]
    /// SONG mode: the engine plays the rendered song instead of the edit pattern.
    var songMode = false

    static let empty = SongArrangement()

    func edit(_ b: Bank) -> Int { max(1, editVar[b] ?? 1) }
    func count(_ b: Bank) -> Int { variations[b]?.count ?? 0 }
    func seq(_ b: Bank, _ v: Int) -> BankSeq? { variations[b]?[safe: v - 1] }
    func hasContent(_ b: Bank) -> Bool { variations[b]?.contains { !$0.isEmpty } ?? false }

    /// Banks with something to arrange, in bank order (the grid's rows).
    var rows: [Bank] { Bank.allCases.filter(hasContent) }

    var totalBars: Int { sections.reduce(0) { $0 + max(1, $1.bars) } }

    /// Worth saving with the project / showing as a song: there are sections, or a bank has a second variation.
    var isUsed: Bool { !sections.isEmpty || variations.values.contains { $0.count > 1 } }

    /// First bar of each section.
    var starts: [Int] {
        var out: [Int] = [], s = 0
        for sec in sections { out.append(s); s += max(1, sec.bars) }
        return out
    }

    /// The section playing at song bar `bar` (nil if the song is empty).
    func section(atBar bar: Int) -> Int? {
        guard !sections.isEmpty else { return nil }
        var s = 0
        for (i, sec) in sections.enumerated() {
            s += max(1, sec.bars)
            if bar < s { return i }
        }
        return sections.count - 1
    }

    /// The whole song as one pattern: sections end to end, each cell's variation tiled to its section's bars and
    /// offset by the section's start. Swing / transpose come from `base` (the edit pattern), so the song plays in the
    /// same key and feel.
    func render(base: Pattern) -> Pattern {
        var p = Pattern(bars: max(1, totalBars), swing: base.swing)
        p.transpose = base.transpose
        var start = 0
        for sec in sections {
            let bars = max(1, sec.bars)
            for b in Bank.allCases {
                let v = sec.part(b)
                guard v > 0, let s = seq(b, v), !s.isEmpty else { continue }
                s.write(into: &p, bank: b, offset: start * 16, length: bars * 16)
            }
            start += bars
        }
        for k in p.lanes.keys { p.lanes[k]?.sort { $0.step < $1.step } }
        for k in p.notes.keys { p.notes[k]?.sort { $0.step < $1.step } }
        return p
    }
}
