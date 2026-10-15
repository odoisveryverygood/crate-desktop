import SwiftUI

/// The black OLED lid on the Duo's inner screen and the iPad, decluttered like the phone (HANDOFF "UI simplification"):
/// ONE header line (project · BPM · bar · loop length · ↶ ↷), the pad line, the main area (step grid / pad editor /
/// song grid), ONE result line, then the one ✦ prompt with ＋ (it grows into a big box while you type).
/// No hero numbers, bank meters or timing strip: the extra height goes to the step grid.
struct LidDisplayView: View {
    let state: AppState

    var body: some View {
        GeometryReader { geo in
            let narrow = geo.size.width < 560
            let side: CGFloat = narrow ? 22 : 28
            let ui = CrateUI.shared
            let focused = ui.promptFocused
            let bottom: CGFloat = narrow ? 20 : 24
            // Book pose: the keyboard covers the lid's bottom, so the prompt rises above it (the content above shrinks).
            let lift = focused ? max(0, ui.keyboardOverlap(geo.frame(in: .global)) + 10 - bottom) : 0
            // Typing with the keyboard elsewhere (laptop pose: it's on the deck half): the prompt becomes a big box.
            let typing = focused && lift == 0
            // An iPad-sized lid: the step grid spreads out.
            let big = geo.size.height > 600
            let songGrid = state.song.songMode && state.mode == .seq && !ui.editorOpen
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    LidHeader(state: state, roomy: geo.size.width >= 430, maxProject: geo.size.width * 0.3)
                    // The song grid needs the room; the pad line (a pad's sound, ‹ ›, EDIT) is PATTERN-view work.
                    if !typing && !songGrid {
                        PadLine(state: state)
                            .padding(.top, 12)
                    }
                    if !typing {
                        Group {
                            if ui.editorOpen {
                                PadEditorView(state: state)
                            } else {
                                mainArea(big: big)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                        .padding(.top, 12)
                        Group {
                            if state.punch > 0.04 {
                                PunchStrip(punch: state.punch, fx: state.fx)
                            } else {
                                LidResultLine(state: state)
                                    .accessibilityIdentifier("ai-chips")
                            }
                        }
                        .frame(height: 16)
                        .padding(.top, 10)
                    }
                }
                .overlay { if focused { DismissPromptLayer() } }
                LidPromptRow(state: state, narrow: narrow, showChips: !focused, chipIDs: LidChips.phoneSet,
                             height: 40, fontSize: 15, expanded: typing)
                    .padding(.top, typing ? 12 : 16)
            }
            .padding(.horizontal, side)
            .padding(.top, narrow ? 16 : 20)
            .padding(.bottom, bottom + lift)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .animation(.easeOut(duration: 0.2), value: lift)
        }
        .background(Theme.oled)
        .ignoresSafeArea(.keyboard)
    }

