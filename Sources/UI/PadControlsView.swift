import SwiftUI

// MARK: - Editing (pad editor's controls → pad params → engine)

/// Applies the pad editor's controls to a pad: one UNDO step per editor visit, a re-render of just that pad (from
/// its kept slice, no decode), then an audition. Rapid changes (a held − / +) coalesce: the newest value wins.
@MainActor
final class PadParamsEditor {
    static let shared = PadParamsEditor()

    private var visitPad: PadID?
    /// EditHistory.version right after this visit's checkpoint; anything else touching history starts a new step.
    private var visitVersion = -1
    private var inFlight: Set<PadID> = []
    private var pending: [PadID: PadSound] = [:]
    private var lastAudition = Date.distantPast

    /// The editor closed or moved to another pad: the next change is a new UNDO step.
    func endVisit() { visitPad = nil }

    func change(_ state: AppState, _ pad: PadID, _ what: String, _ edit: (inout PadParams) -> Void) {
        guard var s = state.sound(pad) else { return }
        let old = s
        var p = s.params
        edit(&p)
        guard p != s.params else { return }
        if visitPad != pad || EditHistory.shared.version != visitVersion {
            Orchestrator.current?.checkpoint("\(pad.key) sound")
            visitPad = pad
            visitVersion = EditHistory.shared.version
        }
        s.params = p
        state.sounds[pad] = s
        var f = p.summary
        f["pad"] = pad.key
        f["what"] = what
        DebugLog.event("padparam", f)
        var was = old.params, now = p
        was.favorite = false; now.favorite = false
        if was != now { audible.insert(pad) }   // ★ alone doesn't play the pad
        render(state, pad, s)
    }

    private var audible: Set<PadID> = []

    private func render(_ state: AppState, _ pad: PadID, _ s: PadSound) {
        if inFlight.contains(pad) { pending[pad] = s; return }
        inFlight.insert(pad)
        Task { @MainActor in
            var cur = s
            while true {
                await self.apply(state, pad, cur)
                guard let next = self.pending.removeValue(forKey: pad) else { break }
                if Date().timeIntervalSince(self.lastAudition) > 0.15, self.audible.contains(pad) { self.audition(state, pad) }
                cur = next
            }
            self.inFlight.remove(pad)
            if self.audible.remove(pad) != nil { self.audition(state, pad) }
        }
    }

    private func apply(_ state: AppState, _ pad: PadID, _ s: PadSound) async {
        let e = state.engine
        if let ae = e as? AudioEngine, await ae.rerender(pad, sound: s) { return }
        // The pad moved on meanwhile (an UNDO, a new sound): what's loaded now wins.
        guard state.sound(pad) == s else { return }
        var bank: [Int: PadSound] = [:]
        for i in 0..<16 {
            let id = PadID(pad.bank, i)
            if let x = e.sound(for: id) ?? state.sounds[id] { bank[i] = x }
        }
        bank[pad.index] = s
        try? await e.loadBank(pad.bank, sounds: bank)
    }

    /// Hear the change, without recording it or adding it to a jam. Skipped while the beat is playing that pad.
    private func audition(_ state: AppState, _ pad: PadID) {
        let e = state.engine
        if e.isPlaying {
            let p = e.pattern
            if !(p.lanes[pad]?.isEmpty ?? true) || !(p.notes[pad]?.isEmpty ?? true) { return }
        }
        lastAudition = Date()
        if let ae = e as? AudioEngine { ae.audition(pad) } else { e.trigger(pad, velocity: 110, semitones: 0) }
        state.lastHitPad = pad
        state.lastHitTime = Date()
    }
}

// MARK: - Controls row (under the waveform)

/// The pad editor's sound controls, like Serato Sample's pad row. No knobs: each control is a tile showing its value;
/// − / + step it (hold to repeat), tapping the value resets it. REVERSE and ★ are toggles; STRETCH snaps ½ · 1 · ×2
/// (− / + nudge 5 %). Two rows on a phone, one on a wide lid.
struct PadControlsRow: View {
    let state: AppState
    static let tileHeight: CGFloat = 34
    static let gap: CGFloat = 6

