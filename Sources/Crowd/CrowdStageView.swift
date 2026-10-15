import SwiftUI

/// Audience-facing content for the Duo's outer display. The host owns the accessory scene.
struct CrowdStageView: View {
    let state: AppState
    var rotate: Angle = .zero

    @State private var lastHighPunch = Date.distantPast
    @State private var dropFlashUntil = Date.distantPast

    var body: some View {
        GeometryReader { geometry in
            // The Duo's outer panel presents wide while the device is open: lay out for the real frame,
            // no automatic rotation (the host can still pass `rotate` if a panel ever presents sideways).
            let size = geometry.size
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                Group {
                    if size.width > size.height * 1.15 {
                        wideStage(size: size, now: timeline.date)
                    } else {
                        stage(size: size, now: timeline.date)
                    }
                }
                .frame(width: size.width, height: size.height)
                .rotationEffect(rotate)
            }
        }
        .background(Color.black)
        .clipped()
        .onChange(of: state.punch) { old, new in
            if old > 0.6 { lastHighPunch = Date() }
            if new < 0.1, Date().timeIntervalSince(lastHighPunch) < 0.3 {
                dropFlashUntil = Date().addingTimeInterval(0.28)
                lastHighPunch = .distantPast
            }
        }
    }

    /// Wide panel: cover art left, a quiet title block right. Minimal text so it reads from across a room.
    private func wideStage(size: CGSize, now: Date) -> some View {
        let inset = max(24, size.height * 0.08)
        let cover = size.height - inset * 2
        let level = min(1, max(0, Double(state.engine.level())))
        return ZStack {
            Color.black
            HStack(alignment: .center, spacing: inset) {
                NowPlayingCard(state: state)
                    .frame(width: cover, height: cover)
                VStack(alignment: .leading, spacing: max(10, size.height * 0.035)) {
                    Text("CRATE")
                        .font(Theme.doto(min(44, size.height * 0.09)))
                        .foregroundStyle(Theme.orange)
                        .fixedSize()
                    Spacer(minLength: 0)
                    Text(state.styleLabel.uppercased())
                        .font(Theme.doto(min(64, size.height * 0.13)))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(state.sampleLabel.uppercased())
                        .font(Theme.label(max(12, size.height * 0.035)))
                        .foregroundStyle(Theme.mid)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    GeometryReader { bar in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Theme.dim)
                            Rectangle().fill(Theme.orange).frame(width: bar.size.width * level)
                        }
                    }
                    .frame(height: 3)
                }
                .frame(maxHeight: cover, alignment: .topLeading)
            }
            .padding(inset)
            .frame(width: size.width, height: size.height, alignment: .leading)

            if now < dropFlashUntil {
                Theme.orange.opacity(0.93)
                Text("DROP")
                    .font(Theme.doto(min(size.height * 0.4, 200)))
                    .foregroundStyle(Color.black)
                    .minimumScaleFactor(0.5)
                    .accessibilityIdentifier("crowd-drop")
            }
        }
    }

    private func stage(size: CGSize, now: Date) -> some View {
        let inset = max(20, size.width * 0.055)
        let active = activePads(now: now)
        let level = min(1, max(0, Double(state.engine.level())))

        return ZStack {
            Color.black
            VStack(alignment: .leading, spacing: max(12, size.height * 0.025)) {
                HStack(alignment: .firstTextBaseline) {
                    Text("CRATE").font(Theme.doto(min(55, size.width * 0.13)))
                        .foregroundStyle(Theme.orange)
                    Spacer()
                    Text("CR-16  /  LIVE").font(Theme.label(max(11, size.width * 0.025)))
                        .foregroundStyle(Theme.mid)
                }

                NowPlayingCard(state: state)
                    .frame(height: min(size.width + 80, size.height * 0.52))

                Text("\(state.styleLabel.uppercased())  ×  \(state.sampleLabel.uppercased())")
                    .font(Theme.label(max(15, size.width * 0.039)))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityIdentifier("crowd-style-sample")

                VStack(spacing: max(5, size.width * 0.015)) {
                    ForEach(0..<4, id: \.self) { row in
                        HStack(spacing: max(5, size.width * 0.015)) {
                            ForEach(0..<4, id: \.self) { column in
                                let index = (3 - row) * 4 + column
                                Circle()
                                    .fill(active.contains(index) ? Theme.orange : Theme.dotOff)
                                    .overlay(Circle().stroke(active.contains(index) ? Theme.text.opacity(0.7) : Theme.dim, lineWidth: 1))
                            }
                        }
                    }
                }
                .frame(height: min(92, size.height * 0.13))
                .accessibilityIdentifier("crowd-hit-matrix")

                GeometryReader { bar in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.dim)
                        Rectangle().fill(Theme.orange).frame(width: bar.size.width * level)
                    }
                }
                .frame(height: max(5, size.height * 0.009))
                .accessibilityIdentifier("crowd-level")

                Text(state.lastPerform.isEmpty ? "PERFORM  ▸  READY" : "PERFORM  ▸  \(state.lastPerform.uppercased())")
                    .font(Theme.label(max(11, size.width * 0.028)))
                    .foregroundStyle(Theme.ochre)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityIdentifier("crowd-perform")
            }
            .padding(inset)
            .frame(width: size.width, height: size.height, alignment: .topLeading)

            if now < dropFlashUntil {
                Theme.orange.opacity(0.93)
                Text("DROP")
                    .font(Theme.doto(min(size.width * 0.32, 170)))
                    .foregroundStyle(Color.black)
                    .minimumScaleFactor(0.5)
                    .accessibilityIdentifier("crowd-drop")
            }
        }
    }

    private func activePads(now: Date) -> Set<Int> {
        var indices = Set<Int>()
        if let pad = state.lastHitPad, now.timeIntervalSince(state.lastHitTime) < 0.16 {
            indices.insert(pad.index)
        }
        guard state.engine.isPlaying else { return indices }
        let pattern = state.engine.pattern
        let total = max(1, pattern.totalSteps)
        let position = state.engine.position()
        guard position.isFinite else { return indices }
        let step = ((Int(floor(position)) % total) + total) % total
        let phase = position - floor(position)
        if phase < 0.28 {
            for (pad, hits) in pattern.lanes where hits.contains(where: { $0.step == step }) {
                indices.insert(pad.index)
            }
            for (pad, notes) in pattern.notes where notes.contains(where: { $0.step == step }) {
                indices.insert(pad.index)
            }
        }
        return indices
    }
}

#Preview("Crowd · portrait") {
    CrowdStageView(state: AppState(engine: MockEngine()))
        .frame(width: 466, height: 678)
}

#Preview("Crowd · rotated") {
    CrowdStageView(state: AppState(engine: MockEngine()))
        .frame(width: 678, height: 466)
}
