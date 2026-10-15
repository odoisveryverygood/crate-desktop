import Foundation

/// The 16th-note grid of a sample: constant (library loops: bpm) or following tracked beats (imported songs).
struct ChopGrid: Hashable {
    /// Absolute time of step 0 (the first downbeat of the chopped region).
    var origin: Double
    /// Seconds per 16th where no beat times apply.
    var stepSec: Double
    /// Absolute beat times starting at `origin` (optional); 16ths are interpolated between them.
    var beats: [Double] = []

    func time(_ step: Double) -> Double {
        if beats.count >= 2 {
            let b = step / 4
            let i = Int(b.rounded(.down))
            if i >= 0, i + 1 < beats.count { return beats[i] + (b - Double(i)) * (beats[i + 1] - beats[i]) }
            if i < 0 { return beats[0] + b * (beats[1] - beats[0]) }
            let n = beats.count
            return beats[n - 1] + (b - Double(n - 1)) * (beats[n - 1] - beats[n - 2])
        }
        return origin + step * stepSec
    }

    /// Fractional step at absolute time `t` (inverse of `time`).
    func step(at t: Double) -> Double {
        if beats.count >= 2 {
            var lo = 0, hi = beats.count - 1
            if t <= beats[0] { return 4 * (t - beats[0]) / (beats[1] - beats[0]) }
            if t >= beats[hi] { return 4 * (Double(hi) + (t - beats[hi]) / (beats[hi] - beats[hi - 1])) }
            while hi - lo > 1 { let m = (lo + hi) / 2; if beats[m] <= t { lo = m } else { hi = m } }
            return 4 * (Double(lo) + (t - beats[lo]) / (beats[hi] - beats[lo]))
        }
        return (t - origin) / stepSec
    }

    /// Seconds per 16th around step `s`.
    func stepLength(at s: Double) -> Double { time(s + 1) - time(s) }

    /// The grid from `step` on, as a new grid whose step 0 is there.
    func shifted(by steps: Int) -> ChopGrid {
        guard steps != 0 else { return self }
        if beats.count >= 2, steps % 4 == 0, steps / 4 < beats.count - 1, steps > 0 {
            return ChopGrid(origin: beats[steps / 4], stepSec: stepSec, beats: Array(beats[(steps / 4)...]))
        }
        let o = time(Double(steps))
        return ChopGrid(origin: o, stepSec: stepLength(at: Double(steps)), beats: [])
    }
}

/// How a sample is cut onto 16 pads (Serato Sample's Autoset modes, plus a whole-song pick for imported songs).
enum ChopMode: String, CaseIterable {
    /// FIND CHOPS: cuts on real note/hit boundaries (onsets snapped to the 1/16 grid), the 8 best on pads 1–8.
    case find
    /// Equal 1/16-of-the-span slices (snapped to an onset within 30 ms), in time order.
    case slice16
    /// Equal 1/8-of-the-span slices on pads 1–8; pads 9–16 continue past the span when there's more audio.
    case slice8
    /// Imported songs: 16 distinct chops picked across the whole song instead of one region.
    case song
}

/// One chop and what it sounds like (all 0…1 unless noted).
struct ChopFeature: Hashable {
    /// Absolute seconds in the file.
    var start: Double
    var end: Double
    /// Start on the region's 16th grid (step 0 = the region's first downbeat) and length in 16ths (≥ 1).
    var step: Int
    var steps: Int
    /// Loudness relative to the loudest chop of the set.
    var energy: Double = 0
    /// Onset strength at the start (0 = cut where nothing starts).
    var attack: Double = 0
    /// Harmonic clarity × stability (a chop that holds one chord) × not noise.
    var tonal: Double = 0
    var centroid: Double = 0
    var flatness: Double = 0
    /// Mean chroma as shares of the chop's pitched energy (12, sums to 1).
    var chroma: [Double] = Array(repeating: 0, count: 12)
    /// Dominant pitch class.
    var pc: Int = 0
    var score: Double = 0
    var hero = false
    /// Hero rank among the set (0 = best).
    var rank = 0
    /// Start snapped to a detected onset.
    var onset = false
    /// Part of the tiling (played in order = the original loop); false = an extra phrase chop overlapping two tiles.
    var tile = true

