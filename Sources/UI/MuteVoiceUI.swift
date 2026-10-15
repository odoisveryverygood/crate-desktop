import SwiftUI
#if os(macOS)
import AppKit
#endif

// SHIFT (mute) key + layer, pull-to-talk pad marks + pad line and the 🎲 chip. Kept out of the deck / pad files so
// their diffs stay small.

// MARK: - MUTE key

extension CrateUI {
    /// MUTE down: the pads (and BANK keys) become mute toggles while it's held. Leaves KEYS for the pads.
    @MainActor func muteDown(_ state: AppState) {
        fxLatched = false
        fxHeld = false
        sampleArmed = false
        if state.mode == .keys {
            // the deck swaps the keyboard for the pads under the finger: latch, so the layer stays up
            setMode(.seq, state)
            muteLatched = true
            muteDownAt = nil
            DebugLog.event("mute_layer", ["latched": true, "fromKeys": true])
            return
        }
        muteDownAt = Date()
        muteHeld = true
        DebugLog.event("mute_layer", ["held": true])
    }

    /// MUTE up. A quick tap latches the layer until MUTE is tapped again.
    @MainActor func muteUp() {
        muteHeld = false
        if let t = muteDownAt, Date().timeIntervalSince(t) < 0.3 { muteLatched.toggle() }
        muteDownAt = nil
        DebugLog.event("mute_layer", ["held": false, "latched": muteLatched])
    }
}


/// Speaker with a slash, drawn like the other 12×12 mode pictograms.
struct MuteGlyph: View {
    var color: Color = Deck05.ink
    var size: CGFloat = 12

    var body: some View {
        Canvas { ctx, box in
            let s = size / 12
            ctx.translateBy(x: (box.width - size) / 2, y: (box.height - size) / 2)
            ctx.scaleBy(x: s, y: s)
            let line = StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
            var spk = Path()
            spk.addLines([CGPoint(x: 0.8, y: 4.2), CGPoint(x: 3.2, y: 4.2), CGPoint(x: 6.4, y: 1.3),
                          CGPoint(x: 6.4, y: 10.7), CGPoint(x: 3.2, y: 7.8), CGPoint(x: 0.8, y: 7.8)])
            spk.closeSubpath()
            ctx.stroke(spk, with: .color(color), style: line)
            var x = Path()
            x.move(to: CGPoint(x: 8.3, y: 4.3)); x.addLine(to: CGPoint(x: 11.3, y: 7.7))
            x.move(to: CGPoint(x: 11.3, y: 4.3)); x.addLine(to: CGPoint(x: 8.3, y: 7.7))
            ctx.stroke(x, with: .color(color), style: line)
        }
        .frame(width: size + 3, height: size + 3)
        .accessibilityHidden(true)
    }
}

// MARK: - Pad marks

/// On a pad cell: muted = dimmed with a diagonal strike (always visible); the MUTE layer outlines the pads;
/// being pulled down to talk = a small down-chevron ring in the corner (fills with the pull), listening = plus a
/// pulsing orange outline.
struct PadMarks: ViewModifier {
    let muted: Bool
    let muteLayer: Bool
    /// Pull-to-talk progress on this pad (nil = none, ≥ 1 = listening).
    let voice: Double?

