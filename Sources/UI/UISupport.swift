import SwiftUI
import Observation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// UI-only state shared by the lid and the deck (RootView hosts them as separate views).
@Observable
final class CrateUI {
    static let shared = CrateUI()

    /// The prompt draft (lid and compact prompt fields share it).
    var draft = ""
    /// ✦ DIG bumps this; the visible prompt field focuses itself.
    var focusRequest = 0
    /// Bumped to dismiss the keyboard (a chip was tapped).
    var blurRequest = 0
    /// Mirrors the prompt field's focus (the lid hides its chips while typing).
    var promptFocused = false
    /// The on-screen keyboard in window coordinates (`.null` while it's hidden). A lid whose bottom it covers
    /// lifts its prompt above it (book pose, phone landscape), so there's never a second copy of the field.
    var keyboardFrame = CGRect.null
    /// SHIFT latch: pad touches select the pad without playing it.
    var shift = false
    /// Last KEYS note (for the lid's NOTE / SEMI readout).
    var lastMidi: Int? = nil
    var lastSemi: Int? = nil
    /// LEVEL fader per pad, 0…1 (cosmetic unless `onLevel` is wired).
    var levels: [PadID: Double] = [:]
    /// Optional hook for the LEVEL fader (pad, 0…1). The App may wire it to a per-pad gain.
    @ObservationIgnored var onLevel: ((PadID, Double) -> Void)?
    /// Optional hook for the PAD FX PUNCH fader (0…1), e.g. `{ hinge.apply($0) }` so the fader shares the
    /// hinge's smoothing + DROP detection. Unset → the fader drives state.punch + engine.setPunch directly.
    @ObservationIgnored var onPunch: ((Double) -> Void)?
    /// Running on an iPhone Duo (fold or hinge seen). False on iPhone / iPad: no hinge, no back screen.
    private(set) var isDuo = DeviceInfo.simulatorDuo || DeviceInfo.rememberedDuo

    func level(_ pad: PadID) -> Double { levels[pad] ?? 0.66 }

    @ObservationIgnored private var keyboardObservers: [NSObjectProtocol] = []

