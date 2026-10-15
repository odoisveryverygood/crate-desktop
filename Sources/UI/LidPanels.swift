import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - SEQ: 16-step dot grid of the current bar

struct SeqRow {
    var label: String
    var color: Color
    var pads: [PadID]
}

enum SeqRows {
    /// Lanes that have hits anywhere in the pattern: bank A per lane, bank B merged into CHOP, banks C/D per pad.
    /// Each lane carries its bank's colour (tab + playhead).
    static func build(_ state: AppState, _ p: Pattern) -> [SeqRow] {
        func has(_ pad: PadID) -> Bool {
            !(p.lanes[pad]?.isEmpty ?? true) || !(p.notes[pad]?.isEmpty ?? true)
        }
        var rows: [SeqRow] = []
        for i in 0..<16 {
            let pad = PadID(.a, i)
            if has(pad) { rows.append(SeqRow(label: UIHelpers.bankANames[i], color: Theme.bank(.a), pads: [pad])) }
        }
        let chops = (0..<16).map { PadID(.b, $0) }.filter(has)
        if !chops.isEmpty { rows.append(SeqRow(label: "CHOP", color: Theme.bank(.b), pads: chops)) }
        for bank in [Bank.c, .d] {
            // Slices of one file (an imported song, a "sax line" layer) share one row named after the sound.
            var grouped: [URL: Int] = [:]
            for i in 0..<16 {
                let pad = PadID(bank, i)
                guard has(pad) else { continue }
                if let snd = state.sound(pad), [.chop, .loop].contains(snd.category) {
                    if let r = grouped[snd.fileURL] { rows[r].pads.append(pad); continue }
                    grouped[snd.fileURL] = rows.count
                    let word = snd.name.split(separator: " ").first.map { String($0).uppercased() } ?? "CHOP"
                    rows.append(SeqRow(label: word.count <= 5 ? word : "CHOP", color: Theme.bank(bank), pads: [pad]))
                    continue
                }
                rows.append(SeqRow(label: UIHelpers.laneLabel(state, pad), color: Theme.bank(bank), pads: [pad]))
            }
        }
        // The selected pad always has a lane (empty if it's not in the beat yet) so it can be programmed by tapping steps.
        let sel = state.selectedPad
        if state.sound(sel) != nil, !rows.contains(where: { $0.pads.contains(sel) }) {
            let label = sel.bank == .a ? UIHelpers.bankANames[sel.index]
                : sel.bank == .b ? "CHOP \(sel.number)" : UIHelpers.laneLabel(state, sel)
            let row = SeqRow(label: label, color: Theme.bank(sel.bank), pads: [sel])
            // keep bank order: after the last row of the same or an earlier bank
            let at = rows.lastIndex(where: { ($0.pads.first?.bank.rawValue ?? 0) <= sel.bank.rawValue }).map { $0 + 1 } ?? 0
            rows.insert(row, at: at)
        }
        return rows
    }

    static let placeholder = [
        SeqRow(label: "KICK", color: Theme.bank(.a), pads: []),
        SeqRow(label: "SNR", color: Theme.bank(.a), pads: []),
        SeqRow(label: "HAT", color: Theme.bank(.a), pads: []),
        SeqRow(label: "CHOP", color: Theme.bank(.b), pads: []),
        SeqRow(label: "BASS", color: Theme.bank(.c), pads: []),
    ]
}

/// 05 dot sequencer for the current bar: bank-colour lane tabs, white hits, tiny rest dots, hollow ghosts,
/// a step ruler (1 · 5 · 9 · 13 + the playing step) and the playhead split per lane in that lane's bank colour.
struct SeqGridView: View {
    let state: AppState
    /// Largest lane pitch (the mock's 25 pt; portrait allows a little more).
    var maxPitch: CGFloat = 25
    /// How far dots may grow with the pitch (1 = the mock's sizes; the big iPad lid allows more).
    var dotCap: CGFloat = 1

    /// Lane label column (the mock's X0).
    static let labelColumn: CGFloat = 54
    /// Extra gap between 4-step groups.
    static let groupGap: CGFloat = 10
    /// First lane centre below the top (the ruler sits above it).
    static let firstLane: CGFloat = 24
    static let bottomPad: CGFloat = 19