    var bar: Int { step / 16 }
    var seconds: Double { end - start }

    /// Share of the chop's prominent pitch classes (chroma above its own mean) inside a scale or chord after shifting
    /// it by `semitones`.
    func fit(_ pcs: Set<Int>, shift semitones: Int = 0) -> Double {
        let mean = chroma.reduce(0, +) / 12
        var s = 0.0, total = 0.0
        for k in 0..<12 {
            let w = max(0, chroma[k] - mean)
            total += w
            if pcs.contains(((k + semitones) % 12 + 12) % 12) { s += w }
        }
        return total > 0 ? s / total : 0
    }

    /// "Is this the same material?" 0…1: the pitch profile (mean-removed chroma, cosine) counts 60 %, loudness /
    /// brightness / attack closeness 40 %.
    static func similarity(_ a: ChopFeature, _ b: ChopFeature) -> Double {
        let ma = a.chroma.reduce(0, +) / 12, mb = b.chroma.reduce(0, +) / 12
        var d = 0.0, na = 0.0, nb = 0.0
        for k in 0..<12 {
            let x = a.chroma[k] - ma, y = b.chroma[k] - mb
            d += x * y; na += x * x; nb += y * y
        }
        let pitch = na > 1e-12 && nb > 1e-12 ? max(0, d / (na * nb).squareRoot()) : (na <= 1e-12 && nb <= 1e-12 ? 1 : 0)
        let de = a.energy - b.energy, dc = 3 * (a.centroid - b.centroid), da = 0.5 * (a.attack - b.attack)
        return 0.6 * pitch + 0.4 * exp(-(de * de + dc * dc + da * da) / 0.08)
    }
}

/// FIND CHOPS. Candidate cut points are the 16th-grid steps of the region; a cut scores high on a detected onset
/// (within ±30 ms; the cut then moves to the quiet point just before that attack and onto a zero crossing), a little
/// for strong metric positions, and low right next to an onset (clipped attack) or through a sustained sound with no
/// onset (mid-note). A DP picks the 16 cuts that tile the region with the best total score and sensible lengths, so
/// played in order the chops are the original loop. Each chop is described (energy, attack, chroma, tonal...), the
/// 8 best distinct ones (max-marginal-relevance on a chroma/energy/brightness vector) become heroes on pads 1–8 in
/// time order, the rest go to pads 9–16 in time order.
enum Chopper {
    static let snapTolerance = 0.03
    /// Onset strength that counts as a real note / hit start.
    static let strongOnset: Float = 0.3

    /// Pads → chops for `mode`. `keep`: pads that must stay as they are (favourites); new chops avoid their audio.
    static func chop(_ sig: ChopSignal, grid: ChopGrid, spanSteps: Int, mode: ChopMode = .find, count: Int = 16,
                     seed: UInt64 = 0, keep: [Int: (start: Double, end: Double)] = [:]) -> [Int: ChopFeature] {
        let span = max(1, spanSteps)
        var set: [ChopFeature]
        switch mode {
        case .find, .song:
            set = find(sig, grid: grid, spanSteps: span, count: min(count, span), seed: seed)
        case .slice16:
            set = equal(sig, grid: grid, from: 0, steps: span, count: min(16, span))
        case .slice8:
            set = equal(sig, grid: grid, from: 0, steps: span, count: min(8, span))
            if grid.time(Double(2 * span)) <= sig.end + 0.02 {
                set += equal(sig, grid: grid, from: span, steps: span, count: min(8, span))
            }
        }
        rank(&set, heroes: mode == .find || mode == .song ? 8 : 0)
        return arrange(set, mode: mode, keep: keep)
    }

