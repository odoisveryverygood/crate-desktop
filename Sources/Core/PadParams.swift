import Foundation

/// Per-pad sound controls, like Serato Sample's pad row: rendered once into the pad's buffer when they change
/// (`AudioEngine.PadRender`), so playback costs nothing extra. Saved with the pad (`Project.Sound.params`).
/// The engine keeps the untouched slice, so every change re-renders from the original.
struct PadParams: Hashable, Codable {
    /// dB on top of the sound's own gain (−30…+6).
    var level: Double = 0
    /// One bipolar tone control: −1…0 low-pass (darker), 0 off, 0…+1 high-pass (brighter).
    var filter: Double = 0
    /// Fade-in, seconds (0…0.5).
    var attack: Double = 0
    /// Fade-out at the end of the sound and after a note-off / cut, seconds (0…2).
    var release: Double = 0
    var reverse = false
    /// Semitones (−12…+12), pitch only (the length stays). KEYS notes and the song transpose add to it.
    var keyShift: Int = 0
    /// Playback speed, pitch kept: 0.5 = half speed (twice as long), 2 = double speed.
    var stretch: Double = 1
    /// A marker (★ on the pad); doesn't change the sound.
    var favorite = false

    static let neutral = PadParams()

    /// Nothing that changes the audio (favorite aside).
    var isNeutral: Bool {
        level == 0 && filter == 0 && attack == 0 && release == 0 && !reverse && !needsTimePitch
    }
    var isDefault: Bool { isNeutral && !favorite }
    var needsTimePitch: Bool { keyShift != 0 || abs(stretch - 1) > 0.0005 }

    // Unknown / missing keys fall back to the defaults, so older and newer project files both open.
    enum CodingKeys: String, CodingKey { case level, filter, attack, release, reverse, keyShift, stretch, favorite }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .level) ?? 0, Self.levelRange)
        filter = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .filter) ?? 0, -1...1)
        attack = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .attack) ?? 0, 0...0.5)
        release = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .release) ?? 0, 0...2)
        reverse = try c.decodeIfPresent(Bool.self, forKey: .reverse) ?? false
        keyShift = min(12, max(-12, try c.decodeIfPresent(Int.self, forKey: .keyShift) ?? 0))
        stretch = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .stretch) ?? 1, Self.stretchRange)
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
    }

    private static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { v.isFinite ? min(r.upperBound, max(r.lowerBound, v)) : 0 }

    // MARK: Controls (the editor's tiles and the crate://padparam debug command share these)

    enum Control: String, CaseIterable { case level, filter, attack, release, reverse, key, stretch, favorite }

    /// One − (dir < 0) or + tap; REVERSE / ★ toggle.
    mutating func step(_ c: Control, _ dir: Int) {
        switch c {
        case .level: level = min(6, max(-30, (level + Double(dir)).rounded()))
        case .filter: filter = min(1, max(-1, ((filter * 10).rounded() + Double(dir)) / 10))
        case .attack: attack = Self.step(attack, in: Self.attackSteps, dir)
        case .release: release = Self.step(release, in: Self.releaseSteps, dir)
        case .key: keyShift = min(12, max(-12, keyShift + dir))
        case .stretch: stretch = Self.step(stretch, in: Self.stretchSteps, dir)
        case .reverse: reverse.toggle()
        case .favorite: favorite.toggle()
        }
    }

    /// Tapping a tile's value.
    mutating func reset(_ c: Control) { set(c, Self.neutral.value(c)) }

    /// An exact value (clamped): seconds for attack / release, dB for level, speed factor for stretch, 0 / 1 toggles.
    mutating func set(_ c: Control, _ v: Double) {
        guard v.isFinite else { return }
        switch c {
        case .level: level = Self.clamp(v, Self.levelRange)
        case .filter: filter = Self.clamp(v, -1...1)
        case .attack: attack = Self.clamp(v, 0...0.5)
        case .release: release = Self.clamp(v, 0...2)
        case .key: keyShift = min(12, max(-12, Int(v.rounded())))
        case .stretch: stretch = Self.clamp(v, Self.stretchRange)
        case .reverse: reverse = v != 0
        case .favorite: favorite = v != 0
        }
    }

    func value(_ c: Control) -> Double {
        switch c {
        case .level: return level
        case .filter: return filter
        case .attack: return attack
        case .release: return release
        case .key: return Double(keyShift)
        case .stretch: return stretch
        case .reverse: return reverse ? 1 : 0
        case .favorite: return favorite ? 1 : 0
        }
    }

    // MARK: Steps (the editor's − / + tiles)

    static let levelRange: ClosedRange<Double> = -30...6
    static let stretchRange: ClosedRange<Double> = 0.5...2
    static let attackSteps: [Double] = [0, 0.002, 0.005, 0.01, 0.02, 0.035, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5]
    static let releaseSteps: [Double] = [0, 0.01, 0.025, 0.05, 0.1, 0.15, 0.2, 0.3, 0.5, 0.75, 1, 1.5, 2]
    /// Speed snaps and the fine steps between them (percent / 100).
    static let stretchSteps: [Double] = (10...40).map { Double($0) / 20 }

    /// The next value in `steps` above (dir > 0) or below the current one.
    static func step(_ v: Double, in steps: [Double], _ dir: Int) -> Double {
        if dir > 0 { return steps.first { $0 > v + 1e-6 } ?? steps.last! }
        return steps.last { $0 < v - 1e-6 } ?? steps.first!
    }

    // MARK: Filter mapping (shared by the DSP and the readout)

    /// Low-pass cutoff for filter < 0: 20 kHz → 150 Hz.
    static func lowPassHz(_ f: Double) -> Double { 20000 * pow(150.0 / 20000.0, pow(min(1, abs(f)), 0.8)) }
    /// High-pass cutoff for filter > 0: 30 Hz → 5 kHz.
    static func highPassHz(_ f: Double) -> Double { 30 * pow(5000.0 / 30.0, pow(min(1, abs(f)), 0.8)) }

    // MARK: Readouts

    var levelText: String {
        let v = Int(level.rounded())
        return v == 0 ? "0 dB" : (v > 0 ? "+\(v)" : "−\(-v)") + " dB"
    }
    var filterText: String {
        if abs(filter) < 0.001 { return "OFF" }
        return filter < 0 ? "LP " + Self.hz(Self.lowPassHz(filter)) : "HP " + Self.hz(Self.highPassHz(filter))
    }
    var attackText: String { Self.seconds(attack) }
    var releaseText: String { Self.seconds(release) }
    var keyText: String { keyShift == 0 ? "0" : keyShift > 0 ? "+\(keyShift)" : "−\(-keyShift)" }
    var stretchText: String {
        if abs(stretch - 0.5) < 0.001 { return "½" }
        if abs(stretch - 1) < 0.001 { return "1" }
        if abs(stretch - 2) < 0.001 { return "×2" }
        return "\(Int((stretch * 100).rounded()))%"
    }

    static func hz(_ f: Double) -> String {
        f >= 1000 ? String(format: f >= 9950 ? "%.0fk" : "%.1fk", f / 1000) : "\(Int(f.rounded()))"
    }
    static func seconds(_ s: Double) -> String {
        if s <= 0 { return "0" }
        let ms = Int((s * 1000).rounded())
        return ms >= 1000 ? String(format: ms % 1000 == 0 ? "%.0fs" : "%.1fs", s) : "\(ms)ms"
    }

    /// For the debug log.
    var summary: [String: Any] {
        ["level": level, "filter": filter, "attack": attack, "release": release, "reverse": reverse,
         "key": keyShift, "stretch": stretch, "fav": favorite]
    }
}
