import SwiftUI

// Compact lid controls: tempo, loop length, bar position, undo / redo. Every one is a visible tap target;
// nothing is changed by an invisible drag.

/// "100 BPM": tap for the SONG sheet (tempo, swing, key, click, velocity). During a count-in it shows the beats left.
struct TempoChip: View {
    let state: AppState
    var size: CGFloat = 13

    var body: some View {
        Button { CrateUI.shared.songSheetOpen = true } label: {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let n = CrateUI.shared.countIn {
                        Text("\(n)").font(Theme.inter(size, 600)).foregroundStyle(Theme.live)
                        Text("COUNT-IN").font(Theme.inter(size * 0.62, 600)).tracking(0.6).foregroundStyle(Theme.live)
                    } else {
                        Text(SongFormat.bpm(currentBPM(state)))
                            .font(Theme.inter(size, 600)).monospacedDigit().foregroundStyle(Theme.lidInk)
                        Text("BPM").font(Theme.inter(size * 0.62, 600)).tracking(0.6).foregroundStyle(Theme.lidGrey1)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.chipStroke, lineWidth: 0.6))
                .fixedSize()
                .frame(minHeight: 44)   // hit area; the header row stays 30 tall
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Tempo")
                .accessibilityValue("\(SongFormat.bpm(currentBPM(state))) BPM")
            }
        }
        .buttonStyle(HitPressStyle())
        .padding(.vertical, -9)
        .accessibilityIdentifier("tempo-chip")
        .songSheet(state)
    }
}

func currentBPM(_ state: AppState) -> Double { state.engine.bpm.isFinite ? state.engine.bpm : state.bpm }

extension View {
    /// The SONG sheet, presented while `CrateUI.songSheetOpen` (the phone's BPM chip, the iPad's BPM number).
    func songSheet(_ state: AppState) -> some View {
        sheet(isPresented: Binding(get: { CrateUI.shared.songSheetOpen }, set: { CrateUI.shared.songSheetOpen = $0 })) {
            SongSheet(state: state)
        }
    }
}

/// SONG: tempo (type it, ±1 with hold-to-repeat, TAP), swing, key, click and pad velocity on one sheet.
/// The first tempo / swing / key change in a visit is one UNDO step; CLICK and VELOCITY are preferences.
struct SongSheet: View {
    let state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var taps: [Date] = []
    @State private var checkpointed = false
    @State private var bpm: Double = 90
    @State private var swing: Double = 50
    @State private var typed = ""
    @State private var typing = false
    @FocusState private var fieldFocused: Bool
    @State private var keyOpen = false
    /// Bumped on a key change: the transpose lives in the engine's pattern, which SwiftUI doesn't observe.
    @State private var keyVersion = 0
    @State private var detent: PresentationDetent = .height(SongSheet.closedHeight)
    @State private var repeatTask: Task<Void, Never>?
    @State private var pressStepped = false
    @AppStorage(SongPrefs.clickKey) private var click = false
    @AppStorage(SongPrefs.velocityKey) private var velocity = VelocityMode.full.rawValue

