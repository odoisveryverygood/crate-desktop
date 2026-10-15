import Foundation

// Codable mirrors of library/oneshots.json, loops.json and grooves.json (keys starting with "_" are ignored).

struct OneShot: Codable, Hashable {
    var id: String
    var file: String
    var name: String
    var category: String
    var styles: [String: Double]
    var tags: [String]? = nil
    var brightness: Double = 0.5
    var punch: Double = 0.5
    var dust: Double = 0.5
    var decaySec: Double? = nil
    var durationSec: Double? = nil
    var rootNote: Int? = nil
    var key: String? = nil
    var loopable: Bool? = nil
    var source: String? = nil

    func style(_ s: Style) -> Double { s.score(in: styles) }
}

struct OneShotsFile: Codable {
    var version: Int?
    var samples: [OneShot]
}

struct LoopEntry: Codable, Hashable {
    var id: String
    var file: String
    var name: String
    var instrument: String
    var bpm: Double
    var bars: Int
    var beatsPerBar: Int? = 4
    var durationSec: Double
    var key: String? = nil
    var keyConfidence: Double? = nil
    var beatsSec: [Double]? = nil
    var onsetsSec: [Double]? = nil
    var slices16Sec: [Double]? = nil
    var chordsPerBar: [String?]? = nil
    var bassPerBeat: [Int?]? = nil
    var source: String? = nil
    var styles: [String: Double] = [:]
    var moods: [String]? = nil
    var brightness: Double? = nil
    var dust: Double? = nil

    func style(_ s: Style) -> Double { s.score(in: styles) }
    var secondsPerBar: Double { Double(beatsPerBar ?? 4) * 60 / max(bpm, 1) }
}

struct LoopsFile: Codable {
    var version: Int?
    var loops: [LoopEntry]
}

struct KitTarget: Codable, Hashable {
    var dust: Double
    var brightness: Double
    var punch: Double
}

struct StyleInfo: Codable, Hashable {
    var label: String
    var bpm: [Double]
    var defaultBpm: Double
    var swing: Double
    var grooves: [String]
    var bass: String?
    /// Bass rhythm variants (keys of bassRhythms); a new beat picks one by seed.
    var basses: [String]? = nil
    var kit: KitTarget
    var keywords: [String]

    var bpmRange: ClosedRange<Double> {
        let lo = bpm.first ?? defaultBpm - 5, hi = bpm.last ?? defaultBpm + 5
        return min(lo, hi)...max(lo, hi)
    }
}

struct GrooveTemplate: Codable, Hashable {
    var id: String
    var style: String
    var name: String
    var bars: Int
    var bpm: Double
    var swing: Double
    /// lane name → [[step, vel, offset, ratchet?]]
    var lanes: [String: [[Double]]]
}

struct BassRhythmNote: Codable, Hashable {
    var step: Int
    var len: Double
    var deg: String
    var vel: Int
}

struct BassRhythm: Codable, Hashable {
    var notes: [BassRhythmNote]
    var followKick: Bool = false
}

struct BankAInfo: Codable, Hashable { var pads: [String] }

struct GroovesFile: Codable {
    var styles: [String: StyleInfo]
    var bankA: BankAInfo?
    var grooves: [GrooveTemplate]
    var fills: [FillDef]
    var bassRhythms: [String: BassRhythm]

    func style(_ s: Style) -> StyleInfo? { styles[s.rawValue] }
    func groove(id: String) -> GrooveTemplate? { grooves.first { $0.id == id } }
    func fill(id: String) -> FillDef? { fills.first { $0.id == id } }
}

/// Deterministic RNG (SplitMix64) so "DIG AGAIN" varies per seed but stays reproducible in tests.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// Chord symbol → root pitch class + quality ("Am7", "A#maj9", "F#9", "C#m7", "Gm", "Dbm").
struct ChordInfo: Hashable {
    var pc: Int
    var minor: Bool
    var symbol: String

    static func parse(_ symbol: String?) -> ChordInfo? {
        guard let s = symbol?.trimmingCharacters(in: .whitespaces), let first = s.first else { return nil }
        let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard var pc = letters[Character(first.uppercased())] else { return nil }
        var rest = s.dropFirst()
        if let acc = rest.first {
            if acc == "#" || acc == "♯" { pc += 1; rest = rest.dropFirst() } else if acc == "b" || acc == "♭" { pc -= 1; rest = rest.dropFirst() }
        }
        let q = rest.lowercased()
        let minor = (q.hasPrefix("m") && !q.hasPrefix("maj")) || q.hasPrefix("min") || q.hasPrefix("dim") || q.hasPrefix("-")
        return ChordInfo(pc: (pc + 12) % 12, minor: minor, symbol: s)
    }
}