    init() {
        #if os(iOS)
        let nc = NotificationCenter.default
        keyboardObservers = [
            nc.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] n in
                guard let r = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                MainActor.assumeIsolated { self?.keyboardFrame = Self.inWindow(r) }
            },
            nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardFrame = .null }
            },
        ]
        #endif
    }

    /// Keyboard frames arrive in screen coordinates; SwiftUI's global space is the window's (they differ in an iPad window).
    @MainActor private static func inWindow(_ r: CGRect) -> CGRect {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let w = scenes.lazy.compactMap(\.keyWindow).first ?? scenes.first?.windows.first else { return r }
        return w.convert(r, from: w.screen.coordinateSpace)
        #else
        return .null
        #endif
    }

    /// How far the keyboard covers the bottom of a view at `frame` (global coordinates); 0 when it doesn't.
    func keyboardOverlap(_ frame: CGRect) -> CGFloat {
        let k = keyboardFrame
        guard !k.isNull, k.height > 0, k.minX < frame.maxX, k.maxX > frame.minX else { return 0 }
        return max(0, frame.maxY - k.minY)
    }

    // MARK: Sampling (SAMPLE arm, FX layer, pad editor, count-in)

    /// SAMPLE is armed: the pads blink, and holding one records the mic into that pad.
    var sampleArmed = false
    /// The pad a finger is recording into right now.
    var recordingPad: PadID? = nil
    /// Slid up while recording: the take keeps going hands-free (to play an instrument into the mic) until a pad,
    /// the pad line's STOP or the ❚❚ transport key is tapped.
    var recordLocked = false
    /// FX layer over the pads: up while the FX key is held, or latched by a quick tap for one pick.
    var fxHeld = false
    var fxLatched = false
    var fxLayer: Bool { fxHeld || fxLatched }
    /// MUTE layer over the pads (held, or latched by a quick tap until tapped again): a pad / BANK tap mutes it.
    var muteHeld = false
    var muteLatched = false
    var muteLayer: Bool { muteHeld || muteLatched }
    @ObservationIgnored var muteDownAt: Date?
    /// The pad editor page (lid waveform + START / END knobs on the deck) for the selected pad.
    var editorOpen = false
    /// FLIP IT glows after a song import, until it's tapped or a new beat is dug.
    var flipHint = false
    /// Beats left in the count-in (4…1) before REC starts; nil when not counting in.
    var countIn: Int? = nil
    /// The bar the step grid shows and edits (0-based); nil = ALL (the grid follows the playhead and a step edit goes
    /// into every bar). Also where PLAY starts when stopped.
    var viewBar: Int? = nil
    /// The SONG sheet (tempo, swing, key, click, velocity): the BPM chip / hero number opens it.
    var songSheetOpen = false
    /// Live START / END (seconds) while a handle or knob is being dragged in the pad editor; committed on release.
    var editPreviewStart: Double? = nil
    var editPreviewEnd: Double? = nil
    @ObservationIgnored var sampler: MicSampler?
    @ObservationIgnored private var fxDownAt: Date?

    /// SAMPLE key: arm or disarm. Asks for the microphone on arming, so the prompt never lands mid-take.
    @MainActor func toggleSample(_ state: AppState) {
        if sampleArmed {
            sampleArmed = false
            DebugLog.event("sample_arm", ["on": false])
            return
        }
        fxLatched = false
        muteLatched = false
        Task { @MainActor in
            guard await MicSampler.requestPermission() else {
                state.addLog("SAMPLE", "the mic is off for CRATE · turn it on in Settings", tint: .grey)
                VoiceDig.shared.show(VoiceDig.micOff, settings: true)   // tap the line → Settings
                return
            }
            self.sampleArmed = true
            state.addLog("SAMPLE", "hold any pad to record into it", tint: .grey)
            DebugLog.event("sample_arm", ["on": true])
        }
    }

    /// A finger goes down on a pad while SAMPLE is armed.
    @MainActor func beginTake(_ pad: PadID) {
        guard sampleArmed, recordingPad == nil, let sampler else { return }
        recordingPad = pad
        sampler.startRecording(intoPad: true)
        DebugLog.event("take_start", ["pad": "\(pad.bank.letter)\(pad.number)"])
    }

    /// The finger lifts: the take lands on that pad, SAMPLE disarms and the editor opens on the new sound.
    /// A tap too short to be a take changes nothing and leaves SAMPLE armed.
    @MainActor func endTake(_ pad: PadID) {
        guard recordingPad == pad, let sampler else { return }
        recordingPad = nil
        recordLocked = false
        sampleArmed = false
        Task { @MainActor in
            switch await sampler.stopRecording(intoPad: pad) {
            case .placed: self.editorOpen = true
            case .tooShort: self.sampleArmed = true
            case .failed: break
            }
        }
    }

    /// ● REC. Stopped: a bar of count-in clicks, then play + record (from the viewed bar). Playing: record from now.
    /// Recording: stop recording and keep playing. Each pass is one UNDO step.
    @MainActor func recPressed(_ state: AppState) {
        if CountIn.shared.isCounting {   // tapped again during the count-in: never mind
            cancelCountIn(state)
            if state.engine.isPlaying { state.engine.stop() }
            state.isPlaying = false
            return
        }
        if state.isRecording {
            state.setRecording(false)
            Orchestrator.current?.syncFromEngine()
            DebugLog.event("rec", ["on": false])
            return
        }
        Orchestrator.current?.leaveSong()   // REC writes into the beat, never into the rendered song
        Orchestrator.current?.checkpoint("recording")
        if state.engine.isPlaying {
            state.setRecording(true)
            DebugLog.event("rec", ["on": true, "countIn": false])
            return
        }
        CountIn.shared.start(state, tick: { [weak self] n in self?.countIn = n }, done: { [weak self] in
            self?.countIn = nil
            state.setRecording(true)
            DebugLog.event("rec", ["on": true, "countIn": true])
        }, cancelled: { [weak self] in
            self?.countIn = nil
            state.setRecording(false)
            state.isPlaying = state.engine.isPlaying
        })
    }

    @MainActor private func cancelCountIn(_ state: AppState) {
        guard CountIn.shared.isCounting else { return }
        CountIn.shared.cancel()
        countIn = nil
        state.setRecording(false)
        DebugLog.event("count_in_cancel")
    }

    /// The transport key shows ❚❚ while there's something to stop: playback, a count-in or a hands-free take.
    func transportRunning(_ state: AppState) -> Bool {
        state.engine.isPlaying || countIn != nil || recordLocked
    }

    /// ▶ / ❚❚: the one transport key next to REC. Stopped: play (from the bar the pager shows, else bar 1).
    /// Running: `stopPressed`.
    @MainActor func playPausePressed(_ state: AppState) {
        if transportRunning(state) {
            stopPressed(state)
        } else {
            state.togglePlay()
            DebugLog.event("transport", ["play": true])
        }
    }

    /// Pause (and `crate://stop`): lands a hands-free SAMPLE take, ends a count-in and REC, and stops playback.
    @MainActor func stopPressed(_ state: AppState) {
        if recordLocked, let pad = recordingPad { endTake(pad) }
        cancelCountIn(state)
        countIn = nil
        if state.engine.isPlaying { state.togglePlay() } else { state.isPlaying = false }
        if state.isRecording {
            state.setRecording(false)
            Orchestrator.current?.syncFromEngine()
        }
        DebugLog.event("transport", ["play": false])
    }

    /// Bar pager: view (and edit) one bar, or ALL. Stopped: PLAY / REC start there. Playing: playback jumps to that
    /// bar's downbeat on the next beat. ALL leaves playback alone and starts from bar 1 next time.
    @MainActor func showBar(_ bar: Int?, _ state: AppState) {
        viewBar = bar
        if let bar, state.engine.isPlaying {
            state.engine.jump(toBar: bar)
        } else {
            state.engine.startBar = bar ?? 0
        }
        DebugLog.event("bar_view", ["bar": bar.map { "\($0 + 1)" } ?? "all", "playing": state.engine.isPlaying])
    }

    /// FX key down: the pads show the effects while it's held.
    @MainActor func fxDown() {
        fxDownAt = Date()
        fxHeld = true
        sampleArmed = false
        muteLatched = false
    }

    /// FX key up. A quick tap latches the layer for one pick (useful with one hand or a mouse).
    @MainActor func fxUp() {
        fxHeld = false
        if let t = fxDownAt, Date().timeIntervalSince(t) < 0.3 { fxLatched.toggle() }
        fxDownAt = nil
    }

    /// What was on before a punch-in (put back when the last finger lifts).
    @ObservationIgnored private var punchBase: (fx: FXType?, amount: Double)?

    /// Punch-in FX (as on the EP-133): while a finger holds an effect pad on the FX layer, that effect is on at the
    /// finger's height (top of the pad = full). Lifting puts back what was there: nothing on a phone, the fader's
    /// amount on iPad / Duo.
    @MainActor func punchIn(_ index: Int, amount: Double, _ state: AppState) {
        if punchBase == nil { punchBase = (state.fx, state.punch) }
        state.selectFX(FXType.padLayout[index])
        state.punch = amount
        state.engine.setPunch(amount)
    }

    @MainActor func punchMove(amount: Double, _ state: AppState) {
        guard punchBase != nil else { return }
        state.punch = amount
        state.engine.setPunch(amount)
    }

    @MainActor func punchOut(_ state: AppState) {
        guard let base = punchBase else { return }
        punchBase = nil
        state.selectFX(base.fx)
        state.punch = base.amount
        state.engine.setPunch(base.amount)
        DebugLog.event("punch_out", ["fx": base.fx?.rawValue ?? "punch", "amt": base.amount])
    }

    /// Picks an effect to stay on (router / accessibility; at half amount if the fader is down, so it's heard).
    @MainActor func pickFX(_ index: Int, _ state: AppState) {
        let fx = FXType.padLayout[index]
        state.selectFX(fx)
        if state.punch < 0.05 { onPunch?(0.5) }
    }

    /// Called when a fold or hinge shows up; remembered so the next launch lays out as a Duo right away.
    func markDuo() {
        DeviceInfo.rememberDuo()
        if !isDuo {
            isDuo = true
            DebugLog.event("device", ["duo": true, "machine": DeviceInfo.machine])
        }
    }

    /// ✦ DIG: dig the draft if there is one, otherwise focus the prompt field.
    func digPressed(_ state: AppState) {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            state.dig(t)
            draft = ""
        } else {
            focusRequest += 1
        }
    }

    /// Mode change with the side effects the deck needs (KEYS picks a pitched pad).
    func setMode(_ mode: Mode, _ state: AppState) {
        if mode == .keys { ensurePitchedSelection(state) }
        state.mode = mode
        DebugLog.event("mode", ["m": mode.rawValue])
    }

    /// KEYS plays the selected pad chromatically: if that's a drum, move to the first pitched pad (bank C first).
    func ensurePitchedSelection(_ state: AppState) {
        if state.sound(state.selectedPad)?.category.isPitched == true { return }
        if let p = UIHelpers.firstPitchedPad(state) {
            state.selectedPad = p
            state.bank = p.bank
        }
    }

    /// PAD BANK press. In KEYS mode it also picks that bank's first pitched pad (so B = play a chop chromatically).
    func selectBank(_ bank: Bank, _ state: AppState) {
        state.bank = bank
        if state.mode == .keys {
            if let i = (0..<16).first(where: { state.sound(PadID(bank, $0))?.category.isPitched == true }) {
                state.selectedPad = PadID(bank, i)
            }
        }
        DebugLog.event("bank", ["b": bank.letter])
    }
}