    /// `big`: an iPad-sized lid, where the step grid spreads out to use the height.
    @ViewBuilder
    private func mainArea(big: Bool) -> some View {
        switch state.mode {
        case .seq:
            if state.song.songMode {
                // SONG tab: the bank × section grid in place of the step grid
                SongGridView(state: state)
            } else {
                // A full beat can have 9+ lanes: keep a comfortable lane pitch and scroll instead of squashing.
                GeometryReader { g in
                    let rows = max(5, SeqRows.build(state, state.engine.pattern).count)
                    let comfy: CGFloat = big ? 26 : 20
                    let need = SeqGridView.fittedHeight(rows: rows, pitch: comfy)
                    if need > g.size.height {
                        ScrollView(.vertical, showsIndicators: false) {
                            SeqGridView(state: state, maxPitch: comfy, dotCap: big ? 1.1 : 1).frame(height: need)
                        }
                    } else {
                        let cap: CGFloat = big ? 48 : 30
                        SeqGridView(state: state, maxPitch: cap, dotCap: big ? 1.35 : 1.15)
                            .frame(height: min(g.size.height, SeqGridView.fittedHeight(rows: rows, pitch: cap)))
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
        case .chop:
            ChopWaveView(state: state).padding(.bottom, 4)
        case .keys:
            KeysWaveView(state: state).padding(.vertical, 4)
        case .sample:
            if (0..<16).contains(where: { state.sound(PadID(.b, $0)) != nil }) {
                ChopWaveView(state: state)
            } else {
                AILogView(state: state, maxLines: 6, size: 10.5)
            }
        case .padFX, .levels16:
            AILogView(state: state, maxLines: 6, size: 10.5)
        }
    }
}

// MARK: - Header line

/// The lid's one header line, like the phone's: project chip · BPM chip (the SONG sheet) · bar · loop menu · ↶ ↷.
struct LidHeader: View {
    let state: AppState
    /// Wide enough for the bar readout and the loop's segments.
    var roomy = true
    var maxProject: CGFloat = 200

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            LidProjectChip(state: state)
                .frame(maxWidth: maxProject, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            TempoChip(state: state, size: 13)
            if roomy {
                BarReadout(state: state, size: 13)
                    // Long-press cycles the back (outer) screen's rotation 0 → 90 → 180 → 270, for however the Duo is held.
                    .onLongPressGesture(minimumDuration: 0.6) {
                        guard CrateUI.shared.isDuo else { return }
                        let d = UserDefaults.standard
                        let next = (d.double(forKey: "crateCrowdTurn") + 90).truncatingRemainder(dividingBy: 360)
                        d.set(next, forKey: "crateCrowdTurn")
                        state.addLog("CROWD", "back screen rotated \(Int(next))°", tint: .grey)
                    }
            }
            Spacer(minLength: 4)
            LoopMenu(state: state, compact: true, segments: roomy)
            HistoryButtons(size: 32)
        }
        .frame(height: 32)
    }
}

// MARK: - LOOP segment bar

/// `LOOP · 4 BARS` + one 15×3 segment per bar: played bars grey, the current bar fills white as it plays.
/// KEYS mode prints the root and octave instead. `LoopMenu` makes it a tap target (1 / 2 / 4 / 8 bars).
struct LoopBar: View {
    let state: AppState
    /// "4 BARS" without the LOOP prefix (the phone header).
    var compact = false
    /// The per-bar segments; a narrow phone header prints just "4 BARS ⌄".
    var segments = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let f = LiveFrame(state)
            let empty = f.pattern.lanes.isEmpty && f.pattern.notes.isEmpty
            let bars = max(1, empty ? state.bars : f.editBars)
            let shown = min(bars, 16)
            let w: CGFloat = bars <= 8 ? 15 : max(4, 144 / CGFloat(shown) - 3)
            let current = f.playing ? f.bar % shown : -1
            let progress = f.playing ? (f.local - Double(f.bar * 16)) / 16 : 0
            HStack(spacing: segments ? 9 : 4) {
                Text(label(bars))
                    .fieldLabel()
                    .foregroundStyle(Theme.lidGrey1)
                    .lineLimit(1)
                    .fixedSize()
                if !segments {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.lidGrey1)
                }
                if segments {
                HStack(spacing: 3) {
                    ForEach(0..<shown, id: \.self) { i in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(i < current ? Theme.lidDone : Theme.lidGrey3)
                            if i == current {
                                Rectangle().fill(Theme.lidInk)
                                    .frame(width: max(1, w * CGFloat(min(1, max(0, progress)))))
                            }
                        }
                        .frame(width: w, height: 3)
                    }
                }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func label(_ bars: Int) -> String {
        if state.mode == .keys && !compact {   // the phone header keeps the loop length; the keys print the notes
            let root = UIHelpers.rootNote(state, state.selectedPad)
            let base = KeysView.baseMidi(root: root, octave: state.keysOctave)
            let oct = (base + 7) / 12 - 1   // octave of the first C on the keyboard
            return "ROOT \(UIHelpers.noteName(root, flat: "♭")) · OCT \(oct)"
        }
        if state.song.songMode { return "SONG" }
        let n = "\(bars) \(bars == 1 ? "BAR" : "BARS")"
        return compact ? n : "LOOP · " + n
    }
}

// MARK: - Result line

/// What the latest DIG produced (or the latest event), parsed from the AI log.
struct LidSummary {
    struct Part {
        var text: String
        var color: Color?
    }

    var parts: [Part] = []
    var timings: [(key: String, value: String, ok: Bool)] = []

    init(_ state: AppState) {
        let log = state.log
        guard !log.isEmpty else {
            timings = Self.fallbackTimings(state)
            return
        }
        let start = log.lastIndex { $0.tag == "JEV" || $0.tag == "KW" } ?? log.startIndex
        var kitMs: Int?, sampleMs: Int?, planMs: Int?, gpt: (ms: Int?, ok: Bool)?
        var digParts: [Part] = []
        for line in log[start...] {
            switch line.tag {
            case "JEV", "KW":
                planMs = line.ms ?? planMs
            case "KIT":
                kitMs = line.ms ?? kitMs
                digParts.append(Part(text: Self.kitPhrase(line.text), color: Theme.bank(.a)))
            case "SAMPLE":
                sampleMs = line.ms ?? sampleMs
                digParts.append(Part(text: Self.samplePhrase(line.text), color: Theme.bank(.b)))
            case "BASS":
                digParts.append(Part(text: "bass line", color: Theme.bank(.c)))
            case "GROOVE":
                digParts.append(Part(text: Self.sentence(line.text), color: Theme.bank(.a)))
            case "LAYER":
                // "+ CAFE SAX · sax on D1… · -1 st to Fm" → "Cafe Sax layer" (no pad / pitch detail in the line)
                let name = (line.text.components(separatedBy: " · ").first ?? line.text)
                    .replacingOccurrences(of: "+ ", with: "").trimmingCharacters(in: .whitespaces)
                digParts.append(Part(text: Self.titleCase(name) + " layer", color: Theme.bank(.d)))
            case "GPT":
                gpt = (line.ms, true)
            case "ERR":
                if line.text.hasPrefix("GPT") { gpt = (nil, false) }
                digParts.append(Part(text: line.text, color: Theme.red))
            default:
                break
            }
        }
        // The newest non-DIG event (crowd rotation, bounce, drop…) takes the line until the next DIG.
        let digTags: Set<String> = ["JEV", "KW", "KIT", "SAMPLE", "BASS", "GROOVE", "LAYER", "GPT", "ERR", "PERFORM"]
        if let last = log.last(where: { $0.tag != "PERFORM" }), !digTags.contains(last.tag) {
            parts = [Part(text: Self.sentence(last.tag.lowercased()) + " · " + last.text, color: Self.tint(last.tint))]
        } else {
            parts = Self.dedupe(digParts)
        }

        // Display keys stay plain ("PLAN", "AI"): no vendor or model names in the lid. A failed AI pass shows nothing.
        if let ms = planMs { timings.append(("PLAN", UIHelpers.msText(ms).spacedUnit, false)) }
        if let ms = kitMs { timings.append(("KIT", UIHelpers.msText(ms).spacedUnit, false)) }
        if let ms = sampleMs { timings.append(("SAMPLE", UIHelpers.msText(ms).spacedUnit, false)) }
        if let g = gpt {
            if g.ok { timings.append(("AI", g.ms.map { UIHelpers.msText($0).spacedUnit } ?? "", true)) }
        }
        if timings.isEmpty { timings = Self.fallbackTimings(state) }
    }

    private static func fallbackTimings(_ state: AppState) -> [(key: String, value: String, ok: Bool)] {
        [("PLAN", state.jevMs.map { "\($0) ms" } ?? "—", false),
         ("AI", state.gptSeconds.map { String(format: "%.1f s", $0) } ?? "—", state.gptSeconds != nil)]
    }

    /// One tab per bank: repeated KIT / SAMPLE lines (a re-dig, a flip) keep only the newest.
    private static func dedupe(_ parts: [Part]) -> [Part] {
        var out: [Part] = []
        for p in parts {
            if let c = p.color, c != Theme.red, let i = out.firstIndex(where: { $0.color == c }) {
                out[i] = p
            } else {
                out.append(p)
            }
        }
        return out
    }

    private static func tint(_ t: Tint) -> Color {
        switch t {
        case .orange: return Theme.bank(.a)
        case .blue: return Theme.bank(.b)
        case .ochre: return Theme.bank(.c)
        case .grey: return Theme.bank(.d)
        case .red: return Theme.red
        }
    }

    /// "J DILLA · VNYL KCK / …" → "J Dilla kit"; single-sound swaps pass through.
    static func kitPhrase(_ text: String) -> String {
        if text.hasPrefix("PAD ") { return text }
        let style = text.components(separatedBy: " · ").first ?? text
        return titleCase(style) + " kit"
    }

    /// "NUJ KEYS · piano · Am · 90 BPM · 2 BAR CHOPS" → "Nuj Keys piano in Am, 90 BPM".
    static func samplePhrase(_ text: String) -> String {
        let c = text.components(separatedBy: " · ")
        guard c.count >= 4, c[3].hasSuffix("BPM") else { return sentence(text) }
        let key = c[2].trimmingCharacters(in: .whitespaces)
        let inKey = (key.isEmpty || key == "?" || key == "—") ? "" : " in \(key)"
        return "\(titleCase(c[0])) \(c[1])\(inKey), \(c[3])"
    }

    static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let f = t.first else { return t }
        return f.uppercased() + t.dropFirst()
    }

    /// "J DILLA" → "J Dilla"; words with digits or symbols stay as they are.
    static func titleCase(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: false).map { w -> String in
            guard w.count > 1, w.allSatisfy({ $0.isLetter }), w == w.uppercased() else { return String(w) }
            return String(w.prefix(1)) + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}

private extension String {
    /// "118ms" → "118 ms", "4.2s" → "4.2 s" (the timing strip's spacing).
    var spacedUnit: String {
        if hasSuffix("ms") { return String(dropLast(2)) + " ms" }
        if hasSuffix("s") { return String(dropLast(1)) + " s" }
        return self
    }
}

/// ONE plain-language result line (Inter 400 13), a thin bank-colour tab before each part.
struct LidResultLine: View {
    let state: AppState
    @State private var changes = AIChangeLog.shared
    @State private var showLog = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 5)) { ctx in
                Group {
                    // The latest AI change says what it touched for 30 s, then the line goes back to the beat summary.
                    if let c = changes.latest, ctx.date.timeIntervalSince(c.at) < 30, !state.isDigging {
                        Text(c.summary)
                            .font(Theme.inter(13))
                            .tracking(-0.065)
                            .foregroundStyle(Theme.lidInk)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("ai-change-summary")
                    } else {
                        beatSummary
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                Analytics.shared.tap("ai_log")
                showLog = true
            }
            // 👍 / 👎 ride along with the change summary (30 s), then the line goes quiet; the log keeps them.
            TimelineView(.periodic(from: .now, by: 5)) { ctx in
                if let c = changes.latest, ctx.date.timeIntervalSince(c.at) < 30 || c.rating != 0 && ctx.date.timeIntervalSince(c.at) < 34 {
                    AIRatingButtons(change: c)
                }
            }
            .fixedSize()
        }
        .sheet(isPresented: $showLog) {
            AILogSheet()
                .presentationDetents([.medium, .large])
                .presentationBackground(Theme.oled)
        }
    }

