import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Pad line (lid)

/// The selected pad on the lid: bank tag, name, ‹ › (the next library sound of the same type) and EDIT.
/// While SAMPLE is armed it shows the mic; while a pad is held it shows the take; with the FX layer up, what to tap.
struct PadLine: View {
    let state: AppState

    var body: some View {
        let ui = CrateUI.shared
        HStack(spacing: 8) {
            if VoiceLine.shows {
                VoiceLine(state: state)
            } else if let pad = ui.recordingPad {
                tag("● REC", Theme.live)
                Text("\(pad.bank.letter)\(pad.number) · \(String(format: "%.1f", ui.sampler?.seconds ?? 0)) s · "
                     + (ui.recordLocked ? "LOCKED" : "LET GO TO STOP · SLIDE UP TO LOCK"))
                    .font(Theme.inter(9, 600)).tracking(0.9).foregroundStyle(Theme.lidInk).lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                MicMeter(level: ui.sampler?.level ?? 0).frame(width: ui.recordLocked ? 44 : 70, height: 6)
                if ui.recordLocked {
                    chip("STOP", id: "take-stop", filled: true) { ui.endTake(pad) }
                }
            } else if ui.sampleArmed {
                tag("MIC", Theme.live)
                Text("HOLD A PAD TO RECORD INTO IT")
                    .font(Theme.inter(9, 600)).tracking(0.9).foregroundStyle(Theme.lidInk).lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                chip("CANCEL", id: "sample-cancel") { ui.sampleArmed = false }
            } else if ui.fxLayer {
                tag("FX", Theme.live)
                Text("HOLD A PAD FOR ITS EFFECT · HIGHER = MORE")
                    .font(Theme.inter(9, 600)).tracking(0.9).foregroundStyle(Theme.lidInk).lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                Text(state.fx?.label ?? "PUNCH").font(Theme.mono(8)).foregroundStyle(Theme.lidGrey1).lineLimit(1)
            } else if ui.muteLayer {
                MuteLine(state: state)
            } else {
                let pad = state.selectedPad
                let sound = state.sound(pad)
                tag("\(pad.bank.letter)\(pad.number)", Theme.bank(pad.bank))
                Text(sound?.name ?? "EMPTY PAD")
                    .font(Theme.inter(11, 600)).tracking(0.8)
                    .foregroundStyle(sound == nil ? Theme.lidGrey1 : Theme.lidInk)
                    .lineLimit(1).truncationMode(.tail)
                    .accessibilityIdentifier("pad-name")
                // ‹ › sit together; their 44 pt hit areas touch, the drawn keys keep a small gap
                if Orchestrator.current?.canSwap(pad) == true {
                    HStack(spacing: 0) {
                        chip("‹", id: "pad-prev") { swap(pad, -1) }
                        chip("›", id: "pad-next") { swap(pad, 1) }
                        DiceChip(pad: pad)
                    }
                } else if Orchestrator.current?.canSwapSample(pad) == true {
                    HStack(spacing: 0) {
                        chip("‹", id: "sample-prev") { swapSample(-1) }
                        chip("›", id: "sample-next") { swapSample(1) }
                        DiceChip(pad: pad)
                    }
                }
                Spacer(minLength: 6)
                if sound != nil {
                    chip(ui.editorOpen ? "DONE" : "EDIT", id: "pad-edit", filled: ui.editorOpen) {
                        ui.editorOpen.toggle()
                        DebugLog.event("editor", ["open": ui.editorOpen])
                    }
                }
            }
        }
        .frame(height: Self.height)
    }

    /// Drawn height of the line and its keys (every key's hit area is 44 pt).
    static let height: CGFloat = 32
    /// Every key on the line: same corner and stroke; the one-glyph keys (‹ › 🎲) are also the same width.
    static let keyRadius: CGFloat = 7
    static let keyStroke: CGFloat = 0.7
    static let glyphWidth: CGFloat = 36

    private func swap(_ pad: PadID, _ step: Int) {
        Task { @MainActor in await Orchestrator.current?.swapSound(pad, step: step) }
    }

