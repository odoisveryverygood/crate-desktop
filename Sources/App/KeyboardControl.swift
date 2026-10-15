import Foundation

/// Physical key layout shared by input handling and the on-screen legends.
enum MusicalTyping {
    static let padKeys = ["z", "x", "c", "v", "a", "s", "d", "f", "q", "w", "e", "r", "1", "2", "3", "4"]
    static let noteKeys = ["a", "w", "s", "e", "d", "f", "t", "g", "y", "h", "u", "j", "k", "o", "l", "p", ";", "'"]
    static func baseMidi(octave: Int) -> Int { 48 + 12 * octave }
    static func label(midi: Int, octave: Int) -> String {
        let offset = midi - baseMidi(octave: octave)
        return noteKeys.indices.contains(offset) ? noteKeys[offset].uppercased() : ""
    }
    static func snap(_ midi: Int, scaleKey: String?, locked: Bool) -> Int {
        guard locked, let key = Music.parseKey(scaleKey) else { return midi }
        let scale = Set(Music.scale(pc: key.pc, minor: key.minor))
        let pc = ((midi % 12) + 12) % 12
        if scale.contains(pc) { return midi }
        if scale.contains((pc + 11) % 12) { return midi - 1 }
        if scale.contains((pc + 1) % 12) { return midi + 1 }
        return midi
    }
}

/// Stores the original target of each down event so key-up never releases a different bank/note.
@MainActor
final class KeyboardPlayer {
    let state: AppState
    var focusPrompt: (() -> Void)?
    var selectMode: ((Mode) -> Void)?
    var selectBank: ((Bank) -> Void)?
    var playedNote: ((Int, Int) -> Void)?
    private struct Held {
        var pad: PadID
        var visualPad: PadID?
        var note: Int?
    }
    private var down = Set<String>()
    private var held: [String: Held] = [:]

    init(state: AppState) { self.state = state }

    @discardableResult
    func press(_ key: String, shift: Bool = false) -> Bool {
        guard !state.promptFocused else { return false }
        let key = key.lowercased()
        let known = [" ", "\r", "\t", "/", "\u{1b}"].contains(key)
            || (state.mode == .keys ? MusicalTyping.noteKeys.contains(key) || ["z", "x", "c", "v"].contains(key)
                                     : MusicalTyping.padKeys.contains(key))
        guard known else { return false }
        guard down.insert(key).inserted else { return true }
        switch key {
        case " ": CrateUI.shared.playPausePressed(state)   // same as the ▶ / ❚❚ key
        case "\r": CrateUI.shared.recPressed(state)
        case "\t":
            releaseAll()
            if shift {
                let modes: [Mode] = [.seq, .keys]   // the deck's modes; SAMPLE and FX are keys of their own
                let next = modes[((modes.firstIndex(of: state.mode) ?? 0) + 1) % modes.count]
                if let selectMode { selectMode(next) } else { state.mode = next }
            } else {
                let next = Bank(rawValue: (state.bank.rawValue + 1) % 4)!
                if let selectBank { selectBank(next) } else { state.bank = next }
            }
            down.insert(key)
        case "/":
            releaseAll()
            state.promptFocused = true
            focusPrompt?()
        case "\u{1b}": releaseAll()
        default:
            if state.mode == .keys {
                switch key {
                case "z", "x":
                    releaseAll()
                    state.keysOctave = min(4, max(-3, state.keysOctave + (key == "z" ? -1 : 1)))
                    down.insert(key)
                case "c": state.keyVelocity = max(1, state.keyVelocity - 10)
                case "v": state.keyVelocity = min(127, state.keyVelocity + 10)
                default:
                    guard let offset = MusicalTyping.noteKeys.firstIndex(of: key) else { return false }
                    let note = MusicalTyping.baseMidi(octave: state.keysOctave) + offset
                    let played = MusicalTyping.snap(note, scaleKey: state.scaleKey, locked: state.scaleLock)
                    let pad = state.selectedPad
                    let sound = state.sound(pad)
                    let root = sound?.rootNote ?? ((sound?.category == .bass || sound?.category == .eight08) ? 36 : 60)
                    held[key] = Held(pad: pad, note: note)
                    state.heldNotes.insert(note)
                    state.hit(pad, velocity: state.keyVelocity, semitones: Double(played - root))
                    state.lastNoteName = Music.name(played)
                    playedNote?(played, played - root)
                    DebugLog.event("keys", ["note": played, "semi": played - root, "input": "keyboard"])
                }
            } else if let index = MusicalTyping.padKeys.firstIndex(of: key) {
                let visual = PadID(state.bank, index)
                let target = state.mode == .levels16 ? state.selectedPad : visual
                held[key] = Held(pad: target, visualPad: visual)
                state.heldPads.insert(visual)
                if state.mode != .levels16 { state.selectedPad = target }
                state.hit(target, velocity: state.keyVelocity, semitones: state.mode == .levels16 ? Double(index - 7) : 0)
            }
        }
        return true
    }

