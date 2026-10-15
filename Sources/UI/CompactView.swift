import SwiftUI

/// Outer display (closed, ~466×678): a mini lid (header line, result line, prompt),
/// the 4×4 pads, and a bottom row with banks, transport and ✦ DIG.
struct CompactView: View {
    let state: AppState

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 16
            let topInset = max(inset, geo.safeAreaInsets.top)
            Group {
                if geo.size.width > geo.size.height {
                    // Closed, held sideways: readouts + transport left, square pad grid right.
                    HStack(spacing: 12) {
                        VStack(spacing: 10) {
                            miniLid(fill: true)
                            bottomRow(stacked: true)
                        }
                        .frame(width: geo.size.width * 0.44)
                        PadGridView(state: state, gap: 5)
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 10) {
                        miniLid(fill: false)
                        PadGridView(state: state, gap: 5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        bottomRow(stacked: false)
                    }
                }
            }
            .padding(.horizontal, inset)
            .padding(.top, topInset)
            .padding(.bottom, max(inset, geo.safeAreaInsets.bottom))
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(OuterField.aluminium)
        .ignoresSafeArea(.keyboard)
        .crateDeferEdgeGestures()
    }

    /// The outer screen's lid card, with the phone's rules: one header line (project · BPM · bar · loop · ↶ ↷),
    /// the result line (what the last change touched), and the prompt with ＋. No FLIP IT / AI PERFORM chips (FLIP IT
    /// shows only right after a song import) and no timing or log lines. Sideways, the step grid fills the card.
    private func miniLid(fill: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LidProjectChip(state: state)
                    .frame(maxWidth: fill ? 120 : 140, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                TempoChip(state: state, size: 12)
                if !fill { BarReadout(state: state, size: 12) }   // the sideways card is narrow
                Spacer(minLength: 4)
                LoopMenu(state: state, compact: true, segments: false)
                HistoryButtons(size: 30)
            }
            .frame(height: 30)
            if fill {
                GeometryReader { g in
                    let rows = max(5, SeqRows.build(state, state.engine.pattern).count)
                    let need = SeqGridView.fittedHeight(rows: rows, pitch: 14)
                    if need > g.size.height {
                        ScrollView(.vertical, showsIndicators: false) {
                            SeqGridView(state: state, maxPitch: 14).frame(height: need)
                        }
                    } else {
                        SeqGridView(state: state, maxPitch: 20)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            LidResultLine(state: state)
                .frame(height: 16)
                .accessibilityIdentifier("ai-log")
            LidPromptRow(state: state, showChips: true, chipIDs: LidChips.phoneSet,
                         height: 36, fontSize: 13, compact: true)
        }
        .padding(14)
        .frame(maxHeight: fill ? .infinity : nil, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black))
    }

    @ViewBuilder
    private func bottomRow(stacked: Bool) -> some View {
        if stacked {
            VStack(spacing: 10) {
                banks
                transport
            }
        } else {
            HStack(spacing: 16) {
                banks.frame(width: 160)
                transport
            }
        }
    }

    private var banks: some View {
        HStack(spacing: 0) {
            ForEach(Bank.allCases, id: \.self) { bank in
                let selected = state.bank == bank
                Button { CrateUI.shared.selectBank(bank, state) } label: {
                    VStack(spacing: 4) {
                        Circle().fill(selected ? OuterField.ink : OuterField.key)
                            .overlay(Circle().strokeBorder(OuterField.seam, lineWidth: selected ? 0 : 0.5))
                            .overlay(Circle().fill(OuterField.bank(bank)).frame(width: 7, height: 7))
                            .frame(width: 29, height: 29)
                        Text(bank.letter).font(OuterField.type(8, weight: 600))
                            .foregroundStyle(selected ? OuterField.ink : OuterField.inkSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("bank-\(bank.letter)")
                .accessibilityLabel("Bank \(bank.letter)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var transport: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let running = CrateUI.shared.transportRunning(state)
            HStack(spacing: 5) {
                control("rec", symbol: "circle.fill", label: "Record",
                        active: state.isRecording || CrateUI.shared.countIn != nil) {
                    CrateUI.shared.recPressed(state)
                }
                // ▶ morphs into ❚❚ while playing; pause stops (the next ▶ starts at bar 1)
                control("play", symbol: running ? "pause.fill" : "play.fill", label: running ? "Pause" : "Play",
                        active: running) {
                    CrateUI.shared.playPausePressed(state)
                }
                Button { CrateUI.shared.digPressed(state) } label: {
                    HStack(spacing: 5) {
                        SparkShape().fill(OuterField.key).frame(width: 9, height: 9)
                        Text("DIG").font(OuterField.type(10, weight: 600)).tracking(1)
                    }
                    .foregroundStyle(OuterField.key)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(state.isDigging ? Theme.orange : OuterField.ink, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("dig-button").accessibilityLabel("Dig")
            }
        }
    }

    private func control(_ id: String, symbol: String, label: String, active: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .foregroundStyle(active ? OuterField.key : OuterField.ink)
                .frame(width: 48, height: 44)
                .background(active ? (id == "rec" ? Theme.orange : OuterField.ink) : OuterField.key,
                            in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id).accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

}

/// Legacy tent view, kept in the same Field type language as the accessory card.
struct CrowdView: View {
    let state: AppState

    /// Hats and shakers tick every 16th, so the crowd display follows the "big" hits.
    private static let skipA: Set<Int> = [4, 5, 6, 10]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { ctx in
            let f = LiveFrame(state)
            let (pad, age) = lastHit(f, now: ctx.date)
            let level = Double(state.engine.level())
            GeometryReader { geo in
                VStack(spacing: 0) {
                    HStack {
                        Text("CRATE · CR-16").crateLabel(11).foregroundStyle(Theme.text)
                        Spacer()
                        Text("\(String(format: "%03d", Int(state.engine.bpm.rounded()))) BPM · \(f.barBeat)")
                            .crateLabel(11)
                            .foregroundStyle(Theme.mid)
                    }
                    Spacer(minLength: 0)
                    Text(pad.map { UIHelpers.padName(state, $0) ?? "PAD \($0.number)" } ?? "CRATE")
                        .font(OuterField.type(min(geo.size.height * 0.42, 220), weight: 300))
                        .foregroundStyle(age < Theme.flash ? Theme.orange : OuterField.white)
                        .opacity(age < Theme.flash ? 1 : max(0.55, 1 - age * 0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.2)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("crowd-name")
                    Spacer(minLength: 0)
                    if state.performOn {
                        Text("AI PERFORM ▸ \(state.lastPerform.isEmpty ? "ON" : state.lastPerform.uppercased())")
                            .font(Theme.mono(12, bold: true))
                            .foregroundStyle(Theme.orange)
                            .padding(.bottom, 10)
                    }
                    LevelMeter(level: level)
                        .frame(height: 18)
                        .accessibilityIdentifier("crowd-level")
                }
                .padding(20)
            }
        }
        .background(Color.black)
    }

    private func lastHit(_ f: LiveFrame, now: Date) -> (PadID?, Double) {
        let liveAge = now.timeIntervalSince(state.lastHitTime)
        if let p = state.lastHitPad, liveAge < 1.5 { return (p, liveAge) }
        guard f.playing else { return (state.lastHitPad, liveAge) }
        var best: (PadID, Double)? = nil
        for (pad, hits) in f.pattern.lanes {
            if pad.bank == .a && Self.skipA.contains(pad.index) { continue }
            for h in hits where h.velocity >= 60 {
                let a = f.age(f.hitTime(h, pad))
                if best == nil || a < best!.1 { best = (pad, a) }
            }
        }
        guard let b = best else { return (state.lastHitPad, liveAge) }
        return (b.0, b.1 * f.stepDur)
    }
}

/// Horizontal dot-matrix level meter (orange, last segments red-hot).
struct LevelMeter: View {
    var level: Double
    var segments = 32

    var body: some View {
        GeometryReader { g in
            let lit = Int((pow(min(1, max(0, level)), 0.5) * Double(segments)).rounded())
            HStack(spacing: 3) {
                ForEach(0..<segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i < lit ? (i > segments - 5 ? Theme.red : Theme.orange) : Theme.dotOff)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

#Preview("Compact · portrait") {
    CompactView(state: AppState(engine: MockEngine())).frame(width: 466, height: 678)
}
#Preview("Compact · landscape") {
    CompactView(state: AppState(engine: MockEngine())).frame(width: 678, height: 466)
}
