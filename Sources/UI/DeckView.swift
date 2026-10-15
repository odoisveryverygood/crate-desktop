import SwiftUI

/// The chassis half, direction 05 (COLOUR-CODED): pictogram MODE keys, 4×4 pads (or the KEYS keyboard),
/// round BANK A–D keys, LEVEL/PUNCH fader with a printed scale, REC and PLAY / PAUSE, the black ✦ DIG key.
/// Landscape (~669×455) = the mock's three columns; portrait (~455×669) = modes on top, pads, controls below.
/// KEYS mode hides the right column so the one-octave keyboard gets the full deck width.
struct DeckView: View {
    let state: AppState
    /// iPhone (and narrow iPad windows): modes on top, the biggest pads that fit, one row of BANK · transport · DIG.
    var phone = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                DeckSurface()
                if state.mode == .keys {
                    wideKeys(size)
                } else if phone {
                    phoneDeck(size)
                } else if size.height > size.width * 1.05 {
                    portrait(size)
                } else {
                    landscape(size)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .background(Deck05.alu)
        .ignoresSafeArea(.keyboard)
        .crateDeferEdgeGestures()
        .onChange(of: state.mode) { _, m in
            if m == .keys { CrateUI.shared.ensurePitchedSelection(state) }
        }
    }

    // MARK: layouts

