import Foundation

/// Where to sample an imported song (Serato's "regions suitable for sampling"), its beat grid, key and chords.
struct SongPlan {
    var bpm: Double
    var key: String
    var keyConfidence: Double
    /// Tracked beats of the whole analysed song (absolute seconds) and the index of a downbeat among them.
    var beats: [Double]
    var downbeatPhase: Int
    /// The chosen region: its grid (step 0 = its first downbeat), length in bars, absolute start / end.
    var grid: ChopGrid
    var bars: Int
    var start: Double
    var end: Double
    /// One chord guess per bar of the region (nil = unclear).
    var chords: [String?]
    /// Why this region won (for the log): the component scores.
    var why: [String: Double] = [:]
}

/// Beat tracking (Ellis 2007 dynamic programming over the onset envelope), downbeats (chord changes + low-end
/// onsets line up on beat 1) and a region score: harmony that's clear and stable within the bar, not noise/drum
/// dominated, not a busy melody (vocals/leads move pitch inside the bar), loud enough (not the intro or the fade),
/// and a clean loop point (the beat after the region sounds like its first beat, and the next region repeats it).
enum SongRegion {
    static func plan(_ sig: ChopSignal, bpmHint: Double? = nil, barsHint: Int? = nil, originHint: Double? = nil) -> SongPlan? {
        let fps = sig.fps
        var bpm = bpmHint ?? AudioAnalyzer.estimateTempo(sig.flux, fps: fps).bpm
        if !(bpm.isFinite && bpm > 30) { bpm = 90 }
        // Keep the beat between 70 and 150 like the analyzer.
        while bpm < 70 { bpm *= 2 }
        while bpm > 150 { bpm /= 2 }
        // A short file is a loop already: chop all of it (bars from its length), on its own beat.
        let isLoop = sig.duration <= 12.5
        var beats = trackBeats(sig, bpm: bpm)
        if let h = bpmHint ?? (isLoop ? bpm : nil), originHint != nil || isLoop {
            // A hand-checked grid (demo manifest), or a loop: constant tempo from its first beat to the end.
            let period = 60 / h
            let o = originHint ?? beats.first.map { b in b - (b / period).rounded(.down) * period } ?? 0
            beats = stride(from: o, through: sig.end + period * 0.5, by: period).map { $0 }
        }
        guard beats.count >= 5 else { return nil }
        let ibi = median(zip(beats.dropFirst(), beats).map { $0 - $1 })
        bpm = 60 / max(0.2, ibi)
        let phase = originHint != nil || isLoop ? 0 : downbeatPhase(sig, beats: beats)
        let beatChroma = (0..<(beats.count - 1)).map { sig.chroma(beats[$0], beats[$0 + 1]) }
        let beatEnergy = (0..<(beats.count - 1)).map { sig.mean(sig.rms, beats[$0], beats[$0 + 1]) }
        let beatFlat = (0..<(beats.count - 1)).map { sig.mean(sig.flatness, beats[$0], beats[$0 + 1]) }
        let loud = percentile(beatEnergy, 0.9)

        var best: (score: Double, b0: Int, bars: Int, why: [String: Double])? = nil
        var barOptions = barsHint.map { [$0] } ?? [4, 2]
        if isLoop, barsHint == nil {
            let fit = Double(beats.count - 1) / 4
            barOptions = [[8, 4, 2, 1].first { Double($0) <= fit + 0.3 } ?? 1]
        }
        for bars in barOptions {
            let B = bars * 4
            var b0 = phase
            while b0 + B <= beats.count - 1 {
                defer { b0 += 4 }
                let idx = Array(b0..<min(beatChroma.count, b0 + B))
                guard idx.count >= max(2, B - 1) else { continue }
                let n0 = Double(idx.count)
                let clarity = idx.map { Chopper.clarity(beatChroma[$0]) }.reduce(0, +) / n0
                // Busy melody: pitch content changing between beats inside a bar (chord changes on beat 1 are fine).
                var moves = 0.0, n = 0.0
                for i in idx.dropFirst() where (i - phase) % 4 != 0 { moves += 1 - max(0, Chopper.pitchSim(beatChroma[i - 1], beatChroma[i])); n += 1 }
                let busy = n > 0 ? moves / n : 0
                let noise = min(1, idx.map { beatFlat[$0] }.reduce(0, +) / n0 / 0.3)
                let energy = min(1, (idx.map { beatEnergy[$0] }.reduce(0, +) / n0) / max(1e-6, 0.8 * loud))
                // Loop point: the beat right after the region vs its first beat; and the next region repeats this one.
                let seam = b0 + B < beatChroma.count ? max(0, Chopper.pitchSim(beatChroma[b0], beatChroma[b0 + B])) : 0.5
                var rep = 0.0
                if b0 + 2 * B <= beatChroma.count {
                    rep = idx.map { max(0, Chopper.pitchSim(beatChroma[$0], beatChroma[$0 + B])) }.reduce(0, +) / n0
                }
                // Movement: the bars hold different harmony (16 chops of one static chord are 16 copies).
                var move = 0.0
                if bars > 1 {
                    let barChroma = (0..<bars).map { b in sig.chroma(beats[b0 + b * 4], beats[min(beats.count - 1, b0 + b * 4 + 4)]) }
                    for b in 1..<bars { move += 1 - max(0, Chopper.pitchSim(barChroma[b - 1], barChroma[b])) }
                    move = min(1, move / Double(bars - 1) / 0.5)
                }
                let onsetCount = Double(sig.onsets(beats[b0], beats[b0 + B]).filter { $0.s > 0.2 }.count)
                let enough = min(1, onsetCount / Double(B + 4))
                let t0 = beats[b0], t1 = beats[b0 + B]
                let edge = (t0 < 6 ? 0.15 : 0) + (t1 > sig.end - 8 ? 0.2 : 0)
                let score = 0.9 * clarity + 0.5 * seam + 0.5 * rep + 0.6 * energy + 0.3 * enough + 0.45 * move
                    - 0.6 * busy - 0.7 * noise - edge + (bars == 4 ? 0.06 : 0)
                if best == nil || score > best!.score {
                    best = (score, b0, bars, ["clarity": clarity, "seam": seam, "repeat": rep, "energy": energy,
                                             "busy": busy, "noise": noise, "move": move, "score": score])
                }
            }
        }
        guard let win = best else { return nil }
        let regionBeats = Array(beats[win.b0...(win.b0 + win.bars * 4)])
        let grid = ChopGrid(origin: regionBeats[0], stepSec: ibi / 4, beats: regionBeats)
        let start = regionBeats[0], end = min(sig.end, regionBeats[regionBeats.count - 1])
        let i0 = sig.sample(start), i1 = sig.sample(end)
        let key = AudioAnalyzer.estimateKey(Array(sig.x[i0..<max(i0 + 1, i1)]))
        let chords = (0..<win.bars).map { b in
            chordGuess(sig.chroma(regionBeats[b * 4], regionBeats[min(regionBeats.count - 1, b * 4 + 4)]))
        }
        return SongPlan(bpm: (bpm * 10).rounded() / 10, key: key.name, keyConfidence: key.confidence, beats: beats,
                        downbeatPhase: phase, grid: grid, bars: win.bars, start: start, end: end, chords: chords, why: win.why)
    }