    @discardableResult
    func release(_ key: String) -> Bool {
        let key = key.lowercased()
        let consumed = down.remove(key) != nil
        guard let old = held.removeValue(forKey: key) else { return consumed }
        if let pad = old.visualPad { state.heldPads.remove(pad) }
        if let note = old.note { state.heldNotes.remove(note) }
        if !held.values.contains(where: { $0.pad == old.pad }) { state.engine.release(old.pad) }
        return true
    }

    func releaseAll() {
        let pads = Set(held.values.map(\.pad))
        held.removeAll()
        down.removeAll()
        state.heldPads.removeAll()
        state.heldNotes.removeAll()
        for pad in pads { state.engine.release(pad) }
    }
}

#if canImport(UIKit)
import SwiftUI
import UIKit

struct KeyboardControl: UIViewRepresentable {
    let state: AppState
    func makeUIView(context: Context) -> KeyboardInputView {
        let view = KeyboardInputView(state: state)
        view.player.focusPrompt = { CrateUI.shared.focusRequest += 1 }
        view.player.selectMode = { CrateUI.shared.setMode($0, state) }
        view.player.selectBank = { CrateUI.shared.selectBank($0, state) }
        view.player.playedNote = { CrateUI.shared.lastMidi = $0; CrateUI.shared.lastSemi = $1 }
        return view
    }
    func updateUIView(_ view: KeyboardInputView, context: Context) {
        // Read observable fields here; synchronize outside SwiftUI's update pass.
        let signature = "\(state.mode.rawValue):\(state.bank.rawValue):\(state.keysOctave):\(state.promptFocused)"
        DispatchQueue.main.async { view.synchronize(signature: signature) }
    }
    static func dismantleUIView(_ view: KeyboardInputView, coordinator: ()) { view.player.releaseAll() }
}

final class KeyboardInputView: UIView {
    let player: KeyboardPlayer
    private var signature = ""
    private var keyNames: [UIKeyboardHIDUsage: String] = [:]
    override var canBecomeFirstResponder: Bool { true }

    init(state: AppState) {
        player = KeyboardPlayer(state: state)
        super.init(frame: .zero)
        isUserInteractionEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(deactivate), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(activate), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func didMoveToWindow() { super.didMoveToWindow(); activate() }
    @objc private func deactivate() { player.releaseAll(); keyNames.removeAll() }
    @objc private func activate() { DispatchQueue.main.async { [weak self] in self?.takeFocus() } }

    func synchronize(signature: String) {
        if self.signature != signature { player.releaseAll(); self.signature = signature }
        if player.state.promptFocused {
            if isFirstResponder { _ = resignFirstResponder() }
        } else { takeFocus() }
    }
    private func takeFocus() {
        guard window != nil, !player.state.promptFocused, !isFirstResponder,
              window?.rootViewController?.presentedViewController == nil else { return }
        // Never take focus from a text field, including fields outside the DIG prompt.
        func hasEditor(_ view: UIView) -> Bool {
            if view.isFirstResponder && view is UITextInput { return true }
            return view.subviews.contains(where: hasEditor)
        }
        guard let window, !hasEditor(window) else { return }
        let acquired = becomeFirstResponder()
        DebugLog.event("keyboard_focus", ["acquired": acquired])
    }
    override func resignFirstResponder() -> Bool {
        deactivate()
        return super.resignFirstResponder()
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty else {
                unhandled.insert(press); continue
            }
            let name: String
            switch key.keyCode {
            case .keyboardReturnOrEnter: name = "\r"
            case .keyboardTab: name = "\t"
            case .keyboardEscape: name = "\u{1b}"
            default: name = key.charactersIgnoringModifiers.lowercased()
            }
            if keyNames[key.keyCode] != nil { continue }
            if player.press(name, shift: key.modifierFlags.contains(.shift)) { keyNames[key.keyCode] = name }
            else { unhandled.insert(press) }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let code = press.key?.keyCode, let name = keyNames.removeValue(forKey: code) { player.release(name) }
            else { unhandled.insert(press) }
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { pressesEnded(presses, with: event) }
}
#endif