    /// One slim control row (two in portrait) leaves the entire deck width for the one-octave keyboard.
    private func wideKeys(_ size: CGSize) -> some View {
        let tall = size.height > size.width * 1.05
        let key: CGFloat = 28
        let inset: CGFloat = tall ? 16 : 22
        return VStack(spacing: 10) {
            if tall {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(modeItems.filter(\.isMode), id: \.self) { item in
                        modeButton(item, key: 30, labelBelow: true)
                            .frame(maxWidth: .infinity)
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    ForEach(modeItems.filter { !$0.isMode }, id: \.self) { item in
                        modeButton(item, key: key, labelBelow: true)
                    }
                    Spacer(minLength: 6)
                    TransportRow(state: state, height: key)
                        .frame(width: TransportRow.width(key))
                    DigButton(state: state, height: key)
                        .frame(width: 76)
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(modeItems, id: \.self) { item in
                                modeButton(item, key: key, labelBelow: true)
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                    TransportRow(state: state, height: key)
                        .frame(width: TransportRow.width(key))
                    DigButton(state: state, height: key)
                        .frame(width: 88)
                }
                .frame(height: key + 14)
            }
            // The project lives on the lid's header now (no wordmark / PROJECT block on the deck).
            KeysView(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, inset)
        .padding(.top, inset)
        .padding(.bottom, 8)
    }

    /// The mock at 669×455: 28 | modes 80 | 18 | pads | 24 | right 102 | 26.
    private func landscape(_ size: CGSize) -> some View {
        let narrow = size.width < 600
        let left: CGFloat = narrow ? 16 : 28
        let right: CGFloat = narrow ? 14 : 26
        let top: CGFloat = min(31, max(14, size.height * 0.052))
        let bottom: CGFloat = min(31, max(12, size.height * 0.048))
        let contentH = max(200, size.height - top - bottom)
        return HStack(alignment: .top, spacing: 0) {
            leftColumn
                .frame(width: narrow ? 74 : 80, height: contentH, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 8) {
                center
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: contentH)
            .padding(.leading, narrow ? 12 : 18)
            .padding(.trailing, narrow ? 16 : 24)
            rightColumn
                .frame(width: 102, height: contentH)
        }
        .padding(.leading, left)
        .padding(.trailing, right)
        .padding(.top, top)
        .padding(.bottom, bottom)
    }

    /// Portrait: one row of mode keys, the pads, then BANK | LEVEL | transport + DIG, wordmark + BOUNCE.
    private func portrait(_ size: CGSize) -> some View {
        let inset: CGFloat = size.width < 420 ? 14 : 20
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(modeItems, id: \.self) { item in
                    modeButton(item, key: 30, labelBelow: true)
                        .frame(maxWidth: .infinity)
                }
            }
            center
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 14)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    DeckLabel("Bank")
                    BankGrid(state: state, key: 24, spacing: 10)
                        .padding(.top, 11)
                    Spacer(minLength: 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showsFader {
                    VStack(alignment: .leading, spacing: 0) {
                        faderLabel
                        fader
                            .padding(.top, 1.5)
                    }
                    .frame(width: 102)
                    .frame(maxWidth: .infinity)
                }
                VStack(spacing: 0) {
                    TransportRow(state: state, height: 32)
                    Spacer(minLength: 8)
                    HStack(spacing: 8) {
                        ShiftKey(state: state, height: 44).frame(width: 64)
                        DigButton(state: state, height: 44)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 142)
            .padding(.top, 16)
        }
        .padding(.horizontal, inset)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    /// Phone: SAMPLE · KEYS · FX, the pads, then BANK | REC PLAY | SHIFT. Effects are punch-in (hold FX, hold an
    /// effect pad), so there's no FX slider. The prompt on the lid is the way in to the AI (no DIG key on the phone);
    /// SHIFT holds the secondary functions (mute). The project chip lives on the lid.
    private func phoneDeck(_ size: CGSize) -> some View {
        let short = size.height < 400
        let key: CGFloat = short ? 24 : 28
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(modeItems, id: \.self) { item in
                    modeButton(item, key: key, labelBelow: true)
                        .frame(maxWidth: .infinity)
                }
            }
            center
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, short ? 8 : 12)
            HStack(alignment: .top, spacing: 0) {
                BankGrid(state: state, key: key, spacing: short ? 6 : 9)
                Spacer(minLength: 8)
                TransportRow(state: state, height: key + 4)
                    .frame(width: TransportRow.width(key + 4))
                Spacer(minLength: 8)
                ShiftKey(state: state, height: key + 4)
                    .frame(width: short ? 64 : 76)
            }
            .padding(.top, short ? 8 : 12)
        }
        .padding(.horizontal, 14)
        .padding(.top, short ? 10 : 14)
        .padding(.bottom, 6)
    }

    /// Landscape left column: mode keys stacked (37 pt pitch, SHIFT set apart), grille + wordmark at the foot.
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(modeItems, id: \.self) { item in
                modeButton(item, key: 26, labelBelow: false)
            }
            Spacer(minLength: 0)
        }
    }

    /// Landscape right column, spaced as the mock (BANK 0, keys 17, LEVEL 78, transport 290, DIG 348 of 392).
    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeckLabel("Bank")
            BankGrid(state: state)
                .padding(.top, 11)
            if showsFader {
                faderLabel
                    .padding(.top, 25)
                fader
                    .padding(.top, 1.5)
                    .frame(maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
            }
            TransportRow(state: state, height: 30)
                .padding(.top, 20)
            ShiftKey(state: state, height: 30)
                .padding(.top, 10)
            DigButton(state: state, height: 44)
                .padding(.top, 10)
        }
    }

    @ViewBuilder
    private var center: some View {
        switch state.mode {
        case .keys:
            KeysView(state: state)
        case .padFX:
            PadFXView(state: state)
        case .sample:
            VStack(spacing: 6) {
                SampleModePanel(state: state)
                PadGridView(state: state)
            }
        default:
            PadGridView(state: state)
        }
    }

    /// The FX · HINGE readout is the Duo's hardware feature; the iPad punches effects in with FX + a pad, like the phone.
    private var showsFader: Bool {
        #if os(macOS)
        return true
        #else
        return CrateUI.shared.isDuo
        #endif
    }

    private var faderLabel: some View {
        #if os(macOS)
        DeckLabel("FX")
        #else
        DeckLabel("FX · Hinge")
        #endif
    }

    /// The FX amount (what the hinge does on a Duo; pull it from high to zero for the DROP). No printed scale.
    private var fader: some View {
        PunchFader(state: state, marks: [])
            .frame(width: 40)
            .frame(maxWidth: .infinity)
    }

    // MARK: mode keys

    enum ModeItem: Hashable {
        case arm, keys, fx, octDown, octUp, scale

        /// The three main keys (the KEYS row's extras go on a second row in portrait).
        var isMode: Bool { self == .arm || self == .keys || self == .fx }
    }

    private var modeItems: [ModeItem] {
        state.mode == .keys ? [.arm, .keys, .fx, .octDown, .octUp, .scale] : [.arm, .keys, .fx]
    }

    @ViewBuilder
    private func modeButton(_ item: ModeItem, key: CGFloat, labelBelow: Bool) -> some View {
        let ui = CrateUI.shared
        switch item {
        case .arm:
            ModeKey(glyph: .mic, label: "SAMPLE", on: ui.sampleArmed, key: key, labelBelow: labelBelow,
                    live: ui.sampleArmed, id: "mode-sample") {
                ui.toggleSample(state)
            }
        case .keys:
            ModeKey(glyph: .keys, label: "KEYS", on: state.mode == .keys, key: key, labelBelow: labelBelow,
                    id: "mode-keys") {
                ui.setMode(state.mode == .keys ? .seq : .keys, state)
            }
        case .fx:
            FXHoldKey(key: key, labelBelow: labelBelow)
        case .octDown:
            DeckButton(label: "OCT −", id: "oct-down") { state.keysOctave = max(-3, state.keysOctave - 1) }
                .frame(width: key + 12, height: key)
        case .octUp:
            DeckButton(label: "OCT +", id: "oct-up") { state.keysOctave = min(3, state.keysOctave + 1) }
                .frame(width: key + 12, height: key)
        case .scale:
            DeckButton(label: "SCALE", on: state.scaleLock, toggle: true, id: "scale-lock") { state.scaleLock.toggle() }
                .frame(width: key + 18, height: key)
        }
    }
}

