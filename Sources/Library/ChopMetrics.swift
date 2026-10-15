import Foundation

/// How good a set of chops is, measured on the audio (debug command `crate://chopcheck`, tools/chop-harness).
///   • onGrid: the start is within 30 ms of a 16th of the sample's grid.
///   • nearOnset: within 10 ms before / 5 ms after the quiet point in front of a detected attack.
///   • zeroCross: the start sits on a zero crossing at the file's own rate (no click).
///   • midNote: no attack within ±30 ms of the start and the sound is sustained across the cut (energy just before
///     the cut ≥ half of the loudest moment in the 100 ms after it).
///   • distinct: 1 − mean nearest-neighbour similarity of pads 1–8 (chroma + energy + brightness + attack vector);
///     dupPairs: pairs among all pads with similarity ≥ 0.97.
enum ChopMetrics {
    struct Chop {
        var pad: Int
        var start: Double
        var length: Double
        var energyDB: Double
        var onGrid: Bool
        var nearOnset: Bool
        var zeroCross: Bool
        var midNote: Bool
        var attackMs: Double?
    }

    struct Report {
        var chops: [Chop]
        var distinct: Double
        var dupPairs: Int
        var pct: (onset: Double, zero: Double, grid: Double, midNote: Double) {
            let n = Double(max(1, chops.count))
            return (Double(chops.filter(\.nearOnset).count) / n * 100, Double(chops.filter(\.zeroCross).count) / n * 100,
                    Double(chops.filter(\.onGrid).count) / n * 100, Double(chops.filter(\.midNote).count) / n * 100)
        }
        var summary: [String: Any] {
            let p = pct
            return ["n": chops.count, "pctNearOnset": (p.onset * 10).rounded() / 10, "pctZeroCross": (p.zero * 10).rounded() / 10,
                    "pctOnGrid": (p.grid * 10).rounded() / 10, "pctMidNote": (p.midNote * 10).rounded() / 10,
                    "distinct": (distinct * 1000).rounded() / 1000, "dupPairs": dupPairs]
        }
    }

    static func measure(_ sig: ChopSignal, grid: ChopGrid, pads: [Int: (start: Double, end: Double)]) -> Report {
        let keys = pads.keys.sorted()
        let zc = ZeroCross.check(url: sig.url, times: keys.map { pads[$0]!.start })
        var chops: [Chop] = []
        for (n, k) in keys.enumerated() {
            let r = pads[k]!
            let t = r.start
            let s = grid.step(at: t)
            let gridDist = abs(grid.time(s.rounded()) - t)
            // The attack the start belongs to: the nearest onset within 30 ms, measured from its quiet point.
            var attackMs: Double? = nil
            if let o = sig.onset(near: t + 0.01, tol: 0.035) { attackMs = (t - sig.attackStart(o.t)) * 1000 }
            let near = attackMs.map { $0 >= -10 && $0 <= 5 } ?? false
            let before = sig.mean(sig.rms, t - 0.015, t)
            let after = sig.maxValue(sig.rms, t, t + 0.1)
            let mid = sig.onset(near: t, tol: 0.03) == nil && before >= 0.5 * after && after > 0.02
            let e = sig.mean(sig.rms, r.start, r.end)
            chops.append(Chop(pad: k, start: t, length: r.end - r.start, energyDB: 20 * log10(max(1e-5, e)), onGrid: gridDist <= 0.03,
                              nearOnset: near, zeroCross: zc[n], midNote: mid, attackMs: attackMs))
        }
        let feats = Dictionary(uniqueKeysWithValues: keys.map { ($0, Chopper.feature(sig, grid: grid, start: pads[$0]!.start, end: pads[$0]!.end)) })
        var normalized = keys.map { feats[$0]! }
        Chopper.normalizeEnergy(&normalized)
        let byPad = Dictionary(uniqueKeysWithValues: zip(keys, normalized))
        let first8 = keys.filter { $0 < 8 }.compactMap { byPad[$0] }
        var nn = 0.0
        for (i, a) in first8.enumerated() {
            nn += first8.enumerated().filter { $0.offset != i }.map { ChopFeature.similarity(a, $0.element) }.max() ?? 0
        }
        let distinct = first8.count > 1 ? 1 - nn / Double(first8.count) : 0
        var dups = 0
        for i in normalized.indices { for j in normalized.indices where j > i && ChopFeature.similarity(normalized[i], normalized[j]) >= 0.9 { dups += 1 } }
        return Report(chops: chops, distinct: distinct, dupPairs: dups)
    }
}
