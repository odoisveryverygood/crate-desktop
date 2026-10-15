import Foundation

// The SONG sheet's settings: metronome + velocity preferences, key names, tempo formatting, and the touch clock the
// engine uses to time recorded hits. The edits themselves are in App/Orchestrator+Song.swift.

/// Per-device preferences (UserDefaults), not part of a project.
enum SongPrefs {
    static let clickKey = "crateClick"
    static let velocityKey = "crateVelocity"
}

/// How hard a pad hit plays. The pads have always read the finger's height; this makes it a visible choice.
enum VelocityMode: String, CaseIterable {
    /// Every hit at 127.
    case full
    /// Top of a pad = hard (127), bottom = soft (70). The original feel.
    case height
    /// Top = 127, bottom = 25: the lower part of a pad plays ghost notes.
    case wide

    var label: String {
        switch self {
        case .full: return "FULL"
        case .height: return "BY HEIGHT"
        case .wide: return "WIDE"
        }
    }

    var hint: String {
        switch self {
        case .full: return "every hit at full power"
        case .height: return "top of a pad = hard, bottom = soft"
        case .wide: return "top = hard, bottom = ghost notes"
        }
    }

    static var current: VelocityMode {
        UserDefaults.standard.string(forKey: SongPrefs.velocityKey).flatMap(VelocityMode.init(rawValue:)) ?? .full
    }

    /// Velocity for a touch `y` points down from the top of a pad `h` tall.
    func velocity(y: CGFloat, height h: CGFloat) -> Int {
        let f = Double(min(1, max(0, y / max(1, h))))
        switch self {
        case .full: return 127
        case .height: return Int((127 - 57 * f).rounded())
        case .wide: return Int((127 - 102 * f).rounded())
        }
    }
}

/// Keys as `state.scaleKey` writes them ("F#m", "Bb") and as the lid prints them ("F♯m", "B♭").
enum SongKey {
    static let roots = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    static let pretty = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    static func name(_ pc: Int, minor: Bool) -> String { roots[((pc % 12) + 12) % 12] + (minor ? "m" : "") }

    static func display(_ pc: Int, minor: Bool) -> String { pretty[((pc % 12) + 12) % 12] + (minor ? "m" : "") }

    /// The key the song sounds in: the material's key (`scaleKey`) moved by the pattern's transpose.
    static func sounding(_ scaleKey: String?, transpose: Int) -> (pc: Int, minor: Bool)? {
        guard let k = Music.parseKey(scaleKey) else { return nil }
        return (((k.pc + transpose) % 12 + 12) % 12, k.minor)
    }

    /// Shortest move between pitch classes, −6 … +5 (a tritone goes down: pitching a sample down sounds better).
    static func nearest(_ d: Int) -> Int {
        let m = ((d % 12) + 12) % 12
        return m >= 6 ? m - 12 : m
    }
}

enum SongFormat {
    /// "92" or "92.5".
    static func bpm(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return abs(r - r.rounded()) < 0.05 ? "\(Int(r.rounded()))" : String(format: "%.1f", r)
    }
}

/// The timestamp of the finger that is being handled right now (UITouch.timestamp: seconds since boot on the same
/// mach clock as AudioEngine.Clock). A pad's sound is triggered inside the touch handler, so the engine can place a
/// recorded hit at the moment the finger landed instead of when the event got delivered (~10–30 ms later).
enum TouchClock {
    static var lastBegan: Double = 0

    /// The touch time if a touch began within the last 80 ms of `now`, else nil (keyboard, URL commands).
    static func recent(now: Double) -> Double? {
        let t = lastBegan
        return t > 0 && t <= now + 0.001 && now - t < 0.08 ? t : nil
    }
}