    /// The whole sample (all 16 chops) for the next / previous library loop.
    private func swapSample(_ step: Int) {
        Task { @MainActor in await Orchestrator.current?.swapSample(step: step) }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Theme.inter(9, 700)).tracking(0.5)
            .foregroundStyle(Color.black)
            .padding(.horizontal, 7)
            .frame(height: 19)
            .background(RoundedRectangle(cornerRadius: 4).fill(color))
            .fixedSize()
    }

    /// EDIT / DONE / ‹ › / CANCEL / STOP: drawn `height` tall with readable type, hit area ≥ 44 × 44 overhanging the line.
    private func chip(_ label: String, id: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        let glyph = label.count == 1
        let h = Self.height
        return Button(action: action) {
            if glyph {
                Text(label)
                    .font(Theme.inter(17, 500))
                    .foregroundStyle(Theme.chipText)
                    .padLineKey()
            } else {
                Text(label)
                    .font(Theme.inter(11, 600)).tracking(1)
                    .foregroundStyle(filled ? Color.black : Theme.chipText)
                    .frame(minWidth: 40)
                    .padding(.horizontal, 14)
                    .frame(height: h)
                    .background(RoundedRectangle(cornerRadius: Self.keyRadius).fill(filled ? Theme.lidInk : Color.black))
                    .overlay(RoundedRectangle(cornerRadius: Self.keyRadius)
                        .strokeBorder(Theme.chipStroke, lineWidth: Self.keyStroke).opacity(filled ? 0 : 1))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(HitPressStyle())
        .padding(.vertical, -(44 - h) / 2)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label == "‹" ? "Previous sound" : label == "›" ? "Next sound" : label)
    }
}