    private var beatSummary: some View {
        let s = LidSummary(state)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            if s.parts.isEmpty {
                Text(state.isDigging ? "Digging through the crate…" : "Empty crate · describe a beat below and the pads fill from your library")
                    .font(Theme.inter(13))
                    .foregroundStyle(Theme.lidGrey1)
                    .lineLimit(1)
            }
            ForEach(Array(s.parts.enumerated()), id: \.offset) { i, part in
                if i > 0 {
                    Text(" + ").font(Theme.inter(13)).foregroundStyle(Theme.lidInk).fixedSize()
                }
                if let c = part.color {
                    Rectangle().fill(c)
                        .frame(width: 2, height: 10)
                        .offset(y: 0.5)
                        .padding(.leading, 1)
                        .padding(.trailing, 6)
                }
                Text(part.text)
                    .font(Theme.inter(13))
                    .tracking(-0.065)
                    .foregroundStyle(Theme.lidInk)
                    .lineLimit(1)
                    .layoutPriority(Double(s.parts.count - i))
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Prompt row + chips

/// The one prompt row: ＋ (bring a song), the ✦ field, then KEEP JAM / FLIP IT / AI PERFORM (AI PERFORM filled white
/// when on). The chips step aside while you type so the field gets the whole row; narrow lids wrap them below.
struct LidPromptRow: View {
    let state: AppState
    var narrow = false
    var showChips = true
    /// Which chips sit on the row (the phone moves UNDO / REDO to its header).
    var chipIDs: [String] = LidChips.lidSet
    /// Field height (the chips are a little shorter; every hit area is ≥ 44 pt).
    var height: CGFloat = 38
    var fontSize: CGFloat = 14
    /// Phone: the AI status pill shows just its state, so the field keeps room to type.
    var compact = false
    /// Phone: while typing, the field grows into a big multi-line box that takes the lid.
    var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: expanded ? .top : .center, spacing: 8) {
                if !expanded { ImportButton(state: state, size: height) }
                LidPromptLine(state: state, height: height, fontSize: fontSize, compact: compact, expanded: expanded)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showChips {
                    KeepJamChip(state: state, height: height - 8)
                }
                if showChips && !narrow {
                    LidChips(state: state, ids: chipIDs, wrap: false, height: height - 8)
                }
            }
            .frame(height: expanded ? nil : height)
            .frame(maxHeight: expanded ? .infinity : nil)
            if showChips && narrow {
                LidChips(state: state, ids: chipIDs, wrap: true, height: height - 8)
            }
        }
    }
}