    static let swings: [Double] = [50, 54, 58, 62, 66, 70]
    static let closedHeight: CGFloat = 560

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 18) {
                HStack {
                    Text("SONG").fieldLabel(7.5).foregroundStyle(Theme.lidGrey1)
                    Spacer()
                    Button { commitTyped(); dismiss() } label: {
                        Text("DONE")
                            .font(Theme.inter(12, 600)).tracking(1).foregroundStyle(Color.black)
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .background(Capsule().fill(Theme.lidInk))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(HitPressStyle())
                    .accessibilityIdentifier("tempo-done")
                }
                bpmRow
                Button(action: tap) {
                    Text(taps.count >= 2 ? "TAP · \(taps.count)" : "TAP TEMPO")
                        .font(Theme.inter(12, 700)).tracking(1.6)
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.lidInk))
                        .contentShape(Rectangle())
                }
                .buttonStyle(ChipPressStyle())
                .accessibilityIdentifier("tempo-tap")
                section("SWING") {
                    HStack(spacing: 6) {
                        ForEach(Self.swings, id: \.self) { s in
                            choice("\(Int(s))", on: abs(swing - s) < 2, id: "swing-\(Int(s))") { setSwing(s) }
                        }
                    }
                }
                keySection
                section("CLICK", hint: "a click on every beat while playing · count-in always clicks · never in bounces") {
                    HStack(spacing: 6) {
                        choice("OFF", on: !click, id: "click-off") { setClick(false) }
                        choice("ON", on: click, id: "click-on") { setClick(true) }
                    }
                }
                section("VELOCITY", hint: (VelocityMode(rawValue: velocity) ?? .height).hint) {
                    HStack(spacing: 6) {
                        ForEach(VelocityMode.allCases, id: \.self) { m in
                            choice(m.label, on: velocity == m.rawValue, id: "velocity-\(m.rawValue)") { setVelocity(m) }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 16)
        }
        .background(Theme.oled)
        .presentationDetents([.height(Self.closedHeight), .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.oled)
        .onAppear {
            bpm = currentBPM(state)
            swing = state.engine.swing
        }
        .onDisappear {
            repeatTask?.cancel()
            commitTyped()
        }
        .onChange(of: fieldFocused) { _, focused in if !focused { commitTyped() } }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("SET") { commitTyped() }
                    .font(Theme.inter(13, 700))
                    .accessibilityIdentifier("tempo-set")
            }
        }
    }

    // MARK: Tempo

    /// [−]  92  [+]: tap the number to type a tempo; hold − / + to run (1 per step, then by 5 after a second).
    private var bpmRow: some View {
        HStack(spacing: 14) {
            nudge("−", id: "tempo-down", dir: -1)
            Group {
                if typing {
                    // starts empty with the current tempo as the placeholder, so typing replaces it
                    TextField("", text: $typed, prompt: Text(SongFormat.bpm(bpm)).foregroundStyle(Theme.lidGrey2))
                        .crateDecimalKeyboard()
                        .focused($fieldFocused)
                        .multilineTextAlignment(.center)
                        .font(Theme.interLight(56)).monospacedDigit()
                        .foregroundStyle(Theme.lidInk)
                        .tint(Theme.live)
                        .onSubmit { commitTyped() }
                        .accessibilityIdentifier("tempo-field")
                } else {
                    Button(action: beginTyping) {
                        Text(SongFormat.bpm(bpm))
                            .font(Theme.interLight(56)).monospacedDigit().tracking(-2)
                            .foregroundStyle(Theme.lidInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Theme.chipStroke).frame(width: 46, height: 1).offset(y: 2)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tempo-value")
                    .accessibilityLabel("Tempo \(SongFormat.bpm(bpm)), tap to type")
                }
            }
            .frame(minWidth: 130)
            nudge("+", id: "tempo-up", dir: 1)
        }
    }

    private func nudge(_ label: String, id: String, dir: Int) -> some View {
        Button {
            // a press already stepped (and maybe repeated); accessibility / automation taps step here
            if pressStepped { pressStepped = false } else { step(dir, by: 1) }
        } label: {
            Text(label)
                .font(Theme.inter(24, 400)).foregroundStyle(Theme.lidInk)
                .frame(width: 56, height: 56)
                .background(Circle().strokeBorder(Theme.chipStroke, lineWidth: 0.8))
                .contentShape(Circle())
        }
        .buttonStyle(HoldRepeatStyle { pressed in
            if pressed {
                pressStepped = true
                step(dir, by: 1)
                startRepeat(dir)
            } else {
                repeatTask?.cancel()
                repeatTask = nil
            }
        })
        .accessibilityIdentifier(id)
    }

    /// Held: 0.4 s, then 1 BPM per tick at 8 Hz; after a second of holding, jumps of 5 at 10 Hz.
    private func startRepeat(_ dir: Int) {
        repeatTask?.cancel()
        let began = Date()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                let fast = Date().timeIntervalSince(began) >= 1.0
                step(dir, by: fast ? 5 : 1)
                try? await Task.sleep(for: .milliseconds(fast ? 100 : 125))
            }
        }
    }

    /// ±1, or to the next multiple of 5 when running fast.
    private func step(_ dir: Int, by n: Int) {
        if n == 1 {
            setBPM(bpm + Double(dir))
        } else {
            let v = bpm.rounded()
            let next = dir > 0 ? (floor(v / 5) + 1) * 5 : (ceil(v / 5) - 1) * 5
            setBPM(next)
        }
    }

    private func beginTyping() {
        typed = ""
        typing = true
        DispatchQueue.main.async { fieldFocused = true }
        DebugLog.event("tempo_type", ["open": true])
    }

    /// Return / SET / DONE / focus lost: apply the typed tempo (decimals ok, 50–200). Junk leaves it as it was.
    private func commitTyped() {
        guard typing else { return }
        typing = false
        fieldFocused = false
        let text = typed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if let v = Double(text), v.isFinite, v > 0 {
            setBPM(v)
        }
        DebugLog.event("tempo_type", ["open": false, "text": text, "bpm": bpm])
    }

    /// Average of the last few tap intervals; a pause of 2 s starts a new count.
    private func tap() {
        let now = Date()
        if let last = taps.last, now.timeIntervalSince(last) > 2 { taps = [] }
        taps.append(now)
        if taps.count > 5 { taps.removeFirst(taps.count - 5) }
        guard taps.count >= 2 else { return }
        let gaps = zip(taps.dropFirst(), taps).map { $0.timeIntervalSince($1) }
        let avg = gaps.reduce(0, +) / Double(gaps.count)
        guard avg > 0.2 else { return }
        setBPM((60 / avg).rounded())
    }

    private func setBPM(_ v: Double) {
        let clamped = (min(200, max(50, v)) * 10).rounded() / 10
        guard clamped != bpm || clamped != currentBPM(state) else { return }
        Orchestrator.current?.setTempoExact(clamped, checkpoint: !checkpointed)
        checkpointed = true
        bpm = clamped
        DebugLog.event("tempo_sheet", ["bpm": clamped])
    }

    private func setSwing(_ s: Double) {
        if !checkpointed { Orchestrator.current?.checkpoint("swing \(Int(swing))") }
        checkpointed = true
        state.engine.swing = s
        state.swing = s
        swing = s
        DebugLog.event("swing", ["swing": s])
    }

    // MARK: Key

    /// KEY  F♯m ⌄ → 12 roots + MAJOR / MINOR. A root moves the sample, bass and keys (nearest way, ±6); MAJOR / MINOR
    /// switches to the relative key (same notes).
    private var keySection: some View {
        _ = keyVersion
        let sounding = SongKey.sounding(state.scaleKey, transpose: state.engine.pattern.transpose)
        let shift = state.engine.pattern.transpose
        return section("KEY", hint: keyOpen ? "moves the sample, bass and keys · drums stay" : nil) {
            VStack(alignment: .leading, spacing: 8) {
                Button { withAnimation(Theme.quick) { keyOpen.toggle() }; detent = keyOpen ? .large : .height(Self.closedHeight) } label: {
                    HStack(spacing: 8) {
                        Text(sounding.map { SongKey.display($0.pc, minor: $0.minor) } ?? "—")
                            .font(Theme.inter(15, 600)).foregroundStyle(Theme.lidInk)
                        if shift != 0 {
                            Text(UIHelpers.signed(shift))
                                .font(Theme.inter(10, 600)).monospacedDigit().foregroundStyle(Theme.lidGrey1)
                        }
                        Spacer()
                        Image(systemName: keyOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.lidGrey1)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.chipStroke, lineWidth: 0.6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(ChipPressStyle())
                .accessibilityIdentifier("key-chip")
                .accessibilityLabel("Key \(sounding.map { SongKey.display($0.pc, minor: $0.minor) } ?? "none")")
                if keyOpen { keyPicker(sounding) }
            }
        }
    }

    private func keyPicker(_ sounding: (pc: Int, minor: Bool)?) -> some View {
        let minor = sounding?.minor ?? false
        return VStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<6, id: \.self) { col in
                        let pc = row * 6 + col
                        choice(SongKey.pretty[pc], on: sounding?.pc == pc, id: "key-\(SongKey.roots[pc].lowercased())") {
                            setKey(pc: pc, minor: minor)
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                choice("MAJOR", on: sounding != nil && !minor, id: "key-major") { setMode(minor: false, sounding) }
                choice("MINOR", on: sounding != nil && minor, id: "key-minor") { setMode(minor: true, sounding) }
            }
        }
    }

    private func setKey(pc: Int, minor: Bool) {
        Orchestrator.current?.setSongKey(pc: pc, minor: minor, checkpoint: !checkpointed)
        checkpointed = true
        keyVersion += 1
    }

    /// MAJOR ⇄ MINOR = the relative key (A minor ⇄ C major), so the sample isn't re-pitched.
    private func setMode(minor: Bool, _ sounding: (pc: Int, minor: Bool)?) {
        guard let s = sounding else {
            setKey(pc: 0, minor: minor)
            return
        }
        guard s.minor != minor else { return }
        setKey(pc: (s.pc + (minor ? 9 : 3)) % 12, minor: minor)
    }

    // MARK: Click + velocity

    private func setClick(_ on: Bool) {
        click = on
        state.engine.metronome = on
    }

    private func setVelocity(_ m: VelocityMode) {
        velocity = m.rawValue
        DebugLog.event("velocity_mode", ["mode": m.rawValue])
    }

    // MARK: Pieces

    private func section<C: View>(_ title: String, hint: String? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).fieldLabel(7.5).foregroundStyle(Theme.lidGrey1)
            content()
            if let hint {
                Text(hint).font(Theme.inter(9.5, 500)).foregroundStyle(Theme.lidGrey1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choice(_ label: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.inter(11, 600)).monospacedDigit()
                .foregroundStyle(on ? Color.black : Theme.lidInk)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity).frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.lidInk : Color.black))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.chipStroke, lineWidth: 0.6).opacity(on ? 0 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(ChipPressStyle())
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A button whose press (finger down) and release are reported, for hold-to-repeat. The button's own action still
/// fires on release.
struct HoldRepeatStyle: ButtonStyle {
    let onPress: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .onChange(of: configuration.isPressed) { _, pressed in onPress(pressed) }
    }
}