extension View {
    /// A one-glyph key on the pad line (‹ › 🎲): one size for all of them, hit area 44 × 44.
    func padLineKey() -> some View {
        frame(width: PadLine.glyphWidth, height: PadLine.height)
            .background(RoundedRectangle(cornerRadius: PadLine.keyRadius).fill(Color.black))
            .overlay(RoundedRectangle(cornerRadius: PadLine.keyRadius).strokeBorder(Theme.chipStroke, lineWidth: PadLine.keyStroke))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// The mic input level while SAMPLE records (orange cells, red at the top).
struct MicMeter: View {
    var level: Double
    var body: some View {
        GeometryReader { g in
            let cells = 14
            let lit = Int((pow(min(1, max(0, level)), 0.5) * Double(cells)).rounded())
            HStack(spacing: 2) {
                ForEach(0..<cells, id: \.self) { i in
                    Rectangle().fill(i < lit ? (i > cells - 3 ? Theme.red : Theme.live) : Theme.lidGrey3)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

// MARK: - Pad editor (lid main area)

/// EDIT: the selected pad's sound, big. Drag its two edges; pinch to zoom, drag elsewhere to scroll when zoomed,
/// tap to hear it. A slice of a song is shown in context with its neighbours: moving its edge moves theirs (they share
/// the line), and tapping a neighbour moves to that slice. Under it, the pad's sound controls (`PadControlsRow`:
/// level, filter, attack, release, key, stretch, reverse, ★). DONE on the pad line closes.
struct PadEditorView: View {
    let state: AppState
    @State private var dragging: DragMode? = nil
    enum DragMode { case start, end, pan }
    /// The visible span once pinched or scrolled (seconds in the source file); nil = the default view for the pad.
    @State private var view: ClosedRange<Double>? = nil
    @State private var pinch: (anchor: Double, frac: Double, span: Double)? = nil
    @State private var panFrom: ClosedRange<Double>? = nil
    @State private var pinchEndedAt = Date.distantPast
    /// The editor's width: the sound controls take one row on a wide lid, two on a phone.
    @State private var width: CGFloat = 370

    var body: some View {
        let ui = CrateUI.shared
        let pad = state.selectedPad
        if let s = state.sound(pad), let orch = Orchestrator.current {
            let dur = max(0.01, orch.sourceDuration(s))
            let start = ui.editPreviewStart ?? s.start
            let end = ui.editPreviewEnd ?? (s.end ?? dur)
            let edges = orch.sharedEdges(pad)
            let slice = edges.prev != nil || edges.next != nil
            let win = view ?? Self.window(start: s.start, end: s.end ?? dur, duration: dur, slice: slice)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(String(format: "%.2f – %.2f s", start, end))
                        .font(Theme.mono(11)).monospacedDigit().foregroundStyle(Theme.lidInk)
                    let chopPad = slice && pad.bank == orch.chopBank
                    Text(chopPad ? "SLICE \(pad.number) · DRAG EDGES" : slice ? "SLICE \(pad.number) · DRAG EDGES · PINCH TO ZOOM"
                         : "DRAG EDGES · PINCH TO ZOOM")
                        .fieldLabel().foregroundStyle(Theme.lidGrey1).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    if chopPad {
                        // FIND CHOPS again: new cuts on the beat at real attacks; ★ pads keep theirs. One undo step.
                        Button {
                            Analytics.shared.tap("rechop", ["bank": pad.bank.letter])
                            Task { @MainActor in await orch.rechop(mode: .find) }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .semibold))
                                Text("RE-CHOP").font(Theme.inter(10, 600)).tracking(0.9)
                            }
                            .foregroundStyle(Theme.chipText)
                            .padding(.horizontal, 12).frame(minWidth: 56).frame(height: 26)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.chipStroke, lineWidth: 0.6))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HitPressStyle())
                        .padding(.vertical, -9)
                        .accessibilityIdentifier("editor-rechop")
                        // FLIP IT lives here now (off the prompt row): re-sequence these chops, drums and bass stay.
                        Button {
                            Analytics.shared.tap("flip", ["from": "editor"])
                            CrateUI.shared.flipHint = false
                            state.onFlip?()
                        } label: {
                            Text("FLIP").font(Theme.inter(10, 600)).tracking(0.9)
                                .foregroundStyle(Theme.chipText)
                                .padding(.horizontal, 12).frame(minWidth: 56).frame(height: 26)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.chipStroke, lineWidth: 0.6))
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(HitPressStyle())
                        .padding(.vertical, -9)
                        .accessibilityIdentifier("editor-flip")
                    }
                    if view != nil {
                        Button { view = nil } label: {
                            Text("FIT").font(Theme.inter(10, 600)).tracking(0.9).foregroundStyle(Theme.chipText)
                                .padding(.horizontal, 12).frame(minWidth: 56).frame(height: 26)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.chipStroke, lineWidth: 0.6))
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(HitPressStyle())
                        .padding(.vertical, -9)
                        .accessibilityIdentifier("editor-fit")
                    }
                }
                GeometryReader { geo in
                    let inset: CGFloat = 9   // the edge grips stay whole at the very start / end of the sound
                    let w = geo.size.width - inset * 2
                    let x = { (t: Double) -> CGFloat in
                        inset + CGFloat((t - win.lowerBound) / max(0.001, win.upperBound - win.lowerBound)) * w
                    }
                    let t = { (px: CGFloat) -> Double in
                        win.lowerBound + Double((px - inset) / max(1, w)) * (win.upperBound - win.lowerBound)
                    }
                    ZStack(alignment: .topLeading) {
                        FileWaveCanvas(url: s.fileURL, window: win, duration: dur, start: start, end: end,
                                       tint: Theme.bank(pad.bank), marks: slice ? sliceMarks(pad) : [])
                            .padding(.horizontal, inset)
                        EnvelopeLine(params: s.params, seconds: (end - start) / s.params.stretch,
                                     x0: x(start), x1: x(end), color: Theme.bank(pad.bank))
                            .allowsHitTesting(false)
                        handle(at: x(start), height: geo.size.height, color: Theme.bank(pad.bank))
                        handle(at: x(end), height: geo.size.height, color: Theme.bank(pad.bank))
                    }
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                guard pinch == nil, Date().timeIntervalSince(pinchEndedAt) > 0.25 else { return }
                                if dragging == nil {
                                    let ds = abs(g.startLocation.x - x(start)), de = abs(g.startLocation.x - x(end))
                                    if min(ds, de) < 44 {
                                        dragging = ds <= de ? .start : .end
                                    } else if abs(g.translation.width) > 6 {
                                        dragging = .pan
                                        panFrom = win
                                    } else {
                                        return
                                    }
                                }
                                switch dragging {
                                case .start?:
                                    ui.editPreviewStart = min(min(win.upperBound, max(win.lowerBound, t(g.location.x))), end - 0.02)
                                case .end?:
                                    ui.editPreviewEnd = max(min(win.upperBound, max(win.lowerBound, t(g.location.x))), start + 0.02)
                                case .pan?:
                                    guard let from = panFrom else { return }
                                    let span = from.upperBound - from.lowerBound
                                    view = Self.clamp(from.lowerBound - Double(g.translation.width / max(1, w)) * span,
                                                      span: span, duration: dur)
                                case nil:
                                    break
                                }
                            }
                            .onEnded { g in
                                let mode = dragging
                                dragging = nil
                                panFrom = nil
                                guard pinch == nil, Date().timeIntervalSince(pinchEndedAt) > 0.25 else {
                                    ui.editPreviewStart = nil
                                    ui.editPreviewEnd = nil
                                    return
                                }
                                switch mode {
                                case .start?, .end?: commit(pad)
                                case .pan?: break
                                case nil: if abs(g.translation.width) < 6 { tap(at: t(g.location.x), pad: pad) }
                                }
                            }
                    )
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { m in
                                if pinch == nil {
                                    dragging = nil
                                    ui.editPreviewStart = nil
                                    ui.editPreviewEnd = nil
                                    let frac = min(1, max(0, Double((m.startLocation.x - inset) / max(1, w))))
                                    let span = win.upperBound - win.lowerBound
                                    pinch = (win.lowerBound + frac * span, frac, span)
                                }
                                guard let p = pinch else { return }
                                let span = min(dur, max(0.02, p.span / Double(max(0.05, m.magnification))))
                                view = Self.clamp(p.anchor - p.frac * span, span: span, duration: dur)
                            }
                            .onEnded { _ in
                                pinch = nil
                                pinchEndedAt = Date()
                            }
                    )
                }
                // The waveform / trim strip never collapses: the controls row is fixed, the strip keeps ≥ 64 pt.
                .frame(minHeight: 64)
                .layoutPriority(1)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("pad-editor")
                .accessibilityLabel("Pad editor")
                .accessibilityValue(String(format: "start %.2f seconds, end %.2f seconds", start, end))
                PadControlsRow(state: state)
                    .frame(height: PadControlsRow.height(for: width))
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onChange(of: pad) { _, _ in view = nil }
        } else {
            Text("EMPTY PAD · TAP SAMPLE AND HOLD A PAD, OR ＋ A SONG")
                .fieldLabel().foregroundStyle(Theme.lidGrey1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// What the editor shows: a slice in context (it and about a slice either side), a one-shot or take whole.
    static func window(start: Double, end: Double, duration: Double, slice: Bool) -> ClosedRange<Double> {
        guard slice else { return 0...duration }
        let len = max(0.05, end - start)
        let lo = max(0, start - len * 1.2), hi = min(duration, end + len * 1.2)
        return lo...max(lo + 0.1, hi)
    }

    /// A `span`-long view starting near `lo`, kept inside the file.
    static func clamp(_ lo: Double, span: Double, duration: Double) -> ClosedRange<Double> {
        let s = min(span, duration)
        let l = min(max(0, lo), duration - s)
        return l...(l + s)
    }

    /// Tap inside the pad's sound plays it; tap a neighbouring slice of the same song to move to that slice.
    private func tap(at t: Double, pad: PadID) {
        if let s = state.sound(pad), t < s.start || t > (s.end ?? .infinity) {
            for i in 0..<16 {
                let p = PadID(pad.bank, i)
                if let x = state.sound(p), x.fileURL == s.fileURL, t >= x.start, t < (x.end ?? .infinity) {
                    state.selectedPad = p
                    state.hit(p)
                    return
                }
            }
        }
        state.hit(pad)
    }

    private func sliceMarks(_ pad: PadID) -> [Double] {
        guard let s = state.sound(pad) else { return [] }
        return (0..<16).compactMap { i in
            guard let x = state.sound(PadID(pad.bank, i)), x.fileURL == s.fileURL else { return nil }
            return x.start
        }
    }

    private func commit(_ pad: PadID) {
        let ui = CrateUI.shared
        let s = ui.editPreviewStart, e = ui.editPreviewEnd
        Task { @MainActor in
            await Orchestrator.current?.trimPad(pad, start: s, end: e)
            ui.editPreviewStart = nil
            ui.editPreviewEnd = nil
        }
    }

    private func handle(at x: CGFloat, height: CGFloat, color: Color) -> some View {
        ZStack {
            Rectangle().fill(color).frame(width: 3, height: height)
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 14, height: 30)
        }
        .frame(width: 16, height: height)
        .offset(x: x - 8)
        .allowsHitTesting(false)
    }
}