    static func rows(for width: CGFloat) -> Int { width >= 640 ? 1 : 2 }
    static func height(for width: CGFloat) -> CGFloat {
        let r = CGFloat(rows(for: width))
        return r * tileHeight + (r - 1) * gap
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let pad = state.selectedPad
            if let s = state.sound(pad) {
                let tiles = Tiles(state: state, pad: pad, p: s.params, tint: Theme.bank(pad.bank))
                let g = Self.gap
                if Self.rows(for: w) == 1 {
                    // 5 steppers · stretch 1.5 · reverse 0.9 · ★ 0.6
                    let u = (w - 7 * g) / 8
                    HStack(spacing: g) {
                        tiles.level.frame(width: u)
                        tiles.filter.frame(width: u)
                        tiles.attack.frame(width: u)
                        tiles.release.frame(width: u)
                        tiles.key.frame(width: u)
                        tiles.stretch.frame(width: u * 1.5)
                        tiles.reverse.frame(width: u * 0.9)
                        tiles.favorite.frame(width: u * 0.6)
                    }
                } else {
                    let u = (w - 3 * g) / 4
                    let rest = w - 3 * g - u * 2.5
                    VStack(spacing: g) {
                        HStack(spacing: g) {
                            tiles.level.frame(width: u)
                            tiles.filter.frame(width: u)
                            tiles.attack.frame(width: u)
                            tiles.release.frame(width: u)
                        }
                        HStack(spacing: g) {
                            tiles.key.frame(width: u)
                            tiles.stretch.frame(width: u * 1.5)
                            tiles.reverse.frame(width: rest * 0.6)
                            tiles.favorite.frame(width: rest * 0.4)
                        }
                    }
                }
            }
        }
        .onChange(of: state.selectedPad) { _, _ in PadParamsEditor.shared.endVisit() }
        .onDisappear { PadParamsEditor.shared.endVisit() }
    }

    /// The tiles for one pad.
    @MainActor private struct Tiles {
        let state: AppState
        let pad: PadID
        let p: PadParams
        let tint: Color

        private func edit(_ c: PadParams.Control, _ f: @escaping (inout PadParams) -> Void) {
            PadParamsEditor.shared.change(state, pad, c.rawValue, f)
        }

        private func stepper(_ c: PadParams.Control, _ label: String, _ value: String, minus: String = "LESS",
                             plus: String = "MORE") -> ParamStepper {
            ParamStepper(label: label, value: value, active: p.value(c) != PadParams.neutral.value(c), tint: tint,
                         id: "param-" + c.rawValue, minus: minus, plus: plus,
                         step: { d in edit(c) { $0.step(c, d) } },
                         reset: { edit(c) { $0.reset(c) } })
        }

        var level: some View { stepper(.level, "LEVEL", p.levelText) }
        var filter: some View { stepper(.filter, "FILTER", p.filterText, minus: "DARKER", plus: "BRIGHTER") }
        var attack: some View { stepper(.attack, "ATTACK", p.attackText) }
        var release: some View { stepper(.release, "RELEASE", p.releaseText) }
        var key: some View { stepper(.key, "KEY", p.keyText, minus: "DOWN", plus: "UP") }
        var stretch: some View {
            StretchTile(value: p.stretch, text: p.stretchText, tint: tint,
                        pick: { v in edit(.stretch) { $0.set(.stretch, v) } },
                        step: { d in edit(.stretch) { $0.step(.stretch, d) } })
        }
        var reverse: some View {
            ParamToggle(on: p.reverse, tint: tint, id: "param-reverse", label: "Reverse") {
                HStack(spacing: 4) {
                    PlayShape().rotation(.degrees(180)).frame(width: 6, height: 7)
                    Text("REV").font(Theme.inter(8, 600)).tracking(0.8)
                }
            } toggle: { edit(.reverse) { $0.step(.reverse, 1) } }
        }
        var favorite: some View {
            ParamToggle(on: p.favorite, tint: Theme.ochre, id: "param-favorite", label: "Favorite") {
                Text("★").font(.system(size: 13, weight: .semibold))
            } toggle: { edit(.favorite) { $0.step(.favorite, 1) } }
        }
    }
}