    func body(content: Content) -> some View {
        content
            .opacity(muted ? 0.4 : 1)
            .overlay {
                if muted {
                    GeometryReader { g in
                        Path { p in
                            p.move(to: CGPoint(x: 7, y: g.size.height - 7))
                            p.addLine(to: CGPoint(x: g.size.width - 7, y: 7))
                        }
                        .stroke(PadFinish.ink.opacity(0.75), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                if muteLayer {
                    RoundedRectangle(cornerRadius: 4.5)
                        .strokeBorder(Theme.orange.opacity(muted ? 0.9 : 0.45),
                                      style: StrokeStyle(lineWidth: 1.2, dash: muted ? [] : [3, 3]))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let p = voice {
                    ZStack(alignment: .topTrailing) {
                        if p >= 1 {
                            TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                                let k = 0.5 + 0.5 * sin(ctx.date.timeIntervalSinceReferenceDate * 2 * .pi * 1.6)
                                RoundedRectangle(cornerRadius: 4.5)
                                    .strokeBorder(Theme.orange, lineWidth: 1.5 + 1.2 * k)
                                    .opacity(0.5 + 0.5 * k)
                            }
                        }
                        VoicePullMark(progress: p).padding(5)
                    }
                    .allowsHitTesting(false)
                    .accessibilityIdentifier(p >= 1 ? "pad-listening" : "pad-pulling")
                }
            }
    }
}

// MARK: - Pad line rows

/// The pad line after a pull-to-talk request: "A3 ← rusty drum" while the AI works. The first launches also show a
/// faint one-time hint here after the first DIG (the pad swipes: ← → sound, ↑ remove, ↓ talk).
struct VoiceLine: View {
    let state: AppState

    /// Whether the pad line shows this instead of the selected pad.
    @MainActor static var shows: Bool {
        let v = VoiceDig.shared
        return v.sent != nil || v.note != nil || v.hint
    }

    var body: some View {
        let v = VoiceDig.shared
        HStack(spacing: 8) {
            if let s = v.sent {
                tag(s.target.label, s.target.pad.map { Theme.bank($0.bank) } ?? s.target.bank.map { Theme.bank($0) } ?? Theme.live)
                Text("← “\(s.text)”")
                    .font(Theme.inter(11, 600)).tracking(0.2).foregroundStyle(Theme.lidInk)
                    .lineLimit(1).truncationMode(.tail)
                    .accessibilityIdentifier("voice-sent")
                Spacer(minLength: 6)
                if state.isDigging { DotSpinner(color: Theme.live, dot: 2) }
            } else if let n = v.note {
                // the panel closed itself: why, in one quiet line (mic off = tap for Settings)
                Circle().fill(Theme.live).frame(width: 5, height: 5)
                Text(n.text)
                    .font(Theme.inter(9, 600)).tracking(0.9).foregroundStyle(Theme.lidGrey1)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityIdentifier("voice-note")
                Spacer(minLength: 6)
            } else if v.hint {
                Text("SWIPE A PAD ← → FOR ANOTHER SOUND · ↑ TO REMOVE · ↓ TO TALK")
                    .font(Theme.inter(9, 600)).tracking(0.5).foregroundStyle(Theme.lidGrey1)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .accessibilityIdentifier("voice-hint")
                Spacer(minLength: 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let n = v.note else { return }
            if n.settings {
                #if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                #else
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
                #endif
            }
            VoiceDig.shared.clearNote()
        }
        .transition(.opacity)
        .task(id: v.sent?.at) { await VoiceDig.shared.expireLine(state) }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Theme.inter(8, 700)).tracking(0.5)
            .foregroundStyle(Color.black)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(RoundedRectangle(cornerRadius: 3).fill(color))
            .fixedSize()
    }
}

/// The pad line on the MUTE layer.
struct MuteLine: View {
    let state: AppState

    var body: some View {
        let n = state.mutedPads.filter { state.sound($0) != nil }.count
        HStack(spacing: 8) {
            Text("SHIFT")
                .font(Theme.inter(8, 700)).tracking(0.5).foregroundStyle(Color.black)
                .padding(.horizontal, 6).frame(height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.live))
                .fixedSize()
            Text("TAP PADS OR BANKS TO MUTE")
                .font(Theme.inter(9, 600)).tracking(0.9).foregroundStyle(Theme.lidInk).lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 6)
            if n > 0 {
                Text("\(n) MUTED").font(Theme.mono(8)).foregroundStyle(Theme.lidGrey1).lineLimit(1).fixedSize()
                Button {
                    state.setMutes([])
                    DebugLog.event("mute", ["clear": true])
                } label: {
                    Text("CLEAR")
                        .font(Theme.inter(7, 600)).tracking(0.7).foregroundStyle(Theme.chipText)
                        .padding(.horizontal, 9).frame(height: 21)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.chipStroke, lineWidth: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(ChipPressStyle())
                .accessibilityIdentifier("mute-clear")
            }
        }
    }
}

// MARK: - 🎲

/// Next to ‹ ›: a random sound of the same kind (or a random sample under the same beat). Instant, one UNDO step.
/// Drawn exactly like ‹ › (`padLineKey`): same width, height, corner and stroke.
struct DiceChip: View {
    let pad: PadID

    var body: some View {
        Button {
            Task { @MainActor in await Orchestrator.current?.randomSound(for: pad) }
        } label: {
            Image(systemName: "dice")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.chipText)
                .padLineKey()
        }
        .buttonStyle(HitPressStyle())
        .padding(.vertical, -(44 - PadLine.height) / 2)
        .accessibilityIdentifier("pad-random")
        .accessibilityLabel("Random sound")
    }
}

/// SHIFT (bottom row): hold it, or tap to latch, and the pads / BANK keys mute and unmute. Secondary functions live
/// behind SHIFT so the top row stays SAMPLE · KEYS · FX. A dot shows when something is muted.
struct ShiftKey: View {
    let state: AppState
    var height: CGFloat = 32
    @State private var pressing = false

    var body: some View {
        let ui = CrateUI.shared
        let on = ui.muteLayer
        let anyMuted = !state.mutedPads.isEmpty
        ZStack {
            KeyFace(on: on, radius: 5)
            Text("SHIFT")
                .font(Deck05.font(8, 700))
                .tracking(8 * 0.2)
                .foregroundStyle(on ? Deck05.key : Deck05.ink)
            if anyMuted && !on {
                Circle().fill(Deck05.ink).frame(width: 4, height: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(5)
            }
        }
        .frame(height: height)
        .brightness(pressing ? -0.08 : 0)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing else { return }
                    pressing = true
                    ui.muteDown(state)
                }
                .onEnded { _ in
                    pressing = false
                    ui.muteUp()
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("shift-key")
        .accessibilityLabel("Shift")
        .accessibilityHint("Hold, then tap pads or banks to mute them")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityAction { ui.muteLatched.toggle() }
    }
}
