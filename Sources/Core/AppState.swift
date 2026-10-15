import Foundation
import Observation

/// Single source of truth the UI binds to. The App layer wires the actions (onDig etc.) to the orchestrator.
@Observable
final class AppState {
    var mode: Mode = .seq
    var bank: Bank = .a
    var selectedPad = PadID(.a, 0)
    var sounds: [PadID: PadSound] = [:]

    var bpm: Double = 90
    var swing: Double = 56
    var isPlaying = false
    var isRecording = false
    var bars = 4

    var styleLabel = "CRATE"
    var sampleLabel = ""
    var chordsLabel = ""
    var log: [LogLine] = []
    var prompt = ""
    var isDigging = false
    /// What the AI is doing with the last prompt (shown next to the prompt).
    var aiStatus: AIStatus = .idle
    var aiStatusText = ""
    var aiStatusAt = Date.distantPast
    var jevMs: Int? = nil
    var gptSeconds: Double? = nil

    var heldPads: Set<PadID> = []
    var heldNotes: Set<Int> = []
    var keyVelocity = 110
    var promptFocused = false

    var keysOctave = 0
    var scaleLock = true
    var scaleKey: String? = nil
    var lastNoteName = ""

    var punch: Double = 0
    /// PAD FX selection (FXType raw value; nil = PUNCH default chain) and LATCH (true = tap selects and stays).
    var fxType: String? = nil
    var fxLatched = true
    var hingeAngle: Double? = nil
    var performOn = false
    var lastPerform = ""

    /// Duo outer screen (faces the audience when open) — driven by ExternalNonInteractiveAccessory availability.
    var outerDisplayAvailable = false
    var crowdDisplayOn = true

    var lastHitPad: PadID? = nil
    var lastHitTime = Date.distantPast

    /// MUTE (MPC pad / track mute): the sequencer skips these pads; a live hit still plays. Saved with the project.
    var mutedPads: Set<PadID> = []

    /// SONG: the bank × section arrangement and whether the engine plays it (SONG) or the edit pattern (PATTERN).
    /// Edited through Orchestrator+Arrange; saved with the project.
    var song = SongArrangement()

    @ObservationIgnored var engine: SamplerEngine
    @ObservationIgnored var onDig: ((String) -> Void)?
    @ObservationIgnored var onFlip: (() -> Void)?
    @ObservationIgnored var onPerformToggle: ((Bool) -> Void)?
    /// Hold a pad / a bank and talk: the request lands on that pad or bank only (Orchestrator.digTargeted).
    @ObservationIgnored var onTargetedDig: ((String, PadID?, Bank?) -> Void)?

    init(engine: SamplerEngine) {
        self.engine = engine
    }

    func sound(_ pad: PadID) -> PadSound? { sounds[pad] ?? engine.sound(for: pad) }

    func hit(_ pad: PadID, velocity: Int = 110, semitones: Double = 0) {
        engine.trigger(pad, velocity: velocity, semitones: semitones)
        lastHitPad = pad
        lastHitTime = Date()
        DebugLog.event("pad", ["bank": pad.bank.letter, "i": pad.index, "vel": velocity, "semi": semitones])
    }

    func dig(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        prompt = t
        CrateUI.shared.flipHint = false
        // After the one-time AI consent sheet (if it's up), so the auto-name window starts with the dig itself.
        PrivacyChoices.shared.beforeAI { [weak self] in
            Task { @MainActor in ProjectStore.shared.promptSubmitted(t) }   // the first beat prompt names the project
            self?.onDig?(t)
        }
    }

    /// A spoken request aimed at one pad or one bank (hold-to-talk).
    func digTargeted(_ text: String, pad: PadID?, bank: Bank?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        DebugLog.event("dig_targeted", ["text": t, "pad": pad?.key ?? "", "bank": bank?.letter ?? "",
                                        "wired": onTargetedDig != nil])
        if let onTargetedDig {
            prompt = t
            onTargetedDig(t, pad, bank)
        } else if let pad {
            dig("\(t) on pad \(pad.key)")
        } else {
            dig(t)
        }
    }

    func togglePlay() {
        if engine.isPlaying { engine.stop() } else { engine.play() }
        isPlaying = engine.isPlaying
    }

    func setRecording(_ on: Bool) {
        isRecording = on
        engine.setRecording(on)
    }

    func addLog(_ tag: String, _ text: String, ms: Int? = nil, tint: Tint = .grey) {
        log.append(LogLine(tag: tag, text: text, ms: ms, tint: tint))
        if log.count > 40 { log.removeFirst(log.count - 40) }
    }
}

enum AIStatus { case idle, thinking, arranging, done, failed }

extension AppState {
    func setStatus(_ s: AIStatus, _ text: String = "") {
        aiStatus = s
        aiStatusText = text
        aiStatusAt = Date()
    }
}
