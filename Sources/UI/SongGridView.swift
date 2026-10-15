import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// SONG: the bank × section grid (FL Studio's playlist, as cells). Columns are sections (header: name + bars = a
/// menu, ▶ = play from there); rows are the banks that have something to arrange, in bank colours; a cell says which
/// variation that bank plays in that section. Tap a cell = off → 1 → 2 → … → off. The row label is a menu (new /
/// edit variation, clear row); the trailing ＋ adds a section; ✦ ARRANGE (top-left corner) builds the whole song.
/// The playing section's column lights up. Shown in the lid's main area when the bar pager's SONG tab is on.
struct SongGridView: View {
    let state: AppState

    static let labelWidth: CGFloat = 62
    static let plusWidth: CGFloat = 36
    static let headerHeight: CGFloat = 30
    static let minRow: CGFloat = 26

    var body: some View {
        let song = state.song
        GeometryReader { geo in
            if song.sections.isEmpty {
                emptyHint(hasBeat: !song.rows.isEmpty || hasBeat)
                    .frame(width: geo.size.width, height: geo.size.height)
            } else {
                grid(song, size: geo.size)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("song-grid")
    }

    private var hasBeat: Bool {
        let p = state.engine.pattern
        return p.lanes.values.contains { !$0.isEmpty } || p.notes.values.contains { !$0.isEmpty }
    }

    // MARK: Empty

    private func emptyHint(hasBeat: Bool) -> some View {
        VStack(spacing: 12) {
            Text(hasBeat ? "✦ ARRANGE TURNS THIS BEAT INTO A FULL SONG" : "DIG A BEAT FIRST · THEN ✦ ARRANGE MAKES IT A SONG")
                .fieldLabel(8.5)
                .foregroundStyle(Theme.lidGrey1)
                .multilineTextAlignment(.center)
            if hasBeat {
                arrangeButton(wide: true)
            }
        }
        .padding(.horizontal, 12)
    }

    private func arrangeButton(wide: Bool) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Orchestrator.current?.arrangeSong(via: "button")
        } label: {
            Text("✦ ARRANGE")
                .font(Theme.inter(wide ? 11 : 8.5, 700)).tracking(wide ? 1.2 : 0.6)
                .foregroundStyle(Color.black)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, wide ? 22 : 4)
                .frame(maxWidth: wide ? nil : .infinity)
                .frame(height: wide ? 40 : 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.lidInk))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(HitPressStyle())
        .accessibilityIdentifier("song-arrange")
        .accessibilityLabel("Arrange: make a full song from this beat")
    }

    // MARK: Grid

    private func grid(_ song: SongArrangement, size: CGSize) -> some View {
        let rows = song.rows
        // A big lid (iPad) lets cells grow a little so the grid isn't a small island in the corner.
        let rowCap: CGFloat = size.height > 400 ? 56 : 44
        let colCap: CGFloat = size.width > 800 ? 104 : 66
        let rowH = max(Self.minRow, min(rowCap, (size.height - Self.headerHeight) / CGFloat(max(1, rows.count))))
        let free = size.width - Self.labelWidth - Self.plusWidth
        let colW = max(44, min(colCap, free / CGFloat(max(1, song.sections.count))))
        // Rows never shrink below a finger: a lid too short for every row scrolls instead (never clips a row).
        return ScrollView(.vertical, showsIndicators: false) {
            gridBody(song, rows: rows, rowH: rowH, colW: colW)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
    }

    private func gridBody(_ song: SongArrangement, rows: [Bank], rowH: CGFloat, colW: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                arrangeButton(wide: false)
                    .frame(height: Self.headerHeight)
                    .padding(.trailing, 6)
                ForEach(rows, id: \.self) { b in
                    rowLabel(b, song: song).frame(height: rowH)
                }
            }
            .frame(width: Self.labelWidth, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(song.sections.enumerated()), id: \.element.id) { i, sec in
                        column(i, sec, rows: rows, song: song, colW: colW, rowH: rowH)
                    }
                    addColumn(rowH: rowH, rows: rows.count)
                }
                .background(alignment: .topLeading) {
                    SongPlayhead(state: state, colW: colW, height: Self.headerHeight + rowH * CGFloat(rows.count))
                }
            }
        }
    }

    private func column(_ i: Int, _ sec: SongSection, rows: [Bank], song: SongArrangement, colW: CGFloat, rowH: CGFloat) -> some View {
        VStack(spacing: 0) {
            header(i, sec)
                .frame(height: Self.headerHeight)
            ForEach(rows, id: \.self) { b in
                cell(i, b, v: sec.part(b), song: song, rowH: rowH)
                    .frame(height: rowH)
            }
        }
        .frame(width: colW)
    }

    /// Section header: the name and its length in small grey; tap = one menu (play from here, length, duplicate,
    /// rename, delete). No per-section ▶ row or chevrons: the grid stays quiet.
    private func header(_ i: Int, _ sec: SongSection) -> some View {
        Menu {
            Button { Orchestrator.current?.playSection(i) } label: { Label("Play from here", systemImage: "play.fill") }
            Section("\(sec.name) · \(sec.bars) BARS") {
                ForEach([4, 8], id: \.self) { n in
                    Button { Orchestrator.current?.setSectionBars(i, bars: n) } label: {
                        if sec.bars == n { Label("\(n) bars", systemImage: "checkmark") } else { Text("\(n) bars") }
                    }
                }
            }
            Button { Orchestrator.current?.duplicateSection(i) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Menu("Rename") {
                ForEach(SongSection.names, id: \.self) { n in
                    Button { Orchestrator.current?.renameSection(i, to: n) } label: {
                        if sec.name == n { Label(n, systemImage: "checkmark") } else { Text(n) }
                    }
                }
            }
            Button(role: .destructive) { Orchestrator.current?.deleteSection(i) } label: { Label("Delete", systemImage: "trash") }
        } label: {
            VStack(spacing: 2) {
                Text(sec.short)
                    .font(Theme.inter(8.5, 700)).tracking(0.5)
                    .foregroundStyle(Theme.lidInk)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("\(sec.bars)").font(Theme.inter(7.5, 600)).monospacedDigit()
                    .foregroundStyle(Theme.lidGrey2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("song-section-\(i + 1)")
        .accessibilityLabel("\(sec.name), \(sec.bars) bars")
    }

    private func cell(_ i: Int, _ b: Bank, v: Int, song: SongArrangement, rowH: CGFloat) -> some View {
        let side = max(20, min(34, rowH - 8))
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Orchestrator.current?.cycleCell(section: i, bank: b)
        } label: {
            ZStack {
                if v > 0 {
                    RoundedRectangle(cornerRadius: 5).fill(Theme.bank(b))
                    Text("\(v)").font(Theme.inter(12, 700)).monospacedDigit().foregroundStyle(Color.black)
                } else {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.lidGrey3, lineWidth: 1)
                    Circle().fill(Theme.lidGrey2).frame(width: 3, height: 3)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(HitPressStyle())
        .accessibilityIdentifier("song-cell-\(i + 1)-\(b.letter.lowercased())")
        .accessibilityLabel("\(Orchestrator.current?.rowName(b) ?? b.letter) in section \(i + 1)")
        .accessibilityValue(v > 0 ? "variation \(v)" : "off")
    }

    private func rowLabel(_ b: Bank, song: SongArrangement) -> some View {
        let name = Orchestrator.current?.rowName(b) ?? Theme.bankName(b)
        let edit = song.edit(b)
        return Menu {
            Button { Orchestrator.current?.newVariation(b) } label: {
                Label("New variation (copy of \(edit))", systemImage: "plus")
            }
            ForEach(1...max(1, song.count(b)), id: \.self) { n in
                Button { Orchestrator.current?.editVariation(b, n) } label: {
                    if n == edit { Label("Edit variation \(n)", systemImage: "pencil") } else { Text("Edit variation \(n)") }
                }
            }
            Button(role: .destructive) { Orchestrator.current?.clearRow(b) } label: { Label("Clear row", systemImage: "xmark") }
        } label: {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.bank(b)).frame(width: 3, height: 16)
                Text(name)
                    .font(Theme.inter(8, 700)).tracking(0.4)
                    .foregroundStyle(Theme.lidInk)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Image(systemName: "chevron.down")
                    .font(.system(size: 5.5, weight: .bold))
                    .foregroundStyle(Theme.lidGrey1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("song-row-\(b.letter.lowercased())")
        .accessibilityLabel("\(name) row")
    }

    private func addColumn(rowH: CGFloat, rows: Int) -> some View {
        Button {
            Orchestrator.current?.addSection()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.lidGrey1)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.chipStroke, lineWidth: 0.6))
                .frame(width: Self.plusWidth, height: Self.headerHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(HitPressStyle())
        .accessibilityIdentifier("song-add")
        .accessibilityLabel("Add a section")
    }
}

/// The playing section's column: a lit background and a progress line under its header (SONG mode, playing).
private struct SongPlayhead: View {
    let state: AppState
    let colW: CGFloat
    let height: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let f = LiveFrame(state)
            let song = state.song
            // A cue in flight (▶, ARRANGE, a length change): the timeline still counts the old bar until the next bar
            // line, so the column it lands on lights up (progress 0) instead of a wrong one.
            let cued = state.engine.cuedBar()
            if song.songMode, f.playing, f.bars == song.totalBars, let i = song.section(atBar: cued ?? f.bar) {
                let start = Double(song.starts[i] * 16)
                let len = Double(max(1, song.sections[i].bars) * 16)
                let progress = cued != nil ? 0 : min(1, max(0, (f.local - start) / len))
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.lidGrey3.opacity(0.75))
                        .frame(width: colW - 2, height: height)
                    Rectangle().fill(Theme.live)
                        .frame(width: max(2, (colW - 10) * progress), height: 2)
                        .offset(x: 4, y: SongGridView.headerHeight - 2)
                }
                .offset(x: CGFloat(i) * colW + 1)
                .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
    }
}
