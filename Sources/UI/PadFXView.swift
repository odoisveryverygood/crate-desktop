import SwiftUI

/// PAD FX mode (MPC Sample style): the 16 pads become the effect grid, plus LATCH and a large FX KNOB.
/// The knob shows `state.punch`, which the hinge also writes, so it turns by itself when the hinge moves.
/// Dragging it goes through `CrateUI.shared.onPunch` (= HingeFX.apply), so snap-to-zero still fires the DROP.
struct PadFXView: View {
    let state: AppState
    var gap: CGFloat = 9

    @State private var holding: Int? = nil

    var body: some View {
        GeometryReader { geo in
            let s = geo.size
            let wide = s.width > s.height * 1.35
            if wide {
                HStack(spacing: 12) {
                    grid
                    controls(vertical: true)
                        .frame(width: min(150, s.width * 0.3))
                }
            } else {
                VStack(spacing: 10) {
                    grid
                    controls(vertical: false)
                        .frame(height: min(124, max(84, s.height * 0.3)))
                }
            }
        }
    }

    // MARK: grid

    private var grid: some View {
        let selected = state.fx
        return VStack(spacing: gap) {
            ForEach(0..<4, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(0..<4, id: \.self) { c in
                        let i = (3 - r) * 4 + c
                        let fx = FXType.padLayout[i]
                        FXPadCell(number: i + 1,
                                  label: fx?.label ?? "PUNCH",
                                  hint: fx?.hint ?? "LPF + SPACE",
                                  selected: fx == selected,
                                  held: holding == i)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { _ in if holding != i { press(i) } }
                                    .onEnded { _ in release(i) }
                            )
                            .accessibilityElement(children: .ignore)
                            .accessibilityIdentifier("fx-\(fx?.rawValue ?? "punch")")
                            .accessibilityLabel(fx?.label ?? "PUNCH")
                            .accessibilityAddTraits(fx == selected ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { state.selectFX(fx) }
                    }
                }
            }
        }
    }

    /// LATCH on: tap selects (tap the lit pad again → back to PUNCH). LATCH off (hold): the effect is
    /// selected only while the pad is held, release returns to PUNCH.
    private func press(_ i: Int) {
        holding = i
        let fx = FXType.padLayout[i]
        if state.fxLatched, let fx, state.fx == fx {
            state.selectFX(nil)
        } else {
            state.selectFX(fx)
        }
    }

    private func release(_ i: Int) {
        holding = nil
        if !state.fxLatched { state.selectFX(nil) }
    }

    // MARK: knob + latch

    @ViewBuilder
    private func controls(vertical: Bool) -> some View {
        if vertical {
            VStack(alignment: .leading, spacing: 10) {
                FXKnob(state: state).aspectRatio(1, contentMode: .fit)
                readout
                Spacer(minLength: 0)
                latch.frame(height: 38)
            }
        } else {
            HStack(alignment: .center, spacing: 14) {
                FXKnob(state: state).aspectRatio(1, contentMode: .fit)
                VStack(alignment: .leading, spacing: 8) {
                    readout
                    Spacer(minLength: 0)
                    latch.frame(height: 36).frame(maxWidth: 120)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var readout: some View {
        let fx = state.fx
        return VStack(alignment: .leading, spacing: 4) {
            SilkLabel(CrateUI.shared.isDuo ? "FX KNOB · HINGE" : "FX KNOB", color: Theme.mid)
            Text(fx?.label ?? "PUNCH")
                .font(Theme.mono(13, bold: true))
                .foregroundStyle(Theme.silk)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityIdentifier("fx-name")
            SilkLabel(state.hingeAngle.map { "HINGE \(Int($0.rounded()))°" } ?? "DRAG KNOB ↕",
                      color: state.hingeAngle != nil ? Theme.orange : Theme.mid)
        }
    }

    private var latch: some View {
        DeckButton(label: state.fxLatched ? "LATCH" : "HOLD", on: state.fxLatched, toggle: true, id: "fx-latch") {
            state.fxLatched.toggle()
            DebugLog.event("fx_latch", ["on": state.fxLatched])
        }
    }
}

/// One FX pad: number top-left, effect name + hint bottom-left; the selected effect is lit orange.
struct FXPadCell: View {
    let number: Int
    let label: String
    let hint: String
    let selected: Bool
    var held = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(selected ? Theme.orange : (held ? Theme.padPressed : Theme.pad))
            Text(String(format: "%02d", number))
                .font(Theme.label(8))
                .tracking(0.8)
                .foregroundStyle(selected ? Color.white.opacity(0.75) : Theme.mid)
                .padding(.leading, 7)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(Theme.mono(10, bold: true))
                    .tracking(0.6)
                    .foregroundStyle(selected ? Color.white : Theme.padLabel)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                Text(hint)
                    .font(Theme.label(6.5))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Theme.mid)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(7)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.padRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.padRadius)
                .strokeBorder(selected ? Theme.orange : Theme.padEdge, lineWidth: 1)
        )
    }
}

/// Big TE-style knob: 270° arc (orange = amount), silk cap with an orange pointer, amount in Doto.
/// Drag up/down (160 pt = full range). Mirrors `state.punch`, so the hinge turns it too.
struct FXKnob: View {
    let state: AppState
    @State private var dragBase: Double? = nil

    var body: some View {
        GeometryReader { g in
            let d = min(g.size.width, g.size.height)
            let v = min(1, max(0, state.punch))
            let line = max(3, d * 0.05)
            ZStack {
                Circle().fill(Theme.button)
                Circle().strokeBorder(Theme.buttonBorder, lineWidth: 1)
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Theme.buttonBorder, style: StrokeStyle(lineWidth: line, lineCap: .butt))
                    .rotationEffect(.degrees(135))
                    .padding(d * 0.09)
                Circle()
                    .trim(from: 0, to: 0.75 * v)
                    .stroke(Theme.orange, style: StrokeStyle(lineWidth: line, lineCap: .butt))
                    .rotationEffect(.degrees(135))
                    .padding(d * 0.09)
                Circle().fill(Theme.silk).padding(d * 0.2)
                Capsule()
                    .fill(Theme.orange)
                    .frame(width: max(3, d * 0.035), height: d * 0.17)
                    .offset(y: -d * 0.19)
                    .rotationEffect(.degrees(-135 + 270 * v))
                Text(String(format: "%03d", Int((v * 100).rounded())))
                    .font(Theme.doto(max(14, d * 0.2)))
                    .foregroundStyle(Theme.text)
                    .offset(y: d * 0.03)
            }
            .frame(width: d, height: d)
            .frame(width: g.size.width, height: g.size.height)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if dragBase == nil { dragBase = state.punch }
                        send(min(1, max(0, (dragBase ?? 0) - Double(drag.translation.height) / 160)))
                    }
                    .onEnded { _ in dragBase = nil }
            )
        }
        .accessibilityElement()
        .accessibilityIdentifier("fx-knob")
        .accessibilityLabel("FX amount")
        .accessibilityValue("\(Int((min(1, max(0, state.punch))) * 100)) percent")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: send(min(1, state.punch + 0.1))
            case .decrement: send(max(0, state.punch - 0.1))
            @unknown default: break
            }
        }
    }

    private func send(_ v: Double) {
        if let hook = CrateUI.shared.onPunch { hook(v); return }
        state.punch = v
        state.engine.setPunch(v)
    }
}
