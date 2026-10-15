import Foundation

// Shared contract for every module (BUILD.md §4). Foundation-only so it also compiles on macOS.

enum Style: String, CaseIterable, Codable, Hashable {
    case dilla, jazzhop, boombap, lofi, vintage, house, trap, drill, rnb
    case jerseyclub, garage, afrobeats, kpop

    /// Styles added after the library was analysed have no per-sample scores: they borrow from their nearest
    /// analysed styles (weights sum to 1, so a perfect neighbour still scores near 1).
    static let derived: [Style: [(Style, Double)]] = [
        .jerseyclub: [(.trap, 0.55), (.house, 0.45)],
        .garage: [(.house, 0.65), (.rnb, 0.35)],
        .afrobeats: [(.house, 0.5), (.rnb, 0.5)],
        .kpop: [(.house, 0.45), (.rnb, 0.3), (.trap, 0.25)],
    ]

    /// A sample's score for this style from its `styles` map (derived for the newer styles when it isn't there).
    func score(in styles: [String: Double]) -> Double {
        if let v = styles[rawValue] { return v }
        guard let mix = Style.derived[self] else { return 0 }
        return mix.reduce(0) { $0 + (styles[$1.0.rawValue] ?? 0) * $1.1 }
    }
}

enum Category: String, Codable, CaseIterable, Hashable {
    case kick, snare, clap, hat, openhat, rim, perc, shaker, cymbal
    case eight08 = "808"
    case bass, fx, vocal, texture, keys, synth, chop, loop

    /// Sounds that follow the key when played in KEYS mode or by a bassline.
    var isPitched: Bool { [.eight08, .bass, .keys, .synth, .chop, .loop].contains(self) }
}

/// A = drums, B = sample chops, C = bass/keys, D = free (AI one-offs, generated sounds).
enum Bank: Int, CaseIterable, Codable, Hashable {
    case a = 0, b, c, d
    var letter: String { ["A", "B", "C", "D"][rawValue] }
}

/// index 0...15, 0 = pad 1 = bottom-left (MPC order; top row = pads 13-16).
struct PadID: Hashable, Codable {
    var bank: Bank
    var index: Int
    init(_ bank: Bank, _ index: Int) { self.bank = bank; self.index = index }
    var number: Int { index + 1 }
}

/// Bank-A slot layout; groove lanes in grooves.json use these names.
enum BankA {
    /// Bottom row (pads 1-4) = kick, snare, clap, hat, left to right, like a finger-drummer's MPC layout.
    static let defaultSlots = ["kick", "snare", "clap", "hat", "openhat", "kick2", "hat2", "rim",
                               "perc", "perc2", "shaker", "cymbal", "808", "fx", "vocal", "texture"]
    /// The session's layout ("put the clap on the left…"): later kits land in the same places until the app restarts;
    /// every launch starts from the default bottom row.
    private(set) static var slots: [String] = {
        UserDefaults.standard.removeObject(forKey: "crateBankASlots")   // older builds persisted a custom order
        return defaultSlots
    }()
    static func setSlots(_ s: [String]) { slots = s }
    static func index(forLane lane: String) -> Int? { slots.firstIndex(of: lane) }
    static func pad(forLane lane: String) -> PadID? { index(forLane: lane).map { PadID(.a, $0) } }
}

struct PadSound: Identifiable, Hashable {
    var id: String
    var name: String
    var category: Category
    var fileURL: URL
    /// Seconds into the file; chops are slices of one loop file.
    var start: Double = 0
    var end: Double? = nil
    var rootNote: Int? = nil
    var gain: Float = 1
    var source: String = ""
    /// The pad editor's controls (level, filter, attack, release, reverse, key, stretch, favorite).
    var params = PadParams()
}

/// offset = fraction of one 16th (+ = late); ratchet = evenly spaced repeats inside the step.
struct Hit: Hashable, Codable {
    var step: Int
    var velocity: Int
    var offset: Double = 0
    var ratchet: Int = 1
}

/// Played on a pad, pitched (midi - rootNote) semitones. length is in steps.
struct NoteEvent: Hashable, Codable {
    var step: Int
    var length: Double
    var midi: Int
    var velocity: Int
}

/// Steps are absolute: 0 ..< bars*16.
struct Pattern: Hashable {
    var bars: Int = 1
    var swing: Double = 50
    var lanes: [PadID: [Hit]] = [:]
    var late: [PadID: Double] = [:]
    var notes: [PadID: [NoteEvent]] = [:]
    /// Song KEY change: semitones the pitched pads of banks B–D (chops, loops, bass, keys) play shifted by, at trigger
    /// time (the notes themselves stay as written). Lives with the pattern so UNDO, saving and a new DIG (which builds
    /// a fresh pattern in its own key) all handle it for free. Bank A drums never move.
    var transpose: Int = 0
    var totalSteps: Int { bars * 16 }
    static let empty = Pattern()
}

/// A one-bar fill from grooves.json. hits = [step, velocity, offset, ratchet?], bar-relative steps.
struct FillOp: Codable, Hashable {
    var op: String            // "clear" | "add" | "addNextBar"
    var lanes: [String]? = nil
    var lane: String? = nil
    var fromStep: Int? = nil
    var hits: [[Double]]? = nil
}

struct FillDef: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var ops: [FillOp]
}

enum ApplyTiming { case now, nextBar }

enum Mode: String, CaseIterable {
    case sample, chop, keys, seq, padFX, levels16
    var label: String {
        switch self {
        case .sample: return "SAMPLE"
        case .chop: return "CHOP"
        case .keys: return "KEYS"
        case .seq: return "SEQ"
        case .padFX: return "PAD FX"
        case .levels16: return "16 LVL"
        }
    }
}

enum Tint: Hashable { case orange, blue, ochre, grey, red }

struct LogLine: Identifiable, Hashable {
    let id = UUID()
    var tag: String          // JEV KIT SAMPLE BASS GPT PERFORM ERR
    var text: String
    var ms: Int? = nil
    var tint: Tint = .grey
}