/// The source file's waveform across `window`; the kept region bright, the rest dim; slice lines for chops.
struct FileWaveCanvas: View {
    let url: URL
    let window: ClosedRange<Double>
    let duration: Double
    let start: Double
    let end: Double
    let tint: Color
    var marks: [Double] = []
    @State private var env: [Float] = []

    var body: some View {
        Canvas { g, size in
            let cy = size.height / 2
            g.fill(Path(CGRect(x: 0, y: cy - 0.25, width: size.width, height: 0.5)), with: .color(Theme.lidGrey3))
            let span = max(0.001, window.upperBound - window.lowerBound)
            func x(_ t: Double) -> CGFloat { CGFloat((t - window.lowerBound) / span) * size.width }
            g.fill(Path(CGRect(x: x(start), y: 0, width: max(1, x(end) - x(start)), height: size.height)),
                   with: .color(tint.opacity(0.12)))
            if !env.isEmpty {
                let cols = max(2, Int(size.width / 2.5))
                for c in 0..<cols {
                    let t = window.lowerBound + span * (Double(c) + 0.5) / Double(cols)
                    let i = min(env.count - 1, max(0, Int(t / max(0.001, duration) * Double(env.count))))
                    let a = CGFloat(min(1, max(0, env[i]))) * (size.height / 2 - 4)
                    let px = CGFloat(c) / CGFloat(cols) * size.width
                    let inside = t >= start && t <= end
                    g.fill(Path(CGRect(x: px, y: cy - max(0.5, a), width: 1.5, height: max(1, a * 2))),
                           with: .color(inside ? Theme.lidInk : Theme.lidInk.opacity(0.28)))
                }
            }
            for m in marks where m > window.lowerBound && m < window.upperBound {
                g.fill(Path(CGRect(x: x(m), y: 0, width: 1, height: size.height)), with: .color(Theme.lidGrey2))
            }
        }
        .task(id: url) { env = await FileWave.envelope(url) }
    }
}