/// One frame of live transport info, polled from the engine inside TimelineViews.
struct LiveFrame {
    let playing: Bool
    let pattern: Pattern
    let bars: Int
    let total: Int
    /// Absolute position in steps.
    let pos: Double
    /// Position inside the pattern (0 ..< total).
    let local: Double
    let stepDur: Double
    let swing: Double
    /// The loop's bars (the edit pattern's). Same as `bars` except in SONG mode, where the engine plays the song.
    let editBars: Int

    init(_ state: AppState) {
        let e = state.engine
        playing = e.isPlaying
        pattern = e.pattern
        bars = max(1, pattern.bars)
        editBars = state.song.songMode ? max(1, state.bars) : bars
        total = bars * 16
        let p = e.position()
        pos = p.isFinite ? max(0, p) : 0
        local = pos.truncatingRemainder(dividingBy: Double(total))
        stepDur = 60 / max(30, e.bpm.isFinite ? e.bpm : 90) / 4
        swing = e.swing
    }

    var step: Int { min(total - 1, Int(local)) }
    var bar: Int { step / 16 }
    var stepInBar: Int { step % 16 }
    var beat: Int { stepInBar / 4 }
    var barBeat: String { "\(bar + 1).\(beat + 1)" }

    func swingDelay(_ s: Int) -> Double { s % 2 == 1 ? max(0, 2 * swing / 100 - 1) : 0 }