/// The prompt field (the only one on the lid): ✦, then what you type. Its placeholder is dim grey and it's empty
/// after you submit (what you asked shows in the result line). ✦ DIG on the deck focuses it (CrateUI.focusRequest),
/// Return digs, Esc or a tap outside it puts the keyboard away.
struct LidPromptLine: View {
    let state: AppState
    var placeholder = "Describe a beat or a change…"
    var shortPlaceholder = "Describe a beat…"
    var height: CGFloat = 38
    var fontSize: CGFloat = 14
    var compact = false
    /// While focused, grow into a big multi-line box (phone). The TextField stays the same view, so focus holds.
    var expanded = false

    @Bindable private var ui = CrateUI.shared
    @FocusState private var focused: Bool

    var body: some View {
        let big = expanded && focused
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: big ? .top : .center, spacing: 9) {
                SparkShape()
                    .fill(focused ? Theme.lidInk : Theme.lidGrey1)
                    .frame(width: big ? 13 : 10, height: big ? 13 : 10)
                    .padding(.top, big ? 6 : 0)
                ZStack(alignment: .topLeading) {
                    if ui.draft.isEmpty {
                        Group {
                            if big {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Describe a beat, or what to change")
                                        .font(Theme.inter(21))
                                    Text("dusty boom bap with rhodes · add a sax line · more hats")
                                        .font(Theme.inter(13))
                                        .foregroundStyle(Theme.lidGrey2)
                                }
                            } else {
                                // the short form when the field is narrow (never a cut-off "Describe a beat or…")
                                ViewThatFits(in: .horizontal) {
                                    Text(placeholder)
                                    Text(shortPlaceholder)
                                    Text("Describe…")
                                }
                                .font(Theme.inter(fontSize))
                                .lineLimit(1)
                            }
                        }
                        .foregroundStyle(Theme.lidPlaceholder)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    TextField("", text: $ui.draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Theme.inter(big ? 21 : fontSize))
                        .lineLimit(big ? 1...8 : 1...1)
                        .foregroundStyle(Theme.lidInk)
                        .tint(Theme.lidInk)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(submit)
                        .onKeyPress(.escape) { focused = false; state.promptFocused = false; return .handled }
                        .crateNoAutocorrect()
                        .accessibilityIdentifier("prompt-field")
                        .accessibilityLabel("Prompt")
                        .accessibilityHint(placeholder)
                }
                .frame(minWidth: 60, maxHeight: big ? .infinity : nil, alignment: .topLeading)
                .layoutPriority(1)
                if !big { AIStatusPill(state: state, showText: !compact) }
            }
            if big {
                HStack {
                    Spacer()
                    Button(action: submit) {
                        HStack(spacing: 7) {
                            SparkShape().fill(Color.black).frame(width: 10, height: 10)
                            Text("DIG").font(Theme.inter(12, 700)).tracking(1.6).foregroundStyle(Color.black)
                        }
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(Capsule().fill(ui.draft.trimmingCharacters(in: .whitespaces).isEmpty
                                                   ? Theme.lidGrey1 : Theme.lidInk))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HitPressStyle())
                    .accessibilityIdentifier("prompt-send")
                }
            }
        }
        .padding(.horizontal, big ? 16 : 12)
        .padding(.vertical, big ? 14 : 0)
        .frame(height: big ? nil : height)
        .frame(maxHeight: big ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: big ? 14 : 10, style: .continuous)
            .fill(Color.white.opacity(focused ? 0.11 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: big ? 14 : 10, style: .continuous)
            .strokeBorder(Color.white.opacity(focused ? 0.28 : 0), lineWidth: 0.8))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { focused = true })
        .background {
            // TextField consumes raw presses; register Escape with the hosting controller
            // so it also works while UIKit's text editor is first responder.
            Button { focused = false; state.promptFocused = false } label: { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .accessibilityHidden(true)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: big)
        // A vertical TextField turns Return into a newline: treat it as submit.
        .onChange(of: ui.draft) { _, t in
            if t.contains("\n") { ui.draft = t.replacingOccurrences(of: "\n", with: " "); submit() }
        }
        .onChange(of: ui.focusRequest) { _, _ in focused = true }
        .onChange(of: ui.blurRequest) { _, _ in focused = false }
        .onChange(of: focused) { _, f in ui.promptFocused = f; state.promptFocused = f }
        .onChange(of: state.promptFocused) { _, f in focused = f }
        .onDisappear { if focused { state.promptFocused = false; ui.promptFocused = false } }
    }

    private func submit() {
        let t = ui.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        focused = false
        ui.draft = ""
        guard !t.isEmpty else { return }
        state.dig(t)
        DebugLog.event("prompt_submit", ["chars": t.count])
    }
}