    static func fittedHeight(rows: Int, pitch: CGFloat) -> CGFloat {
        firstLane + CGFloat(max(rows, 1) - 1) * pitch + bottomPad
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
            let f = LiveFrame(state)
            let rows = SeqRows.build(state, f.pattern)
            GeometryReader { geo in
                Canvas { ctx, size in
                    // Empty: the placeholder lanes leave one lane's room under BASS for the hint.
                    draw(ctx, size: size, frame: f, rows: rows.isEmpty ? SeqRows.placeholder : rows,
                         slots: rows.isEmpty ? SeqRows.placeholder.count + 1 : nil)
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap in
                    handleTap(at: tap.location, size: geo.size, rows: rows)
                })
                // Swipe left / right = next / previous bar (the grid then shows and edits only that bar).
                .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { v in
                    let dx = v.translation.width, dy = v.translation.height
                    guard abs(dx) > 44, abs(dx) > abs(dy) * 1.4 else { return }
                    page(dx < 0 ? 1 : -1)
                })
                .overlay(alignment: .topLeading) { laneLabels(rows, size: geo.size) }
                .overlay(alignment: .topLeading) { barLabel(f) }
                .overlay(alignment: .topLeading) {
                    if rows.isEmpty {
                        // On the spare lane below the placeholder lanes, never over BASS.
                        let n = SeqRows.placeholder.count
                        let y = Self.firstLane + CGFloat(n) * pitch(geo.size, rows: n + 1)
                        Text("EMPTY PATTERN · DESCRIBE A BEAT BELOW")
                            .fieldLabel()
                            .foregroundStyle(Theme.lidGrey1)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(height: 10)
                            .padding(.leading, Self.labelColumn)
                            .offset(y: y - 5)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityHint("Tap a step to add or remove it. Tap a lane name to select and hear that sound; hold it to clear the lane.")
        .accessibilityIdentifier("seq-grid")
        .accessibilityLabel("Sequencer")
    }

    /// Lane pitch for `rows` lanes in `size` (the same spacing `draw` uses).
    private func pitch(_ size: CGSize, rows: Int) -> CGFloat {
        min(maxPitch, max(11, (size.height - Self.firstLane - 12) / CGFloat(max(rows - 1, 1))))
    }

    /// Lane names: tap = select that sound and hear it (the pad line then edits / swaps it); hold = clear the lane.
    private func laneLabels(_ rows: [SeqRow], size: CGSize) -> some View {
        let p = pitch(size, rows: rows.count)
        let w = Self.labelColumn - 4
        return ZStack(alignment: .topLeading) {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                Color.clear
                    .frame(width: w, height: max(14, p))
                    .contentShape(Rectangle())
                    .gesture(
                        LongPressGesture(minimumDuration: 0.5)
                            .onEnded { _ in
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                Orchestrator.current?.clearLane(row.pads, label: row.label)
                            }
                            .exclusively(before: TapGesture().onEnded { selectLane(row) })
                    )
                    .position(x: w / 2, y: Self.firstLane + CGFloat(r) * p)
                    .accessibilityElement()
                    .accessibilityLabel(row.label)
                    .accessibilityIdentifier("lane-\(row.label.lowercased().replacingOccurrences(of: " ", with: "-"))")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { selectLane(row) }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func selectLane(_ row: SeqRow) {
        let pad = row.pads.contains(state.selectedPad) ? state.selectedPad
            : row.pads.first { !(state.engine.pattern.lanes[$0]?.isEmpty ?? true) } ?? row.pads.first
        guard let pad else { return }
        CrateUI.shared.selectBank(pad.bank, state)
        state.selectedPad = pad
        state.hit(pad)
        DebugLog.event("lane_select", ["lane": row.label, "pad": "\(pad.bank.letter)\(pad.number)"])
    }

    /// Swipe / ‹ ›: show (and edit) the next or previous bar, wrapping. From ALL it starts at the bar playing now.
    private func page(_ dir: Int) {
        let f = LiveFrame(state)
        guard f.bars > 1 else { return }
        let cur = Self.shownBar(f)
        let next = ((cur + dir) % f.bars + f.bars) % f.bars
        UISelectionFeedbackGenerator().selectionChanged()
        CrateUI.shared.showBar(next, state)
        Analytics.shared.tap("bar_page", ["dir": dir, "bar": next + 1])
    }

    /// "‹ 2/4 ›" in the ruler row (only for loops longer than a bar): grey while it follows the playhead and step
    /// taps edit every bar; white with ✕ once a bar is picked (swipe or ‹ ›), and step taps edit only that bar.
    @ViewBuilder
    private func barLabel(_ f: LiveFrame) -> some View {
        if f.bars > 1 {
            let pinned = CrateUI.shared.viewBar.map { $0 < f.bars } ?? false
            let ink = pinned ? Theme.lidInk : Theme.lidGrey1
            HStack(spacing: 0) {
                Button { page(-1) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 8, weight: .bold)).foregroundStyle(ink)
                        .frame(width: 18, height: 30).contentShape(Rectangle())
                }
                .accessibilityIdentifier("bar-prev")
                Text("\(Self.shownBar(f) + 1)/\(f.bars)")
                    .font(Theme.inter(7, 700)).monospacedDigit().foregroundStyle(ink)
                    .fixedSize()
                    .accessibilityLabel("Bar \(Self.shownBar(f) + 1) of \(f.bars)")
                Button { page(1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(ink)
                        .frame(width: 18, height: 30).contentShape(Rectangle())
                }
                .accessibilityIdentifier("bar-next")
                if pinned {
                    Button { CrateUI.shared.showBar(nil, state) } label: {
                        Image(systemName: "xmark").font(.system(size: 6.5, weight: .bold)).foregroundStyle(Theme.lidGrey1)
                            .frame(width: 16, height: 30).contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("bar-all")
                    .accessibilityLabel("All bars")
                }
            }
            .frame(maxWidth: Self.labelColumn - 4, alignment: .leading)
            .buttonStyle(HitPressStyle())
            .offset(x: -6, y: Self.firstLane - 20.5 - 15)
        }
    }

    /// The bar on screen: the picked bar (swipe / ‹ ›), else (ALL) the playing bar.
    static func shownBar(_ f: LiveFrame) -> Int {
        if let v = CrateUI.shared.viewBar, v < f.bars { return v }
        return f.bar
    }

    /// Tap a dot = toggle that step: in every bar of the loop (ALL), or only in the bar the pager picked.
    /// Lane names are handled by `laneLabels`.
    private func handleTap(at p: CGPoint, size: CGSize, rows: [SeqRow]) {
        guard !rows.isEmpty, let orch = Orchestrator.current else { return }
        let top = Self.firstLane
        let pitch = pitch(size, rows: rows.count)
        let r = Int(((p.y - top) / pitch).rounded())
        guard r >= 0, r < rows.count, abs(p.y - (top + CGFloat(r) * pitch)) <= pitch / 2 + 2 else { return }
        let row = rows[r]
        guard p.x >= Self.labelColumn - 4 else { return }
        let x0 = Self.labelColumn
        let colW = (size.width - x0 - 3 * Self.groupGap) / 16
        func cx(_ i: Int) -> CGFloat { x0 + CGFloat(i) * colW + CGFloat(i / 4) * Self.groupGap + colW / 2 }
        guard let col = (0..<16).min(by: { abs(cx($0) - p.x) < abs(cx($1) - p.x) }), abs(cx(col) - p.x) <= colW else { return }
        let f = LiveFrame(state)
        if let v = CrateUI.shared.viewBar, v < f.bars {
            orch.toggleStep(row.pads, col: col, onlyBar: v, label: row.label)
        } else {
            orch.toggleStep(row.pads, col: col, bar: f.bar, label: row.label)
        }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, frame f: LiveFrame, rows: [SeqRow], slots: Int? = nil) {
        let n = slots ?? rows.count
        let top = Self.firstLane
        let pitch = min(maxPitch, max(11, (size.height - top - 12) / CGFloat(max(n - 1, 1))))
        let x0 = Self.labelColumn
        let colW = (size.width - x0 - 3 * Self.groupGap) / 16
        func cx(_ i: Int) -> CGFloat { x0 + CGFloat(i) * colW + CGFloat(i / 4) * Self.groupGap + colW / 2 }
        let k = min(dotCap, max(0.7, pitch / 25))
        let dHit = 9 * k, dNow = 10 * k, dGhost = 6 * k
        let segH = min(19, pitch - 3)
        let shown = Self.shownBar(f)
        // the playhead only shows while the playing bar is the bar on screen
        let playing = f.playing && f.bar == shown
        let now = f.stepInBar
        let barStart = shown * 16

        // step ruler: 1 · 5 · 9 · 13 in grey, the playing step in white
        let rulerY = top - 20.5
        for i in [0, 4, 8, 12] where !(playing && i == now) {
            ctx.draw(Text("\(i + 1)").font(Theme.inter(7, 500)).monospacedDigit().foregroundStyle(Theme.lidGrey2),
                     at: CGPoint(x: cx(i), y: rulerY), anchor: .center)
        }
        if playing {
            ctx.draw(Text("\(now + 1)").font(Theme.inter(7, 500)).monospacedDigit().foregroundStyle(Theme.lidInk),
                     at: CGPoint(x: cx(now), y: rulerY), anchor: .center)
        }

        for (r, row) in rows.enumerated() {
            let cy = top + CGFloat(r) * pitch

            // velocity (and note length) per step of this bar
            var cells = [Int: (vel: Int, len: Double)]()
            for pad in row.pads {
                for h in f.pattern.lanes[pad] ?? [] {
                    let s = h.step - barStart
                    if s >= 0 && s < 16 { cells[s] = (max(cells[s]?.vel ?? 0, h.velocity), max(1, cells[s]?.len ?? 1)) }
                }
                for note in f.pattern.notes[pad] ?? [] {
                    let s = note.step - barStart
                    if s >= 0 && s < 16 { cells[s] = (max(cells[s]?.vel ?? 0, note.velocity), max(1, note.length)) }
                }
            }
            let hot = playing && cells[now] != nil

            // the pad you're playing: a soft band + bold label, flashing brighter on each hit
            let selected = row.pads.contains(state.selectedPad)
            let hitAge = row.pads.contains(where: { $0 == state.lastHitPad }) ? Date().timeIntervalSince(state.lastHitTime) : 9
            let flash = max(0, 1 - hitAge / 0.35)
            if selected || flash > 0 {
                let band = CGRect(x: -4, y: cy - min(11, pitch / 2 - 1), width: size.width + 4, height: min(22, pitch - 2))
                ctx.fill(Path(roundedRect: band, cornerRadius: 3),
                         with: .color(row.color.opacity(0.10 + 0.22 * flash)))
            }

            // bank tab + lane label
            let tabW: CGFloat = selected ? 3 : 2
            ctx.fill(Path(CGRect(x: 0, y: cy - 4.5, width: tabW, height: 9)), with: .color(row.color))
            ctx.draw(Text(row.label).font(Theme.inter(7.5, selected || flash > 0 ? 700 : 500)).tracking(0.75)
                        .foregroundStyle(hot || selected || flash > 0 ? Theme.lidInk : Theme.lidGrey1),
                     at: CGPoint(x: 9, y: cy), anchor: .leading)

            // held notes: a hairline to the note's end
            for (s, c) in cells where c.len > 1.5 {
                let end = min(15, s + Int(c.len.rounded(.up)) - 1)
                if end > s {
                    ctx.fill(Path(CGRect(x: cx(s), y: cy - 0.5, width: cx(end) - cx(s), height: 1)),
                             with: .color(Theme.lidRest))
                }
            }

            // this lane's playhead, in its bank colour
            if playing {
                ctx.fill(Path(CGRect(x: cx(now) - 1, y: cy - segH / 2, width: 2, height: segH)), with: .color(row.color))
            }

            for s in 0..<16 {
                let x = cx(s)
                guard let c = cells[s] else {
                    if !(playing && s == now) {
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: cy - 1, width: 2, height: 2)), with: .color(Theme.lidRest))
                    }
                    continue
                }
                let ghost = c.vel < 60
                if playing && s == now {
                    let d = ghost ? dGhost + 2 : dNow
                    ctx.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: cy - d / 2, width: d, height: d)), with: .color(row.color))
                } else if ghost {
                    let d = dGhost - 1
                    ctx.stroke(Path(ellipseIn: CGRect(x: x - d / 2, y: cy - d / 2, width: d, height: d)),
                               with: .color(Theme.lidGhost), lineWidth: 1)
                } else {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - dHit / 2, y: cy - dHit / 2, width: dHit, height: dHit)),
                             with: .color(Theme.lidInk))
                }
            }
        }
    }
}

