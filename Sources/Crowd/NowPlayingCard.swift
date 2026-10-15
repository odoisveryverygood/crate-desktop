import SwiftUI

/// Reusable Now Playing card for the crowd stage and the closed outer-screen pose.
struct NowPlayingCard: View {
    let state: AppState

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let artworkSize = min(width, geometry.size.height * 0.72)
            VStack(alignment: .leading, spacing: 8) {
                CoverArtwork(seed: kitSeed)
                    .frame(width: artworkSize, height: artworkSize)
                    .frame(maxWidth: .infinity)
                    .shadow(color: Theme.orange.opacity(0.24), radius: 20, y: 4)

                Text(title)
                    .font(Theme.doto(min(54, width * 0.115)))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .accessibilityIdentifier("now-playing-title")

                Text("CRATE  ·  \(state.styleLabel.uppercased())")
                    .font(Theme.label(min(15, width * 0.033)))
                    .foregroundStyle(Theme.mid)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                TimelineView(.animation(minimumInterval: 1.0 / 15)) { _ in
                    let total = max(1, state.engine.pattern.totalSteps)
                    let position = state.engine.position()
                    let progress = state.engine.isPlaying && position.isFinite
                        ? (position.truncatingRemainder(dividingBy: Double(total)) / Double(total))
                        : 0
                    GeometryReader { line in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Theme.dim)
                            Rectangle().fill(Theme.blue)
                                .frame(width: line.size.width * max(0, min(1, progress)))
                        }
                    }
                }
                .frame(height: 3)
            }
            .frame(width: width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private var title: String {
        // AppState does not expose the GPT arrangement title yet. Use the current
        // sample name, then the style, until the lead adds that field to Core.
        let sample = state.sampleLabel.split(separator: "·", maxSplits: 1).first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return (sample.isEmpty ? state.styleLabel : sample).uppercased()
    }

    private var kitSeed: UInt64 {
        // A stable FNV-1a hash of loaded sound IDs changes the artwork on a new kit.
        let ids = state.sounds.sorted {
            $0.key.bank.rawValue == $1.key.bank.rawValue
                ? $0.key.index < $1.key.index
                : $0.key.bank.rawValue < $1.key.bank.rawValue
        }.map { $0.value.id }.joined(separator: "|")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in ids.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return hash
    }
}

private struct CoverArtwork: View {
    let seed: UInt64

    var body: some View {
        GeometryReader { geometry in
            let gap = max(6, geometry.size.width * 0.025)
            let cell = (geometry.size.width - gap * 5) / 4
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Theme.hex(0x16161D))
                VStack(spacing: gap) {
                    ForEach(0..<4, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<4, id: \.self) { column in
                                let index = row * 4 + column
                                let value = mixed(index)
                                ZStack {
                                    RoundedRectangle(cornerRadius: 4).fill(Theme.hex(0x24242A))
                                    Circle()
                                        .fill(color(value))
                                        .frame(width: cell * (value.isMultiple(of: 5) ? 0.64 : 0.37))
                                        .shadow(color: color(value).opacity(0.45), radius: 8)
                                }
                                .frame(width: cell, height: cell)
                            }
                        }
                    }
                }
                .padding(gap)
            }
        }
        .accessibilityLabel("Cover artwork generated from the current kit")
    }

    private func mixed(_ index: Int) -> UInt64 {
        var x = seed &+ UInt64(index + 1) &* 0x9E3779B97F4A7C15
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        return x ^ (x >> 31)
    }

    private func color(_ value: UInt64) -> Color {
        switch value % 4 {
        case 0: return Theme.orange
        case 1: return Theme.blue
        case 2: return Theme.ochre
        default: return Theme.grey
        }
    }
}

#Preview("Now Playing") {
    NowPlayingCard(state: AppState(engine: MockEngine()))
        .frame(width: 466, height: 520)
        .padding()
        .background(Color.black)
}