    /// Features (and hero ranks) for chops that already exist (user trims, older projects, other chop sources).
    static func describe(_ sig: ChopSignal, grid: ChopGrid, ranges: [Int: (start: Double, end: Double)]) -> [Int: ChopFeature] {
        var list: [(Int, ChopFeature)] = ranges.map { ($0.key, feature(sig, grid: grid, start: $0.value.start, end: $0.value.end)) }
        var feats = list.map(\.1)
        normalizeEnergy(&feats)
        rank(&feats, heroes: min(8, feats.count / 2))
        for i in list.indices { list[i].1 = feats[i] }
        return Dictionary(uniqueKeysWithValues: list)
    }

    // MARK: - FIND

    struct Cut { var q: Double; var onset: ChopSignal.Onset? }

    /// The sample's own swing, in 16ths: how late its odd-16th onsets sit against its even ones (0…0.4).
    static func swing(_ sig: ChopSignal, grid: ChopGrid, steps: Int) -> Double {
        var odd: [Double] = [], even: [Double] = []
        for o in sig.onsets(grid.time(0) - 0.05, grid.time(Double(steps))) where o.s > 0.3 {
            let f = grid.step(at: o.t)
            let ke = 2 * (f / 2).rounded(), ko = 2 * ((f - 1) / 2).rounded() + 1
            if abs(f - ke) < 0.25 { even.append(f - ke) }
            else if f - ko > -0.25, f - ko < 0.5 { odd.append(f - ko) }
        }
        guard odd.count >= 3 else { return 0 }
        func median(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        return max(0, min(0.4, median(odd) - median(even)))
    }

    static func cutScores(_ sig: ChopSignal, grid: ChopGrid, steps: Int, seed: UInt64, swing: Double) -> [Cut] {
        var rng = SeededRNG(seed: seed ^ 0xC40B)
        return (0..<steps).map { s in
            let t = grid.time(Double(s) + (s % 2 == 1 ? swing : 0))
            let m: Double = s % 16 == 0 ? 1 : s % 4 == 0 ? 0.7 : s % 2 == 0 ? 0.4 : 0.2
            var q = 0.4 * m
            let on = sig.onset(near: t, tol: snapTolerance)
            if sig.maxValue(sig.rms, t, t + 0.12) < 0.04 {
                q -= 1.2                                    // a cut in silence makes an empty pad
            } else {
                if let o = on { q += 1.5 * Double(o.s) * (1 - 0.4 * abs(o.t - t) / snapTolerance) }
                let s: Double = Double(on?.s ?? 0)
                if s < Double(strongOnset) {
                    // Right next to an attack (30–90 ms away): the chop would clip it or start with a flam.
                    if on == nil, let miss = sig.onset(near: t, tol: 0.09), miss.s > 0.25 { q -= Double(miss.s) }
                    // Through a sustained sound with nothing (or only a faint flicker) starting: mid-note.
                    let before: Double = sig.mean(sig.rms, t - 0.02, t)
                    let held: Double = min(1, before / 0.5)
                    q -= 0.6 * held * (1 - s / Double(strongOnset))
                }
            }
            if seed != 0 { q += 0.35 * (rng.unit() * 2 - 1) }
            return Cut(q: q, onset: on)
        }
    }

    /// Length prior: target = span ÷ count; 1-step chops (a 16th) are only worth it on strong separate hits.
    static func lengthScore(_ len: Int, target: Double) -> Double {
        let r = log2(Double(len) / max(1, target))
        return -0.35 * r * r - (len == 1 ? 0.4 : 0)
    }

    static func find(_ sig: ChopSignal, grid: ChopGrid, spanSteps S: Int, count: Int, seed: UInt64) -> [ChopFeature] {
        let swing = self.swing(sig, grid: grid, steps: S)
        func gridTime(_ s: Int) -> Double { grid.time(Double(s) + (s % 2 == 1 ? swing : 0)) }
        let cuts = cutScores(sig, grid: grid, steps: S, seed: seed, swing: swing)
        // Sparse material (pads, held chords): only as many tiles as there are real starts (≥ 8); the other pads get
        // phrase chops (two neighbouring tiles) instead of cuts through held notes.
        let strong = (1..<max(1, S)).filter { (cuts[$0].onset?.s ?? 0) >= strongOnset }.count + 1
        let K = min(count, max(min(8, count), strong))
        let target = Double(S) / Double(K)
        let neg = -Double.infinity
        // f[k][s]: best score with cut k (0-based) at step s; cut 0 is at step 0.
        var f = [[Double]](repeating: [Double](repeating: neg, count: S), count: K)
        var from = [[Int]](repeating: [Int](repeating: -1, count: S), count: K)
        f[0][0] = cuts[0].q
        let maxLen = max(16, Int(target * 4))
        if K > 1 {
            for k in 1..<K {
                for s in k..<S {
                    var best = neg, arg = -1
                    for p in max(k - 1, s - maxLen)..<s where f[k - 1][p] > neg {
                        let v = f[k - 1][p] + lengthScore(s - p, target: target)
                        if v > best { best = v; arg = p }
                    }
                    if arg >= 0 { f[k][s] = best + cuts[s].q; from[k][s] = arg }
                }
            }
        }
        var last = -1, bestEnd = neg
        for s in (K - 1)..<S where f[K - 1][s] > neg {
            let v = f[K - 1][s] + lengthScore(S - s, target: target)
            if v > bestEnd { bestEnd = v; last = s }
        }
        var steps: [Int] = []
        if last >= 0 {
            var s = last
            for k in stride(from: K - 1, through: 0, by: -1) { steps.append(s); if k > 0 { s = from[k][s] } }
            steps.reverse()
        } else {
            steps = (0..<K).map { $0 * S / K }
        }
        // Cut times: an onset → the quiet point before its attack; else the grid line. Then a zero crossing.
        var times = steps.map { s -> Double in
            if let o = cuts[s].onset { return max(gridTime(s) - 0.04, min(gridTime(s) + snapTolerance, sig.attackStart(o.t))) }
            return gridTime(s)
        }
        times = ZeroCross.refine(url: sig.url, times: times)
        let endT = min(sig.end, grid.time(Double(S)))
        for i in times.indices {
            times[i] = max(sig.start, times[i])
            if i > 0 { times[i] = max(times[i], times[i - 1] + 0.03) }
        }
        var out: [ChopFeature] = []
        for i in times.indices {
            let e = i + 1 < times.count ? times[i + 1] : endT
            guard e > times[i] + 0.02 else { continue }
            var c = feature(sig, grid: grid, start: times[i], end: e)
            c.step = steps[i]
            c.steps = max(1, (i + 1 < steps.count ? steps[i + 1] : S) - steps[i])
            c.onset = cuts[steps[i]].onset != nil
            if let o = cuts[steps[i]].onset { c.attack = max(c.attack, Double(o.s)) }
            out.append(c)
        }
        if out.count < count, out.count >= 2 {
            // Phrase chops: tile i + tile i+1, the ones starting on the strongest attacks first.
            let pairs = (0..<(out.count - 1)).sorted { out[$0].attack + out[$0].energy > out[$1].attack + out[$1].energy }
            for i in pairs.prefix(count - out.count) {
                var c = feature(sig, grid: grid, start: out[i].start, end: out[i + 1].end)
                c.step = out[i].step
                c.steps = out[i].steps + out[i + 1].steps
                c.onset = out[i].onset
                c.attack = out[i].attack
                c.tile = false
                out.append(c)
            }
        }
        normalizeEnergy(&out)
        return out
    }

    /// `count` equal slices of `steps` steps from step `from`, each snapped to an onset within 30 ms + a zero crossing.
    static func equal(_ sig: ChopSignal, grid: ChopGrid, from: Int, steps: Int, count: Int) -> [ChopFeature] {
        let n = max(1, count)
        let gs = (0...n).map { Double(from) + Double(steps) * Double($0) / Double(n) }
        var times = gs.dropLast().map { s -> Double in
            let t = grid.time(s)
            if let o = sig.onset(near: t, tol: snapTolerance) { return min(t + snapTolerance, sig.attackStart(o.t)) }
            return t
        }
        times = ZeroCross.refine(url: sig.url, times: times)
        let endT = min(sig.end, grid.time(gs[n]))
        var out: [ChopFeature] = []
        for i in times.indices {
            if i > 0 { times[i] = max(times[i], times[i - 1] + 0.02) }
        }
        for i in times.indices {
            let e = i + 1 < times.count ? times[i + 1] : endT
            guard e > times[i] + 0.01 else { continue }
            var c = feature(sig, grid: grid, start: times[i], end: e)
            c.step = Int(gs[i].rounded())
            c.steps = max(1, Int((gs[i + 1] - gs[i]).rounded()))
            c.onset = sig.onset(near: grid.time(gs[i]), tol: snapTolerance) != nil
            out.append(c)
        }
        normalizeEnergy(&out)
        return out
    }

    // MARK: - Description

    static func feature(_ sig: ChopSignal, grid: ChopGrid, start: Double, end: Double) -> ChopFeature {
        let s0 = grid.step(at: start), s1 = grid.step(at: end)
        var c = ChopFeature(start: start, end: end, step: max(0, Int(s0.rounded())), steps: max(1, Int((s1 - s0).rounded())))
        c.energy = sig.mean(sig.rms, start, end)
        c.attack = sig.maxValue(sig.flux, start - 0.005, min(end, start + 0.03))
        c.centroid = sig.mean(sig.centroid, start, end)
        c.flatness = sig.mean(sig.flatness, start, end)
        let raw = sig.chroma(start, end)
        let sum = raw.reduce(0, +)
        if sum > 0 { c.chroma = raw.map { $0 / sum } }
        c.pc = raw.indices.max { raw[$0] < raw[$1] } ?? 0
        let clarity = Self.clarity(raw)
        // Stability: first half vs second half of the chop hold the same harmony.
        let mid = (start + end) / 2
        let stability = end - start > 0.12 ? max(0, pitchSim(sig.chroma(start, mid), sig.chroma(mid, end))) : 0.5
        let noise = min(1, c.flatness / 0.3)
        c.tonal = max(0, min(1, (0.5 * clarity + 0.3 * stability + 0.2) * (1 - 0.7 * noise)))
        return c
    }

    static func normalizeEnergy(_ set: inout [ChopFeature]) {
        let top = set.map(\.energy).max() ?? 0
        guard top > 0 else { return }
        for i in set.indices { set[i].energy = min(1, set[i].energy / top) }
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var d = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { d += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? d / (na * nb).squareRoot() : 0
    }

    /// Same harmony? Cosine of mean-removed chroma (raw chroma is all-positive, so its cosine is always ≈ 1).
    static func pitchSim(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / Double(max(1, a.count)), mb = b.reduce(0, +) / Double(max(1, b.count))
        return cosine(a.map { $0 - ma }, b.map { $0 - mb })
    }

    /// How clearly a chroma names a chord: the top 3 pitch classes' share of the above-average energy (0…1).
    static func clarity(_ c: [Double]) -> Double {
        let mean = c.reduce(0, +) / Double(max(1, c.count))
        let w = c.map { max(0, $0 - mean) }
        let s = w.reduce(0, +)
        guard s > 0 else { return 0 }
        return max(0, min(1, (w.sorted(by: >).prefix(3).reduce(0, +) / s - 0.45) / 0.5))
    }

    /// Hero score + rank: punchy, loud, harmonic, sensibly long, on a strong beat. Heroes are picked greedily by
    /// max-marginal relevance (score − 0.6 × similarity to heroes already picked), so they're different material;
    /// at least one hero is a sustained harmonic chop when the set has one.
    static func rank(_ set: inout [ChopFeature], heroes: Int) {
        for i in set.indices {
            let c = set[i]
            let lenFit: Double = (2...8).contains(c.steps) ? 1 : (c.steps == 1 || (9...12).contains(c.steps)) ? 0.5 : 0.2
            let m: Double = c.step % 16 == 0 ? 1 : c.step % 4 == 0 ? 0.75 : c.step % 2 == 0 ? 0.4 : 0.2
            set[i].score = 0.32 * c.attack + 0.26 * c.energy + 0.2 * c.tonal + 0.12 * lenFit + 0.1 * m
                - (c.energy < 0.12 ? 0.8 : 0)   // near silence is never a hero
                - (c.tile ? 0 : 0.25)            // heroes are single hits; phrase chops are extras
            set[i].hero = false
        }
        var picked: [Int] = []
        var left = Array(set.indices)
        while !left.isEmpty {
            var best = left[0], bestV = -Double.infinity
            for i in left {
                let sim = picked.map { ChopFeature.similarity(set[i], set[$0]) }.max() ?? 0
                let v = set[i].score - 0.7 * max(0, sim - 0.55) / 0.45
                if v > bestV { bestV = v; best = i }
            }
            picked.append(best)
            left.removeAll { $0 == best }
        }
        for (r, i) in picked.enumerated() { set[i].rank = r; set[i].hero = r < heroes }
        // One sustained harmonic chop among the heroes (a chord to hold, not only hits).
        let isPad = { (c: ChopFeature) in c.tonal >= 0.45 && c.steps >= 3 }
        if heroes > 1, !set.contains(where: { $0.hero && isPad($0) }),
           let pad = picked.dropFirst(heroes).first(where: { isPad(set[$0]) }),
           let weakest = picked.prefix(heroes).last {
            set[weakest].hero = false
            set[pad].hero = true
            let r = set[pad].rank
            set[pad].rank = set[weakest].rank
            set[weakest].rank = r
        }
    }

    /// Pad layout. FIND: heroes in time order on pads 1–8, the rest in time order on 9–16. Slices: time order.
    /// Favourite pads (`keep`) stay; chops overlapping a favourite's audio by more than half are dropped.
    static func arrange(_ set: [ChopFeature], mode: ChopMode, keep: [Int: (start: Double, end: Double)]) -> [Int: ChopFeature] {
        var list = set
        if !keep.isEmpty {
            list.removeAll { c in
                keep.values.contains { k in min(c.end, k.end) - max(c.start, k.start) > 0.5 * (c.end - c.start) }
            }
        }
        let ordered: [ChopFeature]
        if mode == .find || mode == .song {
            let heroes = list.filter(\.hero).sorted { $0.start < $1.start }
            let rest = list.filter { !$0.hero }.sorted { ($0.tile ? 0 : 1, $0.start) < ($1.tile ? 0 : 1, $1.start) }
            ordered = heroes + rest
        } else {
            ordered = list.sorted { $0.start < $1.start }
        }
        var out: [Int: ChopFeature] = [:]
        let free = (0..<16).filter { keep[$0] == nil }
        if mode == .find || mode == .song {
            // Heroes fill the free pads among 1–8 first, the rest fill what's left.
            let heroes = ordered.filter(\.hero), rest = ordered.filter { !$0.hero }
            var lowFree = free.filter { $0 < 8 }, highFree = free.filter { $0 >= 8 }
            for c in heroes { if !lowFree.isEmpty { out[lowFree.removeFirst()] = c } else if !highFree.isEmpty { out[highFree.removeFirst()] = c } }
            var remaining = (lowFree + highFree).sorted()
            for c in rest where !remaining.isEmpty { out[remaining.removeFirst()] = c }
        } else {
            for (i, c) in ordered.enumerated() where i < free.count { out[free[i]] = c }
        }
        return out
    }
}