    /// Steps elapsed since an event at pattern time `t` (wraps around the loop).
    func age(_ t: Double) -> Double {
        let n = Double(total)
        var d = (local - t).truncatingRemainder(dividingBy: n)
        if d < 0 { d += n }
        return d
    }

    var flashSteps: Double { min(0.9, Theme.flash / stepDur) }

    func hitTime(_ h: Hit, _ pad: PadID) -> Double {
        Double(h.step) + swingDelay(h.step) + h.offset + (pattern.late[pad] ?? 0)
    }

    /// True for ~100 ms after the sequencer plays `pad`.
    func sequencerFlash(_ pad: PadID) -> Bool {
        guard playing else { return false }
        let win = flashSteps
        if let hits = pattern.lanes[pad] {
            for h in hits where age(hitTime(h, pad)) < win { return true }
        }
        if let notes = pattern.notes[pad] {
            for n in notes where age(Double(n.step) + swingDelay(n.step) + (pattern.late[pad] ?? 0)) < win { return true }
        }
        return false
    }

    /// Velocity of the sequencer hit flashing `pad` right now (nil = none), so a ghost note flashes lower than an accent.
    func sequencerFlashVelocity(_ pad: PadID) -> Int? {
        guard playing else { return nil }
        let win = flashSteps
        if let hits = pattern.lanes[pad], let h = hits.first(where: { age(hitTime($0, pad)) < win }) { return h.velocity }
        if let notes = pattern.notes[pad],
           let n = notes.first(where: { age(Double($0.step) + swingDelay($0.step) + (pattern.late[pad] ?? 0)) < win }) {
            return n.velocity
        }
        return nil
    }

    /// Notes of `pad` sounding right now (for lighting keys under a bassline).
    func soundingNotes(_ pad: PadID) -> Set<Int> {
        guard playing, let notes = pattern.notes[pad] else { return [] }
        var out = Set<Int>()
        for n in notes {
            let a = age(Double(n.step) + swingDelay(n.step))
            if a < max(0.5, n.length) { out.insert(n.midi) }
        }
        return out
    }

