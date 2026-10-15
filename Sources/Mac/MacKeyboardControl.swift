import SwiftUI
import AppKit

struct KeyboardControl: NSViewRepresentable {
    let state: AppState
    func makeNSView(context: Context) -> MacKeyboardView { MacKeyboardView(state: state) }
    func updateNSView(_ view: MacKeyboardView, context: Context) {
        let signature = "\(state.mode):\(state.bank):\(state.keysOctave):\(state.promptFocused)"
        DispatchQueue.main.async { view.synchronize(signature) }
    }
    static func dismantleNSView(_ view: MacKeyboardView, coordinator: ()) { view.uninstall() }
}
final class MacKeyboardView: NSView {
    let player: KeyboardPlayer
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var keys: [UInt16: String] = [:]
    private var signature = ""
    init(state: AppState) {
        player = KeyboardPlayer(state: state)
        super.init(frame: .zero)
        player.focusPrompt = { CrateUI.shared.focusRequest += 1 }
        player.selectMode = { CrateUI.shared.setMode($0, state) }
        player.selectBank = { CrateUI.shared.selectBank($0, state) }
        player.playedNote = { CrateUI.shared.lastMidi = $0; CrateUI.shared.lastSemi = $1 }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        } { monitors.append(monitor) }
        for name in [NSWindow.didResignKeyNotification, NSApplication.willResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseAll() }
            })
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    func synchronize(_ value: String) { if value != signature { releaseAll(); signature = value } }
    func releaseAll() { player.releaseAll(); keys.removeAll() }
    func uninstall() { releaseAll(); monitors.forEach(NSEvent.removeMonitor); monitors.removeAll(); observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll() }
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, window.isKeyWindow, event.window === window else { return event }
        if event.type == .keyUp, let key = keys.removeValue(forKey: event.keyCode) { player.release(key); return nil }
        guard event.type == .keyDown else { return event }
        if window.firstResponder is NSTextView || window.firstResponder is NSTextField { releaseAll(); return event }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
        let name: String
        switch event.keyCode { case 36, 76: name = "\r"; case 48: name = "\t"; case 53: name = "\u{1b}"; default: name = event.charactersIgnoringModifiers?.lowercased() ?? "" }
        if keys[event.keyCode] != nil { return nil }
        if player.press(name, shift: event.modifierFlags.contains(.shift)) { keys[event.keyCode] = name; return nil }
        return event
    }
}