    /// 16 distinct chops across the whole song: every downbeat / beat onset is a candidate start, each candidate runs
    /// to the next strong onset (1–8 steps); ranked by the hero score with a penalty for material already picked and a
    /// bonus for parts of the song not yet used.
    static func songChops(_ sig: ChopSignal, plan: SongPlan, seed: UInt64) -> [Int: ChopFeature] {
        let beats = plan.beats
        guard beats.count > 8 else { return [:] }
        let grid = ChopGrid(origin: beats[0], stepSec: (beats[1] - beats[0]) / 4, beats: beats)
        var rng = SeededRNG(seed: seed ^ 0x50C6)
        var cands: [ChopFeature] = []
        for (bi, bt) in beats.enumerated() where bi + 1 < beats.count {
            guard let o = sig.onset(near: bt, tol: Chopper.snapTolerance), o.s > 0.25 else { continue }
            let start = sig.attackStart(o.t)
            // End: the next strong onset 2–8 steps later (on the grid), else 4 steps.
            var endStep = Double(bi * 4 + 4)
            for k in 2...8 {
                let t = grid.time(Double(bi * 4 + k))
                if let n = sig.onset(near: t, tol: Chopper.snapTolerance), n.s > 0.5 { endStep = Double(bi * 4 + k); break }
            }
            let end = min(sig.end, grid.time(endStep))
            guard end - start > 0.08 else { continue }
            var c = Chopper.feature(sig, grid: grid, start: start, end: end)
            c.step = bi * 4
            c.steps = max(1, Int(endStep) - bi * 4)
            c.onset = true
            c.attack = max(c.attack, Double(o.s))
            cands.append(c)
        }
        Chopper.normalizeEnergy(&cands)
        Chopper.rank(&cands, heroes: 0)
        let span = max(1, sig.duration)
        var picked: [ChopFeature] = []
        var used = Set<Int>()
        while picked.count < 16, used.count < cands.count {
            var best = -1, bestV = -Double.infinity
            for (i, c) in cands.enumerated() where !used.contains(i) {
                if picked.contains(where: { abs($0.start - c.start) < 0.25 }) { used.insert(i); continue }
                let sim = picked.map { ChopFeature.similarity(c, $0) }.max() ?? 0
                let region = Int((c.start - sig.start) / span * 8)
                let fresh = picked.contains { Int(($0.start - sig.start) / span * 8) == region } ? 0 : 0.08
                let v = c.score - 0.8 * max(0, sim - 0.6) * 2.5 + fresh + 0.05 * rng.unit()
                if v > bestV { bestV = v; best = i }
            }
            guard best >= 0 else { break }
            used.insert(best)
            picked.append(cands[best])
        }
        let starts = ZeroCross.refine(url: sig.url, times: picked.map(\.start))
        for i in picked.indices { picked[i].start = starts[i] }
        Chopper.rank(&picked, heroes: 8)
        return Chopper.arrange(picked, mode: .song, keep: [:])
    }