/// Over the lid's content while the prompt is focused: a tap anywhere outside the field puts the keyboard away.
struct DismissPromptLayer: View {
    var body: some View {
        Color.black.opacity(0.001)
            .contentShape(Rectangle())
            .onTapGesture { CrateUI.shared.blurRequest += 1 }
            .accessibilityHidden(true)
    }
}

/// Press feedback for buttons whose hit area is bigger than what's drawn: a quick dim instead of an outline.
struct HitPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

/// 05 outlined chips over `ActionChips.items` (same ids and actions); AI PERFORM is filled white when on.
struct LidChips: View {
    let state: AppState
    var ids: [String]? = nil
    var wrap = true
    /// Drawn height; the hit area is at least 44 pt tall.
    var height: CGFloat = 30

    /// The chips the mock prints on the prompt row.
    static var lidSet: [String] { ["chip-undo", "chip-redo"] + contextual }
    /// The phone's prompt row (UNDO / REDO are icons in its header): nothing, unless there's something to do now.
    static var phoneSet: [String] { contextual }
    /// FLIP IT shows only right after a song import (its glow); otherwise it lives in the pad editor of a chop pad.
    /// AI PERFORM is off the touch UI (still in ActionChips for keyboards / typed "perform").
    static var contextual: [String] { CrateUI.shared.flipHint ? ["chip-flip-it"] : [] }