    /// The bank-B chop most recently started by the sequencer (for the CHOP view).
    func currentChop() -> Int? {
        guard playing else { return nil }
        var best: (Int, Double)? = nil
        for (pad, hits) in pattern.lanes where pad.bank == .b {
            for h in hits {
                let a = age(hitTime(h, pad))
                if best == nil || a < best!.1 { best = (pad.index, a) }
            }
        }
        for (pad, notes) in pattern.notes where pad.bank == .b {
            for n in notes {
                let a = age(Double(n.step))
                if best == nil || a < best!.1 { best = (pad.index, a) }
            }
        }
        return best?.0
    }
}

/// Peak envelopes are cached per pad + sound + resolution (the real engine computes them from buffers).
final class WaveCache {
    static let shared = WaveCache()
    private var store: [String: [Float]] = [:]

    func wave(_ state: AppState, _ pad: PadID, points: Int) -> [Float] {
        let s = state.sound(pad)
        let sid = s.map { "\($0.id)|\($0.fileURL.lastPathComponent)|\($0.start)|\($0.end ?? -1)|\($0.params.hashValue)" } ?? "none"
        let key = "\(pad.bank.rawValue).\(pad.index).\(sid).\(points)"
        if let w = store[key] { return w }
        let w = state.engine.waveform(pad, points: points)
        if w.contains(where: { $0 > 0.002 }) {
            if store.count > 400 { store.removeAll() }
            store[key] = w
        }
        return w
    }
}

enum UIHelpers {
    /// Short MPC-style names for the bank-A slots (BankA.slots order).
    static var bankANames: [String] { BankA.slots.map { slotNames[$0] ?? $0.uppercased() } }
    private static let slotNames = ["kick": "KICK", "kick2": "KICK 2", "snare": "SNR", "clap": "CLAP", "hat": "HAT",
                                    "hat2": "HAT 2", "openhat": "OHAT", "rim": "RIM", "perc": "PERC", "perc2": "PERC 2",
                                    "shaker": "SHKR", "cymbal": "CRSH", "808": "808", "fx": "FX", "vocal": "VOX", "texture": "VINYL"]

    static func padName(_ state: AppState, _ pad: PadID) -> String? {
        guard let s = state.sound(pad) else { return nil }
        let n = s.name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? (pad.bank == .a ? bankANames[pad.index] : "PAD \(pad.number)") : n.uppercased()
    }

    static func laneLabel(_ state: AppState, _ pad: PadID) -> String {
        switch pad.bank {
        case .a: return bankANames[pad.index]
        case .b: return "CHOP"
        case .c, .d:
            if let c = state.sound(pad)?.category {
                switch c {
                case .eight08: return "808"
                case .bass: return "BASS"
                case .keys: return "KEYS"
                case .synth: return "SYNTH"
                case .chop, .loop: return "CHOP"
                default: return String(c.rawValue.prefix(5)).uppercased()
                }
            }
            return pad.bank == .c ? "BASS" : "D\(pad.number)"
        }
    }

    static func firstPitchedPad(_ state: AppState) -> PadID? {
        for bank in [Bank.c, .b, .d, .a] {
            for i in 0..<16 {
                let p = PadID(bank, i)
                if state.sound(p)?.category.isPitched == true { return p }
            }
        }
        return nil
    }

    static func rootNote(_ state: AppState, _ pad: PadID) -> Int {
        if let r = state.sound(pad)?.rootNote { return r }
        switch state.sound(pad)?.category {
        case .eight08?, .bass?: return 36
        default: return 60
        }
    }

    /// Note name with flats; Doto has no ♭ so `flat` defaults to a dot-matrix "b".
    static func noteName(_ midi: Int, flat: String = "b") -> String {
        let names = ["C", "D\(flat)", "D", "E\(flat)", "E", "F", "G\(flat)", "G", "A\(flat)", "A", "B\(flat)", "B"]
        let pc = ((midi % 12) + 12) % 12
        let oct = Int(floor(Double(midi) / 12)) - 1
        return names[pc] + String(oct)
    }

    static func keyDisplay(_ key: String?) -> String? {
        guard let k = Music.parseKey(key) else { return nil }
        let names = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        return names[k.pc] + (k.minor ? " MINOR" : " MAJOR")
    }

    static func signed(_ v: Int) -> String { v > 0 ? "+\(v)" : v < 0 ? "−\(-v)" : "0" }

    static func msText(_ ms: Int) -> String {
        ms >= 1000 ? String(format: "%.1fs", Double(ms) / 1000) : "\(ms)ms"
    }
}
