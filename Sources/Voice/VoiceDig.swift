import AVFoundation
import Foundation
import Observation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Pull a pad (or a BANK key) down and talk. Touch-down plays the pad as always; if that finger then slides down,
/// a voice panel rises from the bottom of the screen with the drag (`VoicePullPanel`): a thin line that thickens,
/// brightens and starts to move as you pull, while the beat ducks. Past the threshold (haptic + bloom) the mic
/// listens: the line becomes the live waveform and the words show big. Lift = the request goes out at once, aimed at
/// that pad / bank (`AppState.digTargeted`). Back above the threshold = "release to cancel"; lifted before it =
/// nothing. A tap anywhere (when no finger is pulling) or a swipe down closes it; a 20 s watchdog closes it whatever
/// happens. Problems (mic off, nothing heard) close the panel and leave a short note on the pad line.
/// The AI side is the orchestrator's; this only listens and hands over the words.
@MainActor
@Observable
final class VoiceDig {
    static let shared = VoiceDig()

    /// A pad touch becomes a pull once its finger is this far down (and moving mostly down).
    static let pullStart: CGFloat = 12

    /// Pull distance that opens the mic: 70 pt on big phones, less on small screens, and never more than the room
    /// left between the finger and the bottom edge (the bank keys sit low).
    static func threshold(touchY: CGFloat) -> CGFloat {
        let h = windowHeight
        let base = min(70, max(52, h * 0.075))
        return max(32, min(base, h - touchY - 10))
    }

    private static var windowHeight: CGFloat {
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return (scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first)?.bounds.height ?? 800
        #else
        return NSApp.keyWindow?.contentView?.bounds.height ?? 800
        #endif
    }

    /// The beat ducks this far while the mic is open (scaled by the pull before that).
    static let duckDB: Float = -18
    /// Listening with no words for this long closes the panel.
    static let silenceTimeout: Double = 6
    /// Nothing changing for this long closes the panel, whatever state it's in.
    static let watchdogTimeout: Double = 20