    var body: some View {
        let items = ActionChips.items.filter { ids?.contains($0.id) ?? true }
        if wrap {
            ChipFlow(spacing: 6, lineSpacing: 6) {
                ForEach(items) { chip($0) }
            }
        } else {
            HStack(spacing: 6) {
                ForEach(items) { chip($0) }
            }
            .fixedSize()
        }
    }

    private func chip(_ item: ActionChips.Item) -> some View {
        let isPerform = item.id == "chip-ai-perform"
        let isHistory = item.id == "chip-undo" || item.id == "chip-redo"
        let available = item.id == "chip-undo" ? CrateUndoSignal.shared.canUndo : CrateUndoSignal.shared.canRedo
        // UNDO / REDO: solid white while there's something to undo/redo, outlined when not. FLIP IT: white after an import.
        let on = (isPerform && state.performOn) || (isHistory && available)
            || (item.id == "chip-flip-it" && CrateUI.shared.flipHint)
        let dim = isHistory && !available
        let ink = on ? Color.black : Theme.chipText
        return Button {
            tap(item)
        } label: {
            HStack(spacing: 6) {
                if isPerform {
                    SparkShape().fill(ink).frame(width: 8, height: 8)
                }
                Text(item.label)
                    .font(Theme.inter(8, 600))
                    .tracking(8 * 0.08)
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 11)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.lidInk : Color.black))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.chipStroke, lineWidth: 0.6).opacity(on ? 0 : 1))
            .opacity(dim ? 0.55 : 1)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(HitPressStyle())
        .padding(.vertical, -max(0, (44 - height) / 2))
        .accessibilityIdentifier(item.id)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Same actions as `ActionChips`.
    private func tap(_ item: ActionChips.Item) {
        let ui = CrateUI.shared
        switch item.id {
        case "chip-undo":
            Task { @MainActor in await Orchestrator.current?.undo() }
        case "chip-redo":
            Task { @MainActor in await Orchestrator.current?.redo() }
        case "chip-flip-it":
            ui.flipHint = false
            state.onFlip?()
            DebugLog.event("flip")
        case "chip-ai-perform":
            let on = !state.performOn
            state.performOn = on
            state.onPerformToggle?(on)
            DebugLog.event("perform_toggle", ["on": on])
        default:
            if let p = item.prompt {
                ui.draft = ""
                ui.blurRequest += 1
                state.dig(p)
            }
        }
    }
}