/// SAMPLE mode: the mic sampler (hold to record, release to chop into bank D) above the pads.
/// Owns one MicSampler for as long as SAMPLE mode is on screen.
@MainActor
private struct SampleModePanel: View {
    let state: AppState
    @State private var sampler: MicSampler?

    var body: some View {
        Group {
            if let sampler {
                SampleRecordButton(state: state, sampler: sampler)
                    .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .onAppear {
            if sampler == nil { sampler = MicSampler(state: state) }
        }
    }
}

/// PAD FX fallback for the hinge: PUNCH 0…1 → state.punch + engine.setPunch. Pull it from high to zero = DROP.
struct PunchFader: View {
    let state: AppState
    var marks: [String] = FaderView.percentMarks
    @State private var peak: Double = 0

    var body: some View {
        FaderView(value: state.punch, fill: true, id: "punch-fader", marks: marks, onChange: { v in
            if let hook = CrateUI.shared.onPunch { hook(v); return }
            peak = max(peak, v)
            state.punch = v
            state.engine.setPunch(v)
        }, onEnd: { v in
            if CrateUI.shared.onPunch != nil { return }
            if peak > 0.6 && v < 0.1 {
                state.punch = 0
                state.engine.drop()
                DebugLog.event("drop", ["src": "fader"])
            } else {
                DebugLog.event("punch", ["p": (v * 100).rounded() / 100])
            }
            peak = v
        })
    }
}

/// Phone / non-Duo FX amount: the slim horizontal version of the PUNCH fader (same hinge path, so pulling it from
/// high to zero still fires the DROP).
struct PunchSlider: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 10) {
            DeckLabel(state.fx?.label ?? "FX", size: 6.5)
                .frame(width: 58, alignment: .leading)
            GeometryReader { g in
                let v = min(1, max(0, state.punch))
                let capW: CGFloat = 16
                let travel = max(1, g.size.width - capW)
                let x = capW / 2 + v * travel
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(Deck05.slot)
                        .frame(height: 3)
                        .padding(.horizontal, capW / 2)
                    Rectangle().fill(Deck05.live)
                        .frame(width: max(0, x - capW / 2), height: 3)
                        .offset(x: capW / 2)
                    ZStack {
                        KeyFace(radius: 3)
                        Rectangle().fill(Deck05.live).frame(width: 1.5).padding(.vertical, 5)
                    }
                    .frame(width: capW, height: g.size.height)
                    .offset(x: x - capW / 2)
                }
                .frame(width: g.size.width, height: g.size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                    let v = Double(min(1, max(0, (d.location.x - capW / 2) / travel)))
                    if let hook = CrateUI.shared.onPunch { hook(v) } else { state.punch = v; state.engine.setPunch(v) }
                })
            }
            Text("\(Int((min(1, max(0, state.punch)) * 100).rounded()))%")
                .font(Deck05.font(7, 600))
                .monospacedDigit()
                .foregroundStyle(Deck05.ink2)
                .frame(width: 30, alignment: .trailing)
        }
        .accessibilityElement()
        .accessibilityIdentifier("fx-slider")
        .accessibilityLabel("FX amount")
        .accessibilityValue("\(Int((min(1, max(0, state.punch))) * 100)) percent")
        .accessibilityAdjustableAction { dir in
            let v = min(1, max(0, state.punch + (dir == .increment ? 0.1 : -0.1)))
            if let hook = CrateUI.shared.onPunch { hook(v) } else { state.punch = v; state.engine.setPunch(v) }
        }
    }
}