/// A labelled value with − / + either side. Hold − / + to repeat; tap the value to reset.
struct ParamStepper: View {
    let label: String
    let value: String
    let active: Bool
    let tint: Color
    let id: String
    var minus = "LESS"
    var plus = "MORE"
    let step: (Int) -> Void
    let reset: () -> Void

    var body: some View {
        // Three equal touch zones (−, value = reset, +); the readout spans the middle over them, so narrow tiles
        // keep big targets and a readable value.
        ZStack {
            HStack(spacing: 0) {
                RepeatButton(symbol: "−", id: id + "-minus", label: "\(label.capitalized) \(minus.lowercased())",
                             edge: .leading) { step(-1) }
                Button(action: reset) {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(id + "-value")
                .accessibilityLabel(label.capitalized)
                .accessibilityValue(value)
                .accessibilityHint("Resets")
                RepeatButton(symbol: "+", id: id + "-plus", label: "\(label.capitalized) \(plus.lowercased())",
                             edge: .trailing) { step(1) }
            }
            VStack(spacing: 2) {
                Text(label).fieldLabel(6, tracking: 0.12).foregroundStyle(Theme.lidGrey1)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(value).font(Theme.mono(10)).monospacedDigit()
                    .foregroundStyle(active ? tint : Theme.lidInk)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 19)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .frame(height: PadControlsRow.tileHeight)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(active ? tint.opacity(0.7) : Theme.chipStroke, lineWidth: active ? 0.8 : 0.5))
    }
}

/// − / + that fires on touch-down and repeats while held (after 0.4 s, ~11 per second). Fills the width it's given;
/// the glyph sits at `edge`.
struct RepeatButton: View {
    let symbol: String
    let id: String
    let label: String
    var edge: HorizontalAlignment = .center
    let action: () -> Void
    @State private var pressed = false
    @State private var repeater: Task<Void, Never>?

    var body: some View {
        Text(symbol)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(Theme.lidInk)
            .frame(width: 18)
            .padding(edge == .leading ? .leading : .trailing, edge == .center ? 0 : 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: edge == .leading ? .leading : edge == .trailing ? .trailing : .center)
            .background(RoundedRectangle(cornerRadius: 4).fill(pressed ? Theme.lidGrey3 : Color.clear).padding(2))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        action()
                        repeater = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(400))
                            while !Task.isCancelled && pressed {
                                action()
                                try? await Task.sleep(for: .milliseconds(90))
                            }
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        repeater?.cancel()
                        repeater = nil
                    }
            )
            .onDisappear { pressed = false; repeater?.cancel() }
            .accessibilityElement()
            .accessibilityIdentifier(id)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

/// A tap toggle tile (REVERSE, ★): filled when on.
struct ParamToggle<Label: View>: View {
    let on: Bool
    let tint: Color
    let id: String
    let label: String
    @ViewBuilder let content: () -> Label
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            content()
                .foregroundStyle(on ? Color.black : Theme.chipText)
                .frame(maxWidth: .infinity)
                .frame(height: PadControlsRow.tileHeight)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? tint : Color.black))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.chipStroke, lineWidth: 0.5).opacity(on ? 0 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
        .accessibilityValue(on ? "on" : "off")
    }
}

/// STRETCH: ½ · 1 · ×2 speed snaps (pitch kept), − / + nudge 5 % between them.
struct StretchTile: View {
    let value: Double
    let text: String
    let tint: Color
    let pick: (Double) -> Void
    let step: (Int) -> Void