/// The playing bar.beat, small ("2.3"). Stopped, it shows where PLAY will start (the viewed bar).
struct BarReadout: View {
    let state: AppState
    var size: CGFloat = 13

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let f = LiveFrame(state)
            let bar = f.playing ? f.bar : min(CrateUI.shared.viewBar ?? 0, f.bars - 1)
            HStack(spacing: 0) {
                Text("\(bar + 1)").foregroundStyle(f.playing ? Theme.lidInk : Theme.lidGrey1)
                Text(".\(f.playing ? f.beat + 1 : 1)").foregroundStyle(Theme.lidGrey1)
            }
            .font(Theme.inter(size, 500)).monospacedDigit()
            .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("bar-beat")
        .accessibilityLabel("Bar")
    }
}

/// ALL · 1 2 3 4 (· 5 6 7 8): the bar the step grid shows and edits. ALL (default) follows the playhead and a step
/// goes into every bar; a number shows that bar only and edits only it. Stopped, PLAY starts on the picked bar;
/// playing, it jumps there on the next beat. Bars come in groups of four, so an 8-bar loop's second half is one tap.
/// SONG at the right end shows the song grid in the main area and plays the song; ALL or a bar number goes back to
/// PATTERN mode (the loop and its step grid).
struct BarPager: View {
    let state: AppState
    /// Tap height (at least 44 pt); the segments are drawn `visual` tall inside it.
    var height: CGFloat = 44
    var visual: CGFloat = 36

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let f = LiveFrame(state)
            let song = state.song.songMode
            let bars = f.editBars
            let view = song ? nil : CrateUI.shared.viewBar.flatMap { $0 < bars ? $0 : nil }
            let beat = f.pattern.lanes.values.contains { !$0.isEmpty } || f.pattern.notes.values.contains { !$0.isEmpty }
            // a 1-bar loop has nothing to page, but SONG is there once there's a beat
            if bars > 1 || beat || song { row(f, bars: bars, view: view, song: song) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bar-pager")
    }