/// THINKING… / ARRANGING… while the AI works, then ✓ DONE or × FAILED for a few seconds.
struct AIStatusPill: View {
    let state: AppState
    /// The label and status text ("ARRANGING · playing · GPT is arranging"); the phone shows just the spinner.
    var showText = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let age = ctx.date.timeIntervalSince(state.aiStatusAt)
            let s = state.isDigging ? AIStatus.thinking : state.aiStatus
            let visible = s == .thinking || s == .arranging || ((s == .done || s == .failed) && age < 4)
            if visible {
                HStack(spacing: 6) {
                    switch s {
                    case .thinking, .arranging:
                        DotSpinner(color: Theme.live, dot: 1.6)
                    case .done:
                        Text("✓").foregroundStyle(Theme.live)
                    default:
                        Text("×").foregroundStyle(Color.red)
                    }
                    // The phone shows only the spinner / ✓ / ×: the result line says what happened, and the
                    // field keeps its room next to FLIP IT and AI PERFORM.
                    if showText {
                        Text(label(s))
                            .font(Theme.inter(6.8, 700))
                            .tracking(0.7)
                            .foregroundStyle(s == .failed ? Color.red : Theme.lidInk)
                    }
                    if showText, !state.aiStatusText.isEmpty, s != .thinking {
                        Text(state.aiStatusText)
                            .font(Theme.inter(8.5))
                            .foregroundStyle(Theme.lidGrey1)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 170, alignment: .leading)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
                .fixedSize()
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("ai-status")
            }
        }
    }

    private func label(_ s: AIStatus) -> String {
        switch s {
        case .thinking: return "THINKING"
        case .arranging: return "ARRANGING"
        case .done: return "DONE"
        case .failed: return "FAILED"
        case .idle: return ""
        }
    }
}