    // MARK: - Beats

    /// Ellis-style DP: score(t) = onset(t) + max over the previous beat τ ∈ [t − 2P, t − P/2] of
    /// score(τ) − α·log²((t − τ)/P); backtrace from the best frame in the last period.
    static func trackBeats(_ sig: ChopSignal, bpm: Double) -> [Double] {
        let fps = sig.fps
        let o = sig.flux.map(Double.init)
        let n = o.count
        let period = 60 / bpm * fps
        guard n > Int(period * 4) else { return [] }
        let mean = o.reduce(0, +) / Double(n)
        let sd = max(1e-9, (o.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n)).squareRoot())
        let env = o.map { ($0 - mean) / sd }
        let alpha = 100.0
        var score = [Double](repeating: 0, count: n)
        var back = [Int](repeating: -1, count: n)
        let lo = Int((period * 0.5).rounded()), hi = Int((period * 2).rounded())
        var penalty = [Double](repeating: 0, count: hi + 1)
        for d in max(1, lo)...hi { let r = log(Double(d) / period); penalty[d] = alpha * r * r }
        for t in 0..<n {
            var best = 0.0, arg = -1
            let a = max(0, t - hi), b = t - max(1, lo)
            if b >= a {
                for tau in a...b {
                    let v = score[tau] - penalty[t - tau]
                    if arg < 0 || v > best { best = v; arg = tau }
                }
            }
            score[t] = env[t] + (arg >= 0 ? max(0, best) : 0)
            back[t] = arg >= 0 && best > 0 ? arg : -1
        }
        let tail = max(0, n - Int(period))
        var t = (tail..<n).max { score[$0] < score[$1] } ?? (n - 1)
        var out: [Int] = []
        while t >= 0 { out.append(t); t = back[t] }
        return out.reversed().map { sig.start + Double($0) / fps }
    }

    /// Which beat (mod 4) is beat 1: chord changes and low-end hits (kick, bass entries) land there.
    static func downbeatPhase(_ sig: ChopSignal, beats: [Double]) -> Int {
        guard beats.count > 8 else { return 0 }
        var score = [Double](repeating: 0, count: 4)
        var prev = sig.chroma(beats[0], beats[1])
        for i in 1..<(beats.count - 1) {
            let c = sig.chroma(beats[i], beats[i + 1])
            let novelty = 1 - max(0, Chopper.cosine(prev, c))
            let lowHit = sig.maxValue(sig.low, beats[i] - 0.03, beats[i] + 0.05)
            score[i % 4] += novelty + 0.5 * lowHit
            prev = c
        }
        return score.indices.max { score[$0] < score[$1] } ?? 0
    }

    // MARK: - Chords

    /// Major / minor triad template match ("Am", "F", nil when nothing fits clearly).
    static func chordGuess(_ chroma: [Double]) -> String? {
        let s = chroma.reduce(0, +)
        guard s > 0 else { return nil }
        var best = (r: -1.0, name: "")
        for root in 0..<12 {
            for minor in [false, true] {
                let third = minor ? 3 : 4
                var t = [Double](repeating: 0, count: 12)
                t[root] = 1; t[(root + third) % 12] = 0.8; t[(root + 7) % 12] = 0.8
                let r = AudioAnalyzer.pearson(chroma, t)
                if r > best.r { best = (r, AudioAnalyzer.pitchNames[root] + (minor ? "m" : "")) }
            }
        }
        return best.r > 0.45 ? best.name : nil
    }

    static func median(_ a: [Double]) -> Double {
        let s = a.sorted()
        return s.isEmpty ? 0.5 : s[s.count / 2]
    }

    static func percentile(_ a: [Double], _ p: Double) -> Double {
        let s = a.sorted()
        return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * p))]
    }
}