    private func row(_ f: LiveFrame, bars: Int, view: Int?, song: Bool) -> some View {
        HStack(spacing: 4) {
            segment("ALL", selected: !song && view == nil, playing: false, progress: 0, id: "bar-all") {
                pick(nil)
            }
            .frame(width: 44)
            if bars > 1 {
                ForEach(0..<((bars + 3) / 4), id: \.self) { g in
                    HStack(spacing: 3) {
                        ForEach((g * 4)..<min(bars, g * 4 + 4), id: \.self) { b in
                            let here = !song && f.playing && f.bar == b
                            segment("\(b + 1)", selected: !song && view == b, playing: here,
                                    progress: here ? (f.local - Double(b * 16)) / 16 : 0, id: "bar-\(b + 1)") {
                                pick(!song && view == b ? nil : b)
                            }
                        }
                    }
                    .padding(.leading, g > 0 ? 5 : 0)
                }
            } else {
                Spacer(minLength: 0)
            }
            segment("SONG", selected: song, playing: song && f.playing,
                    progress: song ? f.local / Double(max(1, f.total)) : 0, id: "bar-song") {
                guard !state.song.songMode else { return }
                Orchestrator.current?.enterSong(tap: true)
            }
            .frame(width: 52)
            .padding(.leading, 5)
        }
        .frame(height: height)
        .onChange(of: bars) { _, n in
            if let v = CrateUI.shared.viewBar, v >= n { CrateUI.shared.showBar(nil, state) }
        }
    }

