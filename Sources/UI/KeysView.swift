import SwiftUI

/// KEYS mode = the MIDI keyboard: 8 white + 5 black keys, C to C (matching musical typing), playing the selected pad
/// chromatically. Multi-touch note on/off, glissando, scale lock (snaps to the loop's key), OCT ± via state.keysOctave.
struct KeysView: View {
    let state: AppState
    var gap: CGFloat = 2

    /// Offsets from the first C for the white keys, and which white keys have a black key after them.
    static let whiteOffsets = [0, 2, 4, 5, 7, 9, 11, 12]
    static let blackAfter = [0, 1, 3, 4, 5]

    /// finger → (key midi as laid out, midi actually played after scale lock)
    @State private var fingers: [ObjectIdentifier: FingerNote] = [:]

    struct FingerNote: Equatable {
        var key: Int
        var played: Int
    }

    /// Match hardware musical typing so every keyboard note has a visible key.
    static func baseMidi(root: Int, octave: Int) -> Int {
        MusicalTyping.baseMidi(octave: octave)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let whiteW = max(1, (size.width - 7 * gap) / 8)
            let stride = whiteW + gap
            let blackW = whiteW * 0.62
            let blackH = size.height * 0.58
            let pad = state.selectedPad
            let root = UIHelpers.rootNote(state, pad)
            let nominal = Self.baseMidi(root: root, octave: state.keysOctave)
            // Keep the original extended typing map visible when its upper notes are held.
            let base = nominal + (state.heldNotes.contains(where: { $0 > nominal + 12 }) ? 12 : 0)
            let scale = scalePCs()
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
                let frame = LiveFrame(state)
                let sounding = frame.soundingNotes(pad)
                let held = Set(fingers.values.map(\.key)).union(state.heldNotes)
                ZStack(alignment: .topLeading) {
                    ForEach(0..<8, id: \.self) { w in
                        let midi = base + Self.whiteOffsets[w]
                        whiteKey(midi: midi, root: root, scale: scale,
                                 held: held.contains(midi), sounding: sounding.contains(midi))
                            .frame(width: whiteW, height: size.height)
                            .position(x: CGFloat(w) * stride + whiteW / 2, y: size.height / 2)
                    }
                    ForEach(Self.blackAfter, id: \.self) { w in
                        let midi = base + Self.whiteOffsets[w] + 1
                        blackKey(midi: midi, scale: scale,
                                 held: held.contains(midi), sounding: sounding.contains(midi))
                            .frame(width: blackW, height: blackH)
                            .position(x: CGFloat(w + 1) * stride - gap / 2, y: blackH / 2)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
            .overlay(
                TouchSurface { phase, id, pt in
                    handle(phase, id, pt, stride: stride, blackW: blackW, blackH: blackH, base: base, scale: scale)
                }
            )
        }
    }

    // MARK: scale lock

    private func scalePCs() -> Set<Int>? {
        guard state.scaleLock, let k = Music.parseKey(state.scaleKey) else { return nil }
        return Set(Music.scale(pc: k.pc, minor: k.minor))
    }

    private func snap(_ midi: Int, _ scale: Set<Int>?) -> Int {
        guard let scale else { return midi }
        let pc = ((midi % 12) + 12) % 12
        if scale.contains(pc) { return midi }
        if scale.contains((pc + 11) % 12) { return midi - 1 }
        if scale.contains((pc + 1) % 12) { return midi + 1 }
        return midi
    }

    private func inScale(_ midi: Int, _ scale: Set<Int>?) -> Bool {
        guard let scale else { return true }
        return scale.contains(((midi % 12) + 12) % 12)
    }

    // MARK: key views

    private func whiteKey(midi: Int, root: Int, scale: Set<Int>?, held: Bool, sounding: Bool) -> some View {
        let ok = inScale(midi, scale)
        let played = snap(midi, scale)
        return ZStack(alignment: .bottom) {
            UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                .fill(held ? PadFinish.pressed : (ok ? PadFinish.key : PadFinish.pressed))
            UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                .strokeBorder(PadFinish.seam, lineWidth: 1)
            if held || sounding {
                Rectangle().fill(Theme.orange)
                    .frame(height: 4)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6))
            }
            VStack(spacing: 3) {
                if DeviceInfo.hasHardwareKeyboard {
                    Text(MusicalTyping.label(midi: midi, octave: state.keysOctave))
                        .font(Theme.label(9)).foregroundStyle(held ? Theme.orange : Theme.mid)
                }
                if played == root {
                    Circle().fill(Theme.orange).frame(width: 4, height: 4)
                }
                Text(Music.name(played).replacingOccurrences(of: "#", with: "♯"))
                    .font(Theme.label(8))
                    .foregroundStyle(ok ? Theme.mid : PadFinish.seam)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.bottom, 9)
        }
        .modifier(KeyAccessibility(id: "key-\(midi)", label: Music.name(played)) {
            tapKey(midi)
        })
    }

    private func blackKey(midi: Int, scale: Set<Int>?, held: Bool, sounding: Bool) -> some View {
        return ZStack(alignment: .bottom) {
            UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
                .fill(held ? Theme.hex(0x333333) : PadFinish.ink)
            if held || sounding {
                Rectangle().fill(Theme.orange)
                    .frame(height: 3)
                    .padding(.horizontal, 3)
                    .padding(.bottom, 4)
            }
        }
        .overlay(alignment: .bottom) {
            if DeviceInfo.hasHardwareKeyboard {
                Text(MusicalTyping.label(midi: midi, octave: state.keysOctave))
                    .font(Theme.label(9)).foregroundStyle(held ? Theme.orange : PadFinish.key)
                    .padding(.bottom, 12)
            }
        }
        .modifier(KeyAccessibility(id: "key-\(midi)", label: Music.name(snap(midi, scale))) {
            tapKey(midi)
        })
    }

    // MARK: touches

    private func keyAt(_ pt: CGPoint, stride: CGFloat, blackW: CGFloat, blackH: CGFloat, base: Int) -> Int {
        if pt.y < blackH {
            for w in Self.blackAfter {
                let cx = CGFloat(w + 1) * stride - gap / 2
                if abs(pt.x - cx) <= blackW / 2 + 1 { return base + Self.whiteOffsets[w] + 1 }
            }
        }
        let w = min(7, max(0, Int(pt.x / stride)))
        return base + Self.whiteOffsets[w]
    }

    private func handle(_ phase: TouchPhaseUI, _ id: ObjectIdentifier, _ pt: CGPoint,
                        stride: CGFloat, blackW: CGFloat, blackH: CGFloat, base: Int, scale: Set<Int>?) {
        switch phase {
        case .began:
            let key = keyAt(pt, stride: stride, blackW: blackW, blackH: blackH, base: base)
            fingers[id] = noteOn(key, scale)
        case .moved:
            guard let cur = fingers[id] else { return }
            let key = keyAt(pt, stride: stride, blackW: blackW, blackH: blackH, base: base)
            guard key != cur.key else { return }
            if fingers.count == 1 { state.engine.release(state.selectedPad) }
            fingers[id] = noteOn(key, scale)
        case .ended:
            guard fingers[id] != nil else { return }
            fingers[id] = nil
            if fingers.isEmpty && state.heldNotes.isEmpty { state.engine.release(state.selectedPad) }
        }
    }

    @discardableResult
    private func noteOn(_ key: Int, _ scale: Set<Int>?) -> FingerNote {
        let pad = state.selectedPad
        let root = UIHelpers.rootNote(state, pad)
        let played = snap(key, scale)
        let semi = played - root
        state.hit(pad, velocity: 112, semitones: Double(semi))
        state.lastNoteName = Music.name(played)
        CrateUI.shared.lastMidi = played
        CrateUI.shared.lastSemi = semi
        DebugLog.event("keys", ["note": played, "semi": semi])
        return FingerNote(key: key, played: played)
    }

    /// Accessibility / AXe activation: a short note.
    private func tapKey(_ key: Int) {
        noteOn(key, scalePCs())
        let pad = state.selectedPad
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [state] in
            state.engine.release(pad)
        }
    }
}

private struct KeyAccessibility: ViewModifier {
    let id: String
    let label: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(id)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}