    var body: some View {
        let snapped = [0.5, 1, 2].contains { abs($0 - value) < 0.001 }
        HStack(spacing: 0) {
            RepeatButton(symbol: "−", id: "param-stretch-minus", label: "Slower", edge: .leading) { step(-1) }
                .frame(width: 26)
            VStack(spacing: 2) {
                Text(snapped ? "STRETCH" : "STRETCH \(text)")
                    .fieldLabel(6, tracking: 0.12)
                    .foregroundStyle(snapped ? Theme.lidGrey1 : tint)
                    .lineLimit(1)
                HStack(spacing: 2) {
                    seg("½", 0.5, id: "param-stretch-half")
                    seg("1", 1, id: "param-stretch-1")
                    seg("×2", 2, id: "param-stretch-double")
                }
            }
            .frame(maxWidth: .infinity)
            RepeatButton(symbol: "+", id: "param-stretch-plus", label: "Faster", edge: .trailing) { step(1) }
                .frame(width: 26)
        }
        .frame(height: PadControlsRow.tileHeight)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(abs(value - 1) > 0.001 ? tint.opacity(0.7) : Theme.chipStroke, lineWidth: abs(value - 1) > 0.001 ? 0.8 : 0.5))
    }

    private func seg(_ label: String, _ v: Double, id: String) -> some View {
        let on = abs(value - v) < 0.001
        return Button { pick(v) } label: {
            Text(label)
                .font(Theme.mono(9.5))
                .foregroundStyle(on ? Color.black : Theme.lidInk)
                .frame(maxWidth: .infinity)
                .frame(height: 15)
                .background(RoundedRectangle(cornerRadius: 3).fill(on ? (v == 1 ? Theme.lidInk : tint) : Theme.lidGrey3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(v == 0.5 ? "Half speed" : v == 2 ? "Double speed" : "Normal speed")
    }
}

/// Over the editor's waveform: the pad's ATTACK / RELEASE fades as a line across the kept region (flipped when the
/// pad plays reversed: it starts at the right edge). `seconds` = how long the pad plays (slice / stretch).
struct EnvelopeLine: View {
    let params: PadParams
    let seconds: Double
    let x0: CGFloat
    let x1: CGFloat
    let color: Color

    var body: some View {
        Canvas { g, size in
            guard params.attack > 0 || params.release > 0, x1 - x0 > 2 else { return }
            let len = x1 - x0
            let played = max(0.001, seconds)
            let a = min(1, params.attack / played), r = min(1, params.release / played)
            let top: CGFloat = 4, bottom = size.height - 4
            // Gain over played time u ∈ 0…1, the DSP's curves: linear attack, x² release.
            func gain(_ u: Double) -> Double {
                var v = 1.0
                if a > 0, u < a { v *= u / a }
                if r > 0, u > 1 - r { let x = (1 - u) / r; v *= x * x }
                return v
            }
            var p = Path()
            let n = 48
            for k in 0...n {
                let u = Double(k) / Double(n)
                let screen = params.reverse ? 1 - u : u
                let pt = CGPoint(x: x0 + CGFloat(screen) * len, y: bottom - CGFloat(gain(u)) * (bottom - top))
                if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            g.stroke(p, with: .color(color.opacity(0.85)), lineWidth: 1.2)
        }
    }
}

/// Top-right of a pad whose sound was changed in the editor: ★ favorite, ◀ reversed, a dot for anything else.
struct PadEditMarks: View {
    let params: PadParams
    let tint: Color

    var body: some View {
        var other = params
        other.reverse = false
        other.favorite = false
        return HStack(spacing: 3) {
            if params.favorite {
                Text("★").font(.system(size: 7.5, weight: .semibold)).foregroundStyle(Theme.ochre)
            }
            if params.reverse {
                PlayShape().rotation(.degrees(180)).fill(PadFinish.muted).frame(width: 5, height: 5.5)
            }
            if !other.isNeutral {
                Circle().fill(tint).frame(width: 4.5, height: 4.5)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}