    /// ALL / a bar number: PATTERN mode on that view (leaving SONG mode cues the loop from that bar on the next bar line).
    private func pick(_ bar: Int?) {
        if state.song.songMode {
            Orchestrator.current?.leaveSong(toBar: bar ?? 0, tap: true)
            CrateUI.shared.viewBar = bar
        } else {
            CrateUI.shared.showBar(bar, state)
        }
    }

    private func segment(_ label: String, selected: Bool, playing: Bool, progress: Double, id: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.lidInk : Color.black)
                RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.chipStroke, lineWidth: 0.6).opacity(selected ? 0 : 1)
                if playing {
                    GeometryReader { g in
                        Rectangle().fill(Theme.live)
                            .frame(width: max(2, g.size.width * CGFloat(min(1, max(0, progress)))), height: 2.5)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                Text(label)
                    .font(Theme.inter(label.count > 2 ? 9.5 : 11.5, 700)).tracking(0.6).monospacedDigit()
                    .foregroundStyle(selected ? Color.black : (playing ? Theme.lidInk : Theme.lidGrey1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: min(visual, height))
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChipPressStyle())
        .accessibilityIdentifier(id)
        .accessibilityLabel(label == "ALL" ? "All bars" : label == "SONG" ? "Song" : "Bar \(label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The LOOP bar as a menu: tap it, pick 1, 2, 4 or 8 bars.
struct LoopMenu: View {
    let state: AppState
    var compact = false
    var segments = true

    var body: some View {
        Menu {
            ForEach([1, 2, 4, 8], id: \.self) { n in
                Button {
                    if state.song.songMode { Orchestrator.current?.leaveSong(toBar: 0, tap: true) }
                    Orchestrator.current?.setBars(n)
                } label: {
                    if n == currentBars && !state.song.songMode {
                        Label("\(n) \(n == 1 ? "bar" : "bars")", systemImage: "checkmark")
                    } else { Text("\(n) \(n == 1 ? "bar" : "bars")") }
                }
            }
            Divider()
            // SONG: the bank × section arrangement (✦ ARRANGE builds a whole song from this beat).
            Button {
                if state.song.songMode { Orchestrator.current?.leaveSong(toBar: 0, tap: true) }
                else { Orchestrator.current?.enterSong(tap: true) }
            } label: {
                if state.song.songMode { Label("Song", systemImage: "checkmark") }
                else { Label("Song · arrange", systemImage: "square.grid.3x2") }
            }
        } label: {
            LoopBar(state: state, compact: compact, segments: segments)
                .padding(.vertical, 6)
                .frame(minWidth: 44, minHeight: 44)   // hit area; the header row stays 30 tall
                .contentShape(Rectangle())
        }
        .padding(.vertical, -7)
        .accessibilityIdentifier("loop-bar")
        .accessibilityLabel("Loop length")
        .accessibilityValue("\(currentBars) bars")
    }

    private var currentBars: Int {
        if state.song.songMode { return max(1, state.bars) }   // the loop's length, not the song's
        let p = state.engine.pattern
        return max(1, p.lanes.isEmpty && p.notes.isEmpty ? state.bars : p.bars)
    }
}

/// ↶ ↷ (dim when there's nothing to undo / redo). Drawn at `size`, each with a 44 pt hit area that overhangs the
/// row instead of making it taller.
struct HistoryButtons: View {
    var size: CGFloat = 30

    var body: some View {
        let undo = CrateUndoSignal.shared
        let hang = max(0, (44 - size) / 2)
        HStack(spacing: 0) {
            icon("arrow.uturn.backward", on: undo.canUndo, id: "undo") {
                Task { @MainActor in await Orchestrator.current?.undo() }
            }
            icon("arrow.uturn.forward", on: undo.canRedo, id: "redo") {
                Task { @MainActor in await Orchestrator.current?.redo() }
            }
        }
        .padding(.horizontal, -hang)
        .padding(.vertical, -hang)
    }

    private func icon(_ name: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? Theme.lidInk : Theme.lidGrey2)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.chipStroke, lineWidth: 0.6))
                .frame(width: max(44, size), height: max(44, size))
                .contentShape(Rectangle())
        }
        .buttonStyle(HitPressStyle())
        .disabled(!on)
        .accessibilityIdentifier("history-\(id)")
        .accessibilityLabel(id == "undo" ? "Undo" : "Redo")
    }
}

/// KEEP JAM: shows up once you've played pads over the loop with REC off; one tap writes that jam into the beat
/// (like the MPC's retrospective record, without the button combo). Gone a minute after the last hit.
struct KeepJamChip: View {
    let state: AppState
    /// Drawn height; the hit area is at least 44 pt tall.
    var height: CGFloat = 30

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let info = state.engine.jamInfo()
            if info.count > 0, info.age < 60 {
                Button { Orchestrator.current?.keepJam() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.live).frame(width: 6, height: 6)
                        Text("KEEP JAM").font(Theme.inter(8, 700)).tracking(0.7).foregroundStyle(Color.black)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: height)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.lidInk))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HitPressStyle())
                .padding(.vertical, -max(0, (44 - height) / 2))
                .accessibilityIdentifier("chip-keep-jam")
                .accessibilityLabel("Keep jam, \(info.count) hits")
            }
        }
        .fixedSize()
    }
}