    enum Target: Equatable {
        case pad(PadID), bank(Bank)
        var pad: PadID? { if case .pad(let p) = self { return p } else { return nil } }
        var bank: Bank? { if case .bank(let b) = self { return b } else { return nil } }
        var label: String {
            switch self {
            case .pad(let p): return p.key
            case .bank(let b): return "BANK \(b.letter)"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        /// Finger down, not yet past the threshold: the line builds with the drag.
        case pulling
        /// Past the threshold: the mic is on and the words show live.
        case listening
        /// Was listening, pushed back above the threshold: "release to cancel".
        case cancelling
        /// Lifted: waiting (≤ 300 ms) for the final words.
        case finishing
        /// Sent: the panel collapses into "A3 ← rusty drum", then drops away.
        case sent
    }

    struct Sent: Equatable {
        var target: Target
        var text: String
        var at: Date
    }

    /// A short message on the pad line after the panel closed itself ("DIDN'T HEAR ANYTHING").
    struct Note: Equatable {
        var text: String
        /// Tapping the line opens Settings (the mic is off).
        var settings = false
        var at = Date()
    }

    private(set) var phase: Phase = .idle
    /// The phase the panel draws: the current one, or the last one while it slides away.
    private(set) var face: Phase = .idle
    /// The pad / bank being talked to (kept after the panel closes so it can slide away intact).
    private(set) var target: Target?
    /// Pull distance ÷ threshold: 0 … 1 = the mic opens … more = rubber band.
    private(set) var progress: Double = 0
    /// The words so far (volatile results included).
    private(set) var transcript = ""
    /// The last request handed over ("A3 ← rusty drum"), shown on the pad line while the AI works.
    private(set) var sent: Sent?
    /// A short note on the pad line.
    private(set) var note: Note?
    /// When the mic woke (crossed the threshold): drives the bloom.
    private(set) var wokeAt: Date?
    /// The one-time "drag a pad down" hint on the pad line.
    private(set) var hint = false

    @ObservationIgnored private var threshold: CGFloat = 70
    @ObservationIgnored private var serial = 0
    /// Mic + recognizer running for this pull (started as soon as the pull begins, so the threshold is instant).
    @ObservationIgnored private var capturing = false
    /// The mic is faked: debug commands, and `-crateSilentAudio 1` (no audio hardware in that mode).
    @ObservationIgnored private var fakeMic = false
    /// Driven by `crate://voice` / `crate://voicepull` (no permission checks, the words come from the command).
    @ObservationIgnored private var scripted = false
    @ObservationIgnored private var warmError: String?
    @ObservationIgnored private var hintShownThisLaunch = false
    /// The finger that owns the pull: a pad touch (checked live in `TouchTrackingView`) or a BANK key's drag.
    @ObservationIgnored private var pullTouch: ObjectIdentifier?
    @ObservationIgnored private var bankHeld = false
    /// Last time anything moved (phase, progress, words): the watchdog's clock.
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var listenAt = Date()
    /// Ducking: the engine whose main mixer is lowered, its volume before, and a ramp counter.
    @ObservationIgnored private weak var duckEngine: AudioEngine?
    @ObservationIgnored private var duckSaved: Float?
    @ObservationIgnored private var duckGen = 0

    var listening: Bool { phase == .listening || phase == .cancelling }
    /// True while a finger owns the panel (pulling, listening or cancelling).
    var pulling: Bool { phase == .pulling || phase == .listening || phase == .cancelling }
    var level: Double {
        fakeMic ? 0.35 + 0.3 * abs(sin(Date().timeIntervalSinceReferenceDate * 7)) : SpeechService.shared.level
    }

    /// The pad / bank mark while pulling: nil = none, else the pull progress (≥ 1 = listening).
    func mark(for pad: PadID) -> Double? {
        guard target == .pad(pad), pulling else { return nil }
        return phase == .listening ? max(1, progress) : progress
    }

    func mark(bank: Bank) -> Double? {
        guard target == .bank(bank), pulling else { return nil }
        return phase == .listening ? max(1, progress) : progress
    }

    /// Pulling talks only on the plain pads: not while SAMPLE is armed (hold = record), not on the KEYS, FX or
    /// MUTE layers, not while REC is on or the prompt is being typed.
    static func allowed(_ state: AppState) -> Bool {
        let ui = CrateUI.shared
        return !ui.sampleArmed && !ui.fxLayer && !ui.muteLayer && ui.recordingPad == nil && ui.countIn == nil
            && !state.isRecording && state.mode != .keys && state.mode != .levels16 && !ui.promptFocused
    }

    // MARK: The gesture

    /// The finger moved far enough down: the panel starts to rise and the mic warms up (if it's allowed already).
    /// `touch` = the pad finger (nil = a BANK key, whose drag reports its own end).
    @discardableResult
    func pullBegan(_ t: Target, threshold: CGFloat, touch: ObjectIdentifier? = nil, state: AppState) -> Bool {
        guard Self.allowed(state) else { return false }
        start(t, threshold: threshold, fake: AppConfig.silentAudio, scripted: false)
        pullTouch = touch
        bankHeld = touch == nil
        beginDuck(state)
        if CrateMicrophone.permission == .granted { warmError = startCapture() }
        DebugLog.event("voice_pull", ["target": t.label, "threshold": Int(threshold), "fakeMic": fakeMic])
        return true
    }

    /// `dy` = how far the finger is below where it went down.
    func pullMoved(_ dy: CGFloat) {
        guard pulling else { return }
        let p = max(0, Double(dy / max(1, threshold)))
        if abs(p - progress) > 0.002 { lastActivity = Date() }
        progress = p
        setDuck(phase == .listening ? 1 : min(1, p))
        switch phase {
        case .pulling where p >= 1:
            cross()
        case .listening where p < 0.85:
            setPhase(.cancelling)
            UISelectionFeedbackGenerator().selectionChanged()
        case .cancelling where p >= 1:
            setPhase(.listening)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        default:
            break
        }
    }

    /// The finger lifted (or the touch was cancelled).
    func pullEnded(state: AppState) {
        pullTouch = nil
        bankHeld = false
        switch phase {
        case .pulling:
            close("short")
        case .cancelling:
            close("cancel")
        case .listening:
            finish(state)
        default:
            break
        }
    }

    /// Whether the finger that started this pull is still on the glass.
    private var fingerDown: Bool {
        guard pulling else { return false }
        if let id = pullTouch { return TouchTrackingView.isDown(id) }
        return bankHeld
    }

    /// A tap (or swipe) anywhere while the panel is up: closes it, unless the pull's own finger is still down.
    func tapOutside() {
        guard phase != .idle else { return }
        if fingerDown { return }
        DebugLog.event("voice_dismiss", ["phase": "\(phase)"])
        if phase == .listening || phase == .cancelling || phase == .pulling {
            Analytics.shared.track("voice_pull", ["outcome": "dismiss"])
        }
        close("tap")
    }

    /// Past the threshold: haptic + bloom, then the mic (asking for it the first time).
    private func cross() {
        if !scripted {
            neverHintAgain()
            switch CrateMicrophone.permission {
            case .denied:
                Analytics.shared.track("voice_pull", ["outcome": "denied"])
                close("denied", note: Note(text: Self.micOff, settings: true))
                return
            case .undetermined:
                // the system alert takes over; the panel gets out of its way
                close("asking")
                Task { @MainActor in
                    let ok = await CrateMicrophone.requestPermission()
                    DebugLog.event("voice_permission", ["granted": ok])
                    self.setNote(ok ? Note(text: "MIC IS ON · PULL A PAD DOWN AND TALK")
                                    : Note(text: Self.micOff, settings: true))
                }
                return
            default:
                break
            }
        }
        if let err = warmError ?? startCapture() {
            warmError = nil
            close("error", note: Note(text: err, settings: err == Self.micOff || err == Self.speechOff))
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        wokeAt = Date()
        listenAt = Date()
        setDuck(1)
        setPhase(.listening)
        DebugLog.event("voice_begin", ["target": target?.label ?? "", "fakeMic": fakeMic])
        if fakeMic, !scripted, let words = AppConfig.devString("crateVoiceText"), !words.isEmpty {
            type(words, serial: serial)   // dev: a real drag on a silent simulator "hears" -crateVoiceText
        }
    }

    /// Lifted while listening: take the final words (or the latest live ones) and send them.
    private func finish(_ state: AppState) {
        guard let t = target else { return }
        setPhase(.finishing)
        progress = 1
        restoreDuck()
        let s = serial
        let fake = fakeMic
        Task { @MainActor in
            let heard = fake ? self.transcript : await SpeechService.shared.finish(timeout: 0.3)
            guard self.serial == s else { return }
            self.capturing = false
            let text = (heard.isEmpty ? self.transcript : heard)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !text.isEmpty else {
                DebugLog.event("voice_empty", ["target": t.label])
                Analytics.shared.track("voice_pull", ["outcome": "empty"])
                self.close("empty", note: Note(text: "DIDN'T CATCH THAT · TALK WHILE YOU PULL"))
                return
            }
            self.transcript = text
            self.sent = Sent(target: t, text: text, at: Date())
            self.note = nil
            self.setPhase(.sent)
            state.addLog("VOICE", "\(t.label) ← \(text)", tint: .orange)
            DebugLog.event("voice_send", ["target": t.label, "text": text])
            state.digTargeted(text, pad: t.pad, bank: t.bank)
            self.autoClose(after: 0.9)
        }
    }

    // MARK: Panel state

    private func start(_ t: Target, threshold th: CGFloat, fake: Bool, scripted s: Bool) {
        stopCapture()
        serial += 1
        target = t
        threshold = th
        progress = 0
        transcript = ""
        warmError = nil
        wokeAt = nil
        fakeMic = fake || s
        scripted = s
        hint = false
        note = nil
        pullTouch = nil
        bankHeld = false
        setPhase(.pulling)
        watch(serial)
    }

    private func setPhase(_ p: Phase) {
        if p != phase { lastActivity = Date() }
        phase = p
        if p != .idle { face = p }
    }

    /// The panel slides away (the finger let go early, cancelled, dismissed, or something went wrong — then `note`
    /// goes on the pad line).
    func close(_ why: String = "", note n: Note? = nil) {
        guard phase != .idle else { if let n { setNote(n) }; return }
        if !why.isEmpty {
            DebugLog.event("voice_close", ["why": why, "progress": (progress * 100).rounded() / 100])
            if why == "cancel" { Analytics.shared.track("voice_pull", ["outcome": "cancel"]) }
        }
        serial += 1
        pullTouch = nil
        bankHeld = false
        stopCapture()
        restoreDuck()
        setPhase(.idle)
        if let n { setNote(n) }
    }

    private func autoClose(after seconds: Double) {
        let s = serial
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard self.serial == s else { return }
            self.close()
        }
    }

    /// One watchdog per pull: silence while listening closes it with a note; nothing changing for 20 s closes it.
    private func watch(_ s: Int) {
        lastActivity = Date()
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .milliseconds(500))
                guard self.serial == s, self.phase != .idle else { return }
                let now = Date()
                if self.phase == .listening, self.transcript.isEmpty, !self.scripted,
                   now.timeIntervalSince(self.listenAt) > Self.silenceTimeout {
                    Analytics.shared.track("voice_pull", ["outcome": "silence"])
                    self.close("silence", note: Note(text: "DIDN'T HEAR ANYTHING · PULL AGAIN AND TALK"))
                    return
                }
                if now.timeIntervalSince(self.lastActivity) > Self.watchdogTimeout {
                    DebugLog.event("voice_watchdog", ["phase": "\(self.phase)"])
                    self.close("watchdog")
                    return
                }
            }
        }
    }

    private func setNote(_ n: Note) {
        note = n
        let at = n.at
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(n.settings ? 6 : 3.5))
            if self.note?.at == at { self.note = nil }
        }
    }

    func clearNote() { note = nil }

    static let micOff = "MIC IS OFF FOR CRATE · TAP FOR SETTINGS"
    static let speechOff = "SPEECH RECOGNITION IS OFF · TAP FOR SETTINGS"

    /// One quiet line from elsewhere (SAMPLE with the mic off): same spot and behaviour as the panel's notes.
    func show(_ text: String, settings: Bool = false) { setNote(Note(text: text, settings: settings)) }

    // MARK: Ducking

    /// Remember the main mixer's volume (unless a previous duck is still ramping back: keep its original).
    private func beginDuck(_ state: AppState) {
        guard let e = state.engine as? AudioEngine else { return }
        duckGen += 1
        if duckSaved == nil || duckEngine !== e { duckSaved = e.engine.mainMixerNode.outputVolume }
        duckEngine = e
    }

    /// 0 = full level … 1 = −18 dB.
    private func setDuck(_ k: Double) {
        guard let e = duckEngine, let saved = duckSaved else { return }
        let g = pow(10, Self.duckDB * Float(max(0, min(1, k))) / 20)
        e.engine.mainMixerNode.outputVolume = saved * g
    }

    /// Back to exactly the volume before, over ~120 ms.
    private func restoreDuck() {
        guard let e = duckEngine, let saved = duckSaved else { return }
        duckGen += 1
        let gen = duckGen
        let from = e.engine.mainMixerNode.outputVolume
        Task { @MainActor in
            let steps = 8
            for i in 1...steps {
                try? await Task.sleep(for: .milliseconds(15))
                guard self.duckGen == gen else { return }
                let k = Float(i) / Float(steps)
                e.engine.mainMixerNode.outputVolume = i == steps ? saved : from + (saved - from) * k
            }
            DebugLog.event("voice_duck", ["restored": Double(e.engine.mainMixerNode.outputVolume), "from": Double(from)])
            self.duckSaved = nil
            self.duckEngine = nil
        }
    }

    // MARK: Mic

    /// Starts the mic + recognizer for this pull; returns a message if it can't.
    private func startCapture() -> String? {
        guard !capturing else { return nil }
        if fakeMic { capturing = true; return nil }
        let s = serial
        do {
            try SpeechService.shared.start(onText: { [weak self] text in
                guard let self, self.serial == s, self.capturing else { return }
                if text != self.transcript { self.lastActivity = Date() }
                self.transcript = text
            }, onFail: { [weak self] _ in
                guard let self, self.serial == s else { return }
                self.capturing = false
                if self.listening {
                    self.close("mic_error", note: Note(text: "NO MIC INPUT · TRY AGAIN"))
                } else {
                    self.warmError = "NO MIC INPUT · TRY AGAIN"
                }
            })
            capturing = true
            return nil
        } catch {
            DebugLog.event("voice_error", ["error": "\(error)"])
            switch error as? SpeechService.StartError {
            case .micDenied?: return Self.micOff
            case .micUndetermined?: return "ALLOW THE MIC, THEN PULL AGAIN"
            case .speechDenied?: return Self.speechOff
            case .speechUndetermined?: return "ALLOW SPEECH RECOGNITION, THEN PULL AGAIN"
            case .recognizerUnavailable?: return "VOICE ISN'T AVAILABLE RIGHT NOW · TYPE IT INSTEAD"
            default: return "NO MIC INPUT · TRY AGAIN"
            }
        }
    }

    private func stopCapture() {
        guard capturing else { return }
        capturing = false
        if !fakeMic { SpeechService.shared.cancel() }
    }

    /// Fake words, one at a time (debug only).
    private func type(_ text: String, serial s: Int) {
        let words = text.split(separator: " ").map(String.init)
        Task { @MainActor in
            for i in words.indices {
                try? await Task.sleep(for: .milliseconds(140))
                guard self.serial == s, self.listening else { return }
                self.transcript = words[0...i].joined(separator: " ")
                self.lastActivity = Date()
            }
        }
    }

    // MARK: Pad line

    /// The pad line goes back to the selected pad.
    func clearLine() { sent = nil }

    /// Keeps "A3 ← …" up while the AI works (at least 2.5 s, at most 12 s).
    func expireLine(_ state: AppState) async {
        guard let since = sent?.at else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            let age = Date().timeIntervalSince(since)
            if age > 12 || (age > 2.5 && !state.isDigging) { clearLine(); return }
        }
    }

    /// Hint key: set once the pad-gesture hint has shown (or the first real pull happened): it never shows again.
    static let hintKey = "crateGestureHintShown"

    /// The first beat: one faint hint on the pad line for a few seconds, once ever ("swipe a pad ← → for another
    /// sound · ↑ to remove · ↓ to talk").
    func digFinished() {
        guard !hintShownThisLaunch, !UserDefaults.standard.bool(forKey: Self.hintKey), phase == .idle, sent == nil
        else { return }
        hintShownThisLaunch = true
        UserDefaults.standard.set(true, forKey: Self.hintKey)
        hint = true
        DebugLog.event("voice_hint", [:])
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(7))
            self.hint = false
        }
    }

    private func neverHintAgain() {
        hint = false
        UserDefaults.standard.set(true, forKey: Self.hintKey)
    }

    // MARK: Debug

    /// `crate://voice?pad=A3&text=…` / `?bank=a&text=…`: a pull without a finger or a mic. Same path: the panel
    /// rises with an animated drag, crosses the threshold, the words appear one by one, then the release sends them.
    func simulate(_ t: Target, text: String, state: AppState) {
        select(t, state)
        start(t, threshold: 70, fake: true, scripted: true)
        beginDuck(state)
        DebugLog.event("voice_pull", ["target": t.label, "threshold": 70, "scripted": true])
        let s = serial
        Task { @MainActor in
            let frames = 24
            for k in 1...frames {
                try? await Task.sleep(for: .milliseconds(16))
                guard self.serial == s else { return }
                let x = Double(k) / Double(frames)
                self.pullMoved(CGFloat(82 * (1 - pow(1 - x, 3))))
            }
            let words = text.split(separator: " ").map(String.init)
            for i in words.indices {
                try? await Task.sleep(for: .milliseconds(140))
                guard self.serial == s else { return }
                self.transcript = words[0...i].joined(separator: " ")
            }
            try? await Task.sleep(for: .milliseconds(350))
            guard self.serial == s else { return }
            self.pullEnded(state: state)
        }
    }

    /// `crate://voicepull?pad=A3&p=0.5[&text=…][&phase=cancel|finishing|sent|denied|empty|silence]`: holds the panel
    /// at a pull progress for screenshots (p ≥ 1 = listening). `p=0` closes it. No finger owns a pose, so a tap
    /// dismisses it; the watchdog closes it after 20 s. denied / empty / silence = the pad-line notes.
    func pose(_ t: Target, progress p: Double, text: String, phase name: String?, state: AppState) {
        guard p > 0 || name != nil else { close(); return }
        select(t, state)
        switch name {
        case "denied": close(note: Note(text: Self.micOff, settings: true)); return
        case "empty": close(note: Note(text: "DIDN'T CATCH THAT · TALK WHILE YOU PULL")); return
        case "silence": close(note: Note(text: "DIDN'T HEAR ANYTHING · PULL AGAIN AND TALK")); return
        default: break
        }
        start(t, threshold: 70, fake: true, scripted: true)
        progress = p
        transcript = text
        switch name {
        case "cancel": setPhase(.cancelling)
        case "finishing": setPhase(.finishing)
        case "sent":
            sent = Sent(target: t, text: text, at: Date())
            setPhase(.sent)
        default:
            if p >= 1 { wokeAt = Date() }
            setPhase(p >= 1 ? .listening : .pulling)
        }
        DebugLog.event("voice_pose", ["target": t.label, "p": p, "phase": name ?? ""])
    }

    private func select(_ t: Target, _ state: AppState) {
        if let b = t.bank ?? t.pad?.bank, state.bank != b { state.bank = b }
        if let p = t.pad { state.selectedPad = p }
    }
}