/// Peak envelopes of whole source files (2048 points), computed off the main thread and cached.
enum FileWave {
    @MainActor private static var cache: [URL: [Float]] = [:]

    @MainActor static func envelope(_ url: URL) async -> [Float] {
        if let e = cache[url] { return e }
        let e = await Task.detached(priority: .userInitiated) { compute(url) }.value
        if !e.isEmpty { cache[url] = e }
        return e
    }

    private static func compute(_ url: URL, points: Int = 2048) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return [] }
        let fmt = file.processingFormat
        let per = max(1, Int(file.length) / points)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(per)) else { return [] }
        var out: [Float] = []
        out.reserveCapacity(points)
        while file.framePosition < file.length, out.count < points {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(per), file.length - file.framePosition))
            guard (try? file.read(into: buf, frameCount: n)) != nil, let ch = buf.floatChannelData else { break }
            var peak: Float = 0
            for c in 0..<Int(fmt.channelCount) {
                for f in 0..<Int(buf.frameLength) { peak = max(peak, abs(ch[c][f])) }
            }
            out.append(peak)
        }
        let top = max(0.05, out.max() ?? 1)
        return out.map { min(1, $0 / top) }
    }
}

// MARK: - ＋ (bring a song)

/// ＋ next to the prompt: pick a song (it becomes 16 chops on bank D) or a short sound (it lands on the selected pad).
struct ImportButton: View {
    let state: AppState
    /// Drawn size (the prompt field's height); the hit area is at least 44 pt.
    var size: CGFloat = 38
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            Image(systemName: "plus")
                .font(.system(size: size * 0.4, weight: .regular))
                .foregroundStyle(Theme.lidInk)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(0.07)))
                .overlay(Circle().strokeBorder(CrateUI.shared.flipHint ? Theme.lidGrey2 : Color.clear, lineWidth: 0.6))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(HitPressStyle())
        .padding(.horizontal, -max(0, (44 - size) / 2))
        .padding(.vertical, -max(0, (44 - size) / 2))
        .accessibilityIdentifier("import-button")
        .accessibilityLabel("Bring a song")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { @MainActor in await AudioImport.importPicked(url, state: state) }
        }
    }
}