// MARK: - CHOP: bank-B source waveform with 16 numbered slice markers

struct ChopWaveView: View {
    let state: AppState
    /// Boundary being dragged (between slice i-1 and i) and its live x.
    @State private var drag: (i: Int, x: CGFloat)?

    /// The bank holding chops: the selected bank if it has any (B, or D for a dropped song), else B, else D.
    private var bank: Bank {
        func has(_ b: Bank) -> Bool { (0..<16).contains { state.sound(PadID(b, $0)) != nil } }
        if [.b, .d].contains(state.bank), has(state.bank) { return state.bank }
        return has(.b) || !has(.d) ? .b : .d
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let f = LiveFrame(state)
            let bank = self.bank
            // Slices in time order (FIND CHOPS puts the best chops on pads 1–8, so pad order isn't time order).
            let order = Self.timeOrder((0..<16).map { state.sound(PadID(bank, $0)) })
            let sounds = order.map { state.sound(PadID(bank, $0)) }
            let loaded = sounds.contains { $0 != nil }
            let current = currentSlice(f, bank: bank, now: ctx.date)
            GeometryReader { geo in
                Canvas { g, size in
                    draw(g, size: size, bank: bank, sounds: sounds, order: order, current: current, loaded: loaded)
                }
                .contentShape(Rectangle())
                .gesture(loaded ? editGesture(size: geo.size, bank: bank, sounds: sounds, order: order) : nil)
            }
            .overlay {
                if !loaded {
                    Text("NO SAMPLE · PRESS ✦ DIG OR DROP A SONG ON THE PADS")
                        .fieldLabel()
                        .foregroundStyle(Theme.lidGrey1)
                        .padding(6)
                        .background(Theme.oled)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("chop-wave")
        .accessibilityLabel("Chop waveform")
        .accessibilityHint("Drag a slice line to move it. Tap a slice to play it.")
    }

    private func currentSlice(_ f: LiveFrame, bank: Bank, now: Date) -> Int? {
        if let p = state.lastHitPad, p.bank == bank, now.timeIntervalSince(state.lastHitTime) < 1.2 { return p.index }
        if bank == .b, let c = f.currentChop() { return c }
        return state.selectedPad.bank == bank ? state.selectedPad.index : nil
    }

    /// Slice widths proportional to duration; returns each slice's x and width.
    private func layout(_ width: CGFloat, _ sounds: [PadSound?]) -> [(x: CGFloat, w: CGFloat)] {
        var durs = sounds.map { s -> Double in
            guard let s, let e = s.end, e > s.start else { return 1 }
            return e - s.start
        }
        if durs.reduce(0, +) <= 0 { durs = Array(repeating: 1, count: 16) }
        let sum = durs.reduce(0, +)
        var x: CGFloat = 0
        return durs.map { d in
            let w = width * CGFloat(d / sum)
            defer { x += w }
            return (x, w)
        }
    }

    /// Pad indices sorted by where their sound starts (pads of other files and empty pads last, in pad order).
    static func timeOrder(_ sounds: [PadSound?]) -> [Int] {
        let file = sounds.compactMap { $0 }.first?.fileURL
        return sounds.indices.sorted { a, b in
            let x = sounds[a].flatMap { $0.fileURL == file ? $0.start : nil }
            let y = sounds[b].flatMap { $0.fileURL == file ? $0.start : nil }
            switch (x, y) {
            case let (x?, y?): return x != y ? x < y : a < b
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a < b
            }
        }
    }

    /// Drag near a slice line = move that line (the end of slice i-1 / start of slice i). Tap = play that slice.
    private func editGesture(size: CGSize, bank: Bank, sounds: [PadSound?], order: [Int]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let cols = layout(size.width, sounds)
                if drag == nil {
                    guard abs(g.translation.width) > 3 || abs(g.translation.height) > 3 else { return }
                    // nearest inner boundary to where the finger went down
                    let hit = (1..<16).min { abs(cols[$0].x - g.startLocation.x) < abs(cols[$1].x - g.startLocation.x) }
                    guard let i = hit, abs(cols[i].x - g.startLocation.x) < 16 else { return }
                    drag = (i, cols[i].x)
                }
                if let d = drag {
                    let lo = cols[d.i - 1].x + 4, hi = cols[d.i].x + cols[d.i].w - 4
                    drag = (d.i, min(hi, max(lo, g.location.x)))
                }
            }
            .onEnded { g in
                let cols = layout(size.width, sounds)
                if let d = drag {
                    drag = nil
                    // x → seconds across the two neighbouring slices
                    guard let a = sounds[d.i - 1], let b = sounds[d.i] else { return }
                    let bEnd = b.end ?? (b.start + (b.start - a.start))
                    let x0 = cols[d.i - 1].x, span = cols[d.i - 1].w + cols[d.i].w
                    guard span > 0, bEnd > a.start else { return }
                    let t = a.start + Double((d.x - x0) / span) * (bEnd - a.start)
                    Orchestrator.current?.moveChopBoundary(bank: bank, left: order[d.i - 1], right: order[d.i], to: t)
                } else if abs(g.translation.width) < 4, abs(g.translation.height) < 4,
                          let i = cols.firstIndex(where: { g.location.x >= $0.x && g.location.x < $0.x + $0.w }),
                          sounds[i] != nil {
                    let pad = PadID(bank, order[i])
                    state.selectedPad = pad
                    state.hit(pad)
                }
            }
    }

    private func draw(_ g: GraphicsContext, size: CGSize, bank: Bank, sounds: [PadSound?], order: [Int], current: Int?, loaded: Bool) {
        let top: CGFloat = 16
        let h = size.height - top
        let cy = top + h / 2
        let tint = Theme.bank(bank == .d ? .b : bank)
        g.fill(Path(CGRect(x: 0, y: cy - 0.25, width: size.width, height: 0.5)), with: .color(Theme.lidGrey3))
        let cols = layout(size.width, sounds)
        for i in 0..<16 {
            let (x, w) = cols[i]
            let isCur = current == order[i]
            if isCur {
                g.fill(Path(CGRect(x: x, y: top, width: w, height: h)), with: .color(tint.opacity(0.12)))
            }
            // marker + number (the playing slice gets the bank colour, like its lane playhead)
            let dragging = drag?.i == i
            g.fill(Path(CGRect(x: x, y: top - 2, width: isCur ? 2 : 1, height: h + 2)),
                   with: .color((isCur ? tint : Theme.lidGrey3).opacity(dragging ? 0.25 : 1)))
            g.draw(Text("\(order[i] + 1)").font(Theme.inter(7, 500)).monospacedDigit()
                        .foregroundStyle(isCur ? Theme.lidInk : Theme.lidGrey2),
                   at: CGPoint(x: x + 4, y: 6), anchor: .leading)
            if loaded {
                let pts = max(4, Int(w / 3))
                let wave = WaveCache.shared.wave(state, PadID(bank, order[i]), points: pts)
                if !wave.isEmpty {
                    var path = Path()
                    for (j, a) in wave.enumerated() {
                        let px = x + (CGFloat(j) + 0.5) / CGFloat(wave.count) * w
                        let amp = CGFloat(min(1, max(0, a))) * (h / 2 - 6)
                        path.move(to: CGPoint(x: px, y: cy - max(0.5, amp)))
                        path.addLine(to: CGPoint(x: px, y: cy + max(0.5, amp)))
                    }
                    g.stroke(path, with: .color(isCur ? Theme.lidInk : Theme.lidInk.opacity(0.55)), lineWidth: 1.5)
                }
            }
        }
        // live drag handle
        if let d = drag {
            g.fill(Path(CGRect(x: d.x - 1, y: top - 6, width: 2, height: h + 6)), with: .color(Theme.live))
            g.fill(Path(ellipseIn: CGRect(x: d.x - 4, y: top - 10, width: 8, height: 8)), with: .color(Theme.live))
        }
    }
}

// MARK: - KEYS: waveform of the selected pad, oscillating faster for higher notes

struct KeysWaveView: View {
    let state: AppState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let pad = state.selectedPad
            let env = WaveCache.shared.wave(state, pad, points: 160)
            let semi = Double(CrateUI.shared.lastSemi ?? 0)
            let hot = ctx.date.timeIntervalSince(state.lastHitTime) < 0.15 && state.lastHitPad == pad
            Canvas { g, size in
                let cy = size.height / 2
                g.fill(Path(CGRect(x: 0, y: cy - 0.25, width: size.width, height: 0.5)), with: .color(Theme.lidGrey3))
                guard !env.isEmpty else { return }
                let cycles = 16 * pow(2, semi / 12)
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    let t = Double(x / size.width)
                    let fi = t * Double(env.count - 1)
                    let i0 = Int(fi), i1 = min(env.count - 1, i0 + 1)
                    let e = Double(env[i0]) + (Double(env[i1]) - Double(env[i0])) * (fi - Double(i0))
                    let y = cy - CGFloat(sin(t * cycles * 2 * .pi) * min(1, e)) * (size.height / 2 - 8)
                    if x == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    x += 1.5
                }
                g.stroke(path, with: .color(hot ? Theme.bank(pad.bank) : Theme.lidInk), lineWidth: 1.2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("keys-wave")
        .accessibilityLabel("Waveform")
    }
}

// MARK: - AI log

/// The AI log panel (SAMPLE / PAD FX / 16 LVL, portrait SEQ): tint tab, JB tag, Inter text, JB timing.
struct AILogView: View {
    let state: AppState
    var maxLines = 12
    var size: CGFloat = 10.5

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if state.log.isEmpty {
                Text("AI LOG · EMPTY")
                    .fieldLabel()
                    .foregroundStyle(Theme.lidGrey2)
            }
            ForEach(state.log.suffix(maxLines)) { line in
                HStack(alignment: .center, spacing: 0) {
                    Rectangle().fill(tint(line.tint)).frame(width: 2, height: 9)
                        .padding(.trailing, 7)
                    Text(Self.displayTag(line.tag))
                        .font(Theme.mono(7.5))
                        .tracking(0.3)
                        .foregroundStyle(Theme.lidTimingKey)
                        .frame(width: 44, alignment: .leading)
                        .lineLimit(1)
                    Text(line.text)
                        .font(Theme.inter(size))
                        .foregroundStyle(line.tint == .red ? Theme.red : Theme.lidInk)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let ms = line.ms {
                        Text(UIHelpers.msText(ms))
                            .font(Theme.mono(7.5))
                            .foregroundStyle(Theme.lidGrey1)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.leading, 8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai-log")
    }

    /// Internal tags → what the user reads (no vendor names).
    static func displayTag(_ tag: String) -> String {
        switch tag.uppercased() {
        case "JEV", "KW": return "PLAN"
        case "GPT": return "AI"
        case "ERR": return "NOTE"
        case let t: return t
        }
    }

    private func tint(_ t: Tint) -> Color {
        switch t {
        case .orange: return Theme.bank(.a)
        case .blue: return Theme.bank(.b)
        case .ochre: return Theme.bank(.c)
        case .grey: return Theme.bank(.d)
        case .red: return Theme.red
        }
    }
}

// MARK: - PUNCH strip (hinge FX / PAD FX), shown in the result line's slot whenever punch > 0

struct PunchStrip: View {
    let punch: Double
    /// Selected PAD FX (nil = the default PUNCH chain, which shows its LPF / VERB readout).
    var fx: FXType? = nil

    var body: some View {
        let p = min(1, max(0, punch))
        let cutoff = 20000 * pow(180.0 / 20000, pow(p, 0.85))
        let cells = 24
        let lit = Int((p * Double(cells)).rounded())
        HStack(spacing: 10) {
            Text(fx?.label ?? (p > 0.92 ? "BREAKDOWN" : "PUNCH"))
                .fieldLabel(7.5)
                .foregroundStyle(Theme.lidInk)
                .fixedSize()
            HStack(spacing: 2) {
                ForEach(0..<cells, id: \.self) { i in
                    Rectangle()
                        .fill(i < lit ? Theme.live : Theme.lidGrey3)
                        .frame(width: 4, height: 9)
                }
            }
            Text("\(Int(p * 100))%")
                .font(Theme.inter(13))
                .monospacedDigit()
                .foregroundStyle(Theme.lidInk)
                .fixedSize()
            Text(fx.map { $0.hint } ?? "LPF \(cutoff >= 1000 ? String(format: "%.1fk", cutoff / 1000) : "\(Int(cutoff))") · VERB \(Int(38 * p))")
                .font(Theme.mono(7.5))
                .foregroundStyle(Theme.lidGrey1)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("punch-strip")
    }
}
