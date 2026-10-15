import Foundation

/// The audio engine contract. Agent A implements `AudioEngine`; `MockEngine` backs previews and tests.
protocol SamplerEngine: AnyObject {
    func start() throws

    /// Decode, convert and cache the buffers, then swap the bank in atomically. Keys = pad index 0...15.
    func loadBank(_ bank: Bank, sounds: [Int: PadSound]) async throws
    func sound(for pad: PadID) -> PadSound?

    /// Live trigger, as soon as possible. semitones pitches via varispeed (classic sampler).
    func trigger(_ pad: PadID, velocity: Int, semitones: Double)
    /// KEYS note-off (short fade); no-op for one-shots.
    func release(_ pad: PadID)

    func setPattern(_ p: Pattern, timing: ApplyTiming)
    /// SONG mode: `p` comes in on the next bar line and playback carries on from `bar`'s downbeat there (the song's
    /// start, a section's ▶, or back to the loop). Stopped: `p` now, and PLAY starts at `bar`.
    func setPattern(_ p: Pattern, fromBar bar: Int)
    /// The bar a `setPattern(_:fromBar:)` cue in flight lands on (nil once its downbeat has passed, or none).
    func cuedBar() -> Int?
    var pattern: Pattern { get }

    func play()
    func stop()
    var isPlaying: Bool { get }
    var bpm: Double { get set }
    /// MPC swing percent, 50 = straight.
    var swing: Double { get set }

    /// Absolute playback position in steps (the UI polls it at 60 fps for the playhead).
    func position() -> Double
    /// Called on main at each bar start with the absolute bar index.
    var onBar: ((Int) -> Void)? { get set }
    /// Applied to bank-A lanes when that bar is scheduled.
    func queueFill(_ fill: FillDef, atBar bar: Int)

    /// While playing, live triggers are quantized (1/16) into `pattern` (overdub).
    func setRecording(_ on: Bool)

    /// Hinge punch-in FX amount 0...1 (filter / crush / delay / reverb; > 0.92 = breakdown).
    func setPunch(_ amount: Double)
    /// Snap-open: FX off instantly + crash + kick.
    func drop()
    /// PAD FX: which effect `setPunch` drives (nil = the default PUNCH chain). Default impl is a no-op.
    func setFX(_ type: FXType?)

    /// Pads played over the loop with REC off, waiting for KEEP: how many, and seconds since the newest.
    func jamInfo() -> (count: Int, age: Double)
    /// KEEP: write that jam into the pattern; `done` gets how many hits landed.
    func captureJam(_ done: @escaping @MainActor (Int) -> Void)

    /// ● REC from stop: one bar (`beats`) of count-in clicks, then the loop starts on the next downbeat (the
    /// transport runs through the count-in, so a hit just before the downbeat still lands on it).
    func play(countIn beats: Int)
    /// Called on main at each count-in click with the beats left (4…1), then 0 on the downbeat.
    var onCountIn: ((Int) -> Void)? { get set }
    /// Metronome: a click on every beat (accent on beat 1) while playing. Never printed into the master tap / bounces.
    var metronome: Bool { get set }
    /// The bar PLAY (and REC's count-in) starts from when stopped (the bar the step grid is viewing; 0 = the top).
    var startBar: Int { get set }
    /// While playing: jump to `bar`'s downbeat on the next beat (quantized). Stopped: same as `startBar = bar`.
    func jump(toBar bar: Int)

    /// Master RMS 0...1 for meters.
    func level() -> Float
    /// Peak envelope for display (0...1), `points` long.
    func waveform(_ pad: PadID, points: Int) -> [Float]

    /// MUTE: the sequencer skips these pads (live hits still play). Default impl is a no-op.
    func setMuted(_ pads: Set<PadID>)
}

extension SamplerEngine {
    func setMuted(_ pads: Set<PadID>) {}
}

/// Defaults for engines without a sequencer clock of their own (MockEngine: previews and tests).
extension SamplerEngine {
    func play(countIn beats: Int) { play(); onCountIn?(0) }
    var onCountIn: ((Int) -> Void)? { get { nil } set {} }
    var metronome: Bool { get { false } set {} }
    var startBar: Int { get { 0 } set {} }
    func jump(toBar bar: Int) {}
    func setPattern(_ p: Pattern, fromBar bar: Int) {
        setPattern(p, timing: isPlaying ? .nextBar : .now)
        startBar = bar
    }
    func cuedBar() -> Int? { nil }
}
