import SwiftUI

/// Watches the app state and logs the key interactions (Analytics): which screen is up and for how long, transport,
/// mode and bank switches, AI PERFORM, errors the user saw. Starts TapTracker (every tap, no per-button code) and
/// ScreenTracker (sheets stack over this base screen). Kept in one place so the buttons themselves stay analytics-free.
struct AnalyticsObserver: ViewModifier {
    let state: AppState
    @State private var ui = CrateUI.shared
    @State private var lastLog: UUID?
    @State private var tempoFrom: Double?
    @State private var tempoTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear {
                lastLog = state.log.last?.id
                #if os(iOS)
                TapTracker.shared.install(state: state)
                #endif
                ScreenTracker.shared.setBase(screen)
            }
            .onChange(of: screen) { _, s in ScreenTracker.shared.setBase(s) }
            .onChange(of: state.isPlaying) { _, on in Analytics.shared.track(on ? "play" : "stop", ["bars": state.bars]) }
            .onChange(of: state.isRecording) { _, on in Analytics.shared.track(on ? "rec_on" : "rec_off") }
            .onChange(of: state.bank) { _, b in Analytics.shared.tap("bank", ["bank": b.letter]) }
            .onChange(of: state.performOn) { _, on in Analytics.shared.tap("perform", ["on": on]) }
            .onChange(of: state.bpm) { old, _ in
                // one event per tempo change, not one per step of a held −/+ (it settles for 0.8 s first)
                if tempoFrom == nil { tempoFrom = old }
                tempoTask?.cancel()
                tempoTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled, let from = tempoFrom else { return }
                    tempoFrom = nil
                    if abs(from - state.bpm) >= 1 {
                        Analytics.shared.track("tempo", ["bpm": Int(state.bpm.rounded()), "from": Int(from.rounded())])
                    }
                }
            }
            .onChange(of: state.log.last?.id) { _, _ in errorsSeen() }
    }

    /// The screen under any sheet: the main screen per mode, or the panel / layer covering it.
    private var screen: String {
        if state.promptFocused || ui.promptFocused { return "prompt" }
        if ui.editorOpen { return "pad_editor" }
        if ui.fxLayer { return "fx_layer" }
        if ui.muteLayer { return "shift_layer" }
        if ui.shift { return "shift_layer" }
        if state.song.songMode && state.mode == .seq { return "song_view" }
        return "main_" + Self.modeName(state.mode)
    }

    static func modeName(_ m: Mode) -> String {
        switch m {
        case .seq: return "seq"
        case .keys: return "keys"
        case .sample: return "sample"
        case .chop: return "chop"
        case .padFX: return "fx"
        case .levels16: return "16lvl"
        }
    }

    /// `error_seen` for each new red line in the log: ERR (load / import / mic / export failures) and GPT's "×".
    private func errorsSeen() {
        let lines = state.log
        let from = lastLog.flatMap { id in lines.lastIndex { $0.id == id }.map { $0 + 1 } } ?? (lastLog == nil ? 0 : lines.count - 1)
        for l in lines[max(0, from)...] where l.tag == "ERR" || l.text.hasPrefix("×") || l.tint == .red {
            Analytics.shared.track("error_seen", ["tag": l.tag, "msg": String(l.text.prefix(80)),
                                                  "screen": ScreenTracker.shared.current])
        }
        lastLog = lines.last?.id
    }
}

extension View {
    func analytics(_ state: AppState) -> some View { modifier(AnalyticsObserver(state: state)) }
}
