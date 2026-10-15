import Foundation
import AVFoundation
import Accelerate

/// Frame features of a stretch of audio for chopping (`Chopper`), song regions (`SongRegion`) and chop metrics.
/// Mono, resampled to 22 050 Hz, peak-normalised. Every time in the API is absolute seconds in the file.
///   • 512-point STFT, hop 128 (≈ 5.8 ms): log-magnitude spectral flux (onsets), low-band flux, centroid, flatness.
///   • 4096-point STFT, hop 1024 (≈ 46 ms): chroma (55 Hz–4 kHz, cos²-weighted semitone bins).
///   • RMS per 5.8 ms frame; onsets = flux peaks over an adaptive threshold, ≥ 50 ms apart, strength 0…1.
/// Thread-safe after `load` (immutable); `load` caches the last few signals.
final class ChopSignal {
    static let rate: Double = 22050
    static let hop = 128
    static let fftN = 512
    static let chromaN = 4096
    static let chromaHop = 1024

    struct Onset: Hashable { var t: Double; var s: Float }
    /// How much of an imported song is analysed (region search, whole-song chops).
    static let songSeconds: Double = 180

    let url: URL
    /// The decoded span runs to the end of the file (so a cache hit can't miss audio past it).
    var toEnd = false
    let start: Double
    let x: [Float]
    /// Onset strength per frame (÷ the 95th percentile of flux peaks, clipped to 0…1).
    let flux: [Float]
    /// Low-band (< 200 Hz) flux per frame, 0…1: kicks / bass entries (downbeats).
    let low: [Float]
    /// RMS per frame (÷ max).
    let rms: [Float]
    /// Spectral centroid per frame, Hz ÷ 11 025.
    let centroid: [Float]
    /// Spectral flatness per frame 0…1 (noise-like = high: drums, cymbals, hiss).
    let flatness: [Float]
    /// Chroma per 46 ms frame (12 bins, log-compressed energy).
    let chroma: [[Float]]
    let onsets: [Onset]

    var fps: Double { Self.rate / Double(Self.hop) }
    var duration: Double { Double(x.count) / Self.rate }
    var end: Double { start + duration }

    init(url: URL, start: Double, x: [Float]) {
        self.url = url
        self.start = start
        self.x = x
        let f = Self.frames(x)
        flux = f.flux; low = f.low; centroid = f.centroid; flatness = f.flatness; rms = f.rms
        chroma = Self.chromagram(x)
        onsets = Self.pickOnsets(flux, fps: Self.rate / Double(Self.hop), start: start)
    }

    // MARK: - Lookups

    func frame(_ t: Double) -> Int { max(0, min(flux.count - 1, Int(((t - start) * fps).rounded()))) }
    func sample(_ t: Double) -> Int { max(0, min(x.count - 1, Int(((t - start) * Self.rate).rounded()))) }

    func mean(_ a: [Float], _ t0: Double, _ t1: Double) -> Double {
        guard !a.isEmpty else { return 0 }
        let i0 = frame(t0), i1 = max(i0 + 1, min(a.count, frame(t1)))
        var s: Float = 0
        a.withUnsafeBufferPointer { p in vDSP_sve(p.baseAddress! + i0, 1, &s, vDSP_Length(i1 - i0)) }
        return Double(s) / Double(i1 - i0)
    }

    func maxValue(_ a: [Float], _ t0: Double, _ t1: Double) -> Double {
        guard !a.isEmpty else { return 0 }
        let i0 = frame(t0), i1 = max(i0 + 1, min(a.count, frame(t1)))
        var m: Float = 0
        a.withUnsafeBufferPointer { p in vDSP_maxv(p.baseAddress! + i0, 1, &m, vDSP_Length(i1 - i0)) }
        return Double(m)
    }

    /// Mean chroma over [t0, t1) (frames whose centre falls inside; the nearest frame for very short spans).
    func chroma(_ t0: Double, _ t1: Double) -> [Double] {
        var out = [Double](repeating: 0, count: 12)
        guard !chroma.isEmpty else { return out }
        let cps = Self.rate / Double(Self.chromaHop)
        let i0 = Int(((t0 - start) * cps).rounded(.up)), i1 = Int(((t1 - start) * cps).rounded(.down))
        var idx = Array(max(0, i0)...max(0, min(chroma.count - 1, i1)))
        if i1 < i0 { idx = [max(0, min(chroma.count - 1, Int((((t0 + t1) / 2 - start) * cps).rounded())))] }
        for i in idx where i < chroma.count { for k in 0..<12 { out[k] += Double(chroma[i][k]) } }
        return out
    }

    /// The nearest onset to `t` within `tol` seconds.
    func onset(near t: Double, tol: Double) -> Onset? {
        var lo = 0, hi = onsets.count
        while lo < hi { let m = (lo + hi) / 2; if onsets[m].t < t { lo = m + 1 } else { hi = m } }
        var best: Onset? = nil
        for i in [lo - 1, lo] where i >= 0 && i < onsets.count && abs(onsets[i].t - t) <= tol {
            if best == nil || abs(onsets[i].t - t) < abs(best!.t - t) { best = onsets[i] }
        }
        return best
    }

    /// Onsets in [t0, t1).
    func onsets(_ t0: Double, _ t1: Double) -> [Onset] { onsets.filter { $0.t >= t0 && $0.t < t1 } }

    /// Where the attack of an onset detected at `t` begins: on a 3 ms RMS envelope (0.25 ms steps) the last point
    /// before the attack's peak that is still below floor + 15 % of the rise, minus 1.5 ms of headroom. Soft onsets
    /// with no clear rise keep `t` − 5 ms.
    func attackStart(_ t: Double) -> Double {
        let hopS = max(1, Int(0.00025 * Self.rate)), w = Int(0.003 * Self.rate)
        let a = sample(t - 0.025), b = sample(t + 0.015)
        guard b - a > 2 * w else { return t }
        let count = (b - a) / hopS
        var env = [Float](repeating: 0, count: count)
        x.withUnsafeBufferPointer { p in
            for i in 0..<count {
                let c = a + i * hopS, lo = max(0, c - w / 2), n = min(x.count, c + w / 2) - lo
                var ms: Float = 0
                vDSP_measqv(p.baseAddress! + lo, 1, &ms, vDSP_Length(max(1, n)))
                env[i] = ms.squareRoot()
            }
        }
        func time(_ i: Int) -> Double { start + Double(a + i * hopS) / Self.rate }
        // The attack's peak: the loudest point from 10 ms before the onset frame on.
        let from = max(0, Int(0.015 * Self.rate) / hopS)
        guard from < count else { return t - 0.005 }
        var peak = from
        for i in from..<count where env[i] > env[peak] { peak = i }
        var floor = env[peak]
        for i in 0...peak where env[i] < floor { floor = env[i] }
        guard env[peak] > floor * 1.4 + 1e-6 else { return t - 0.005 }
        let threshold = floor + 0.15 * (env[peak] - floor)
        var rise = 0
        for i in stride(from: peak, through: 0, by: -1) where env[i] <= threshold { rise = i; break }
        return max(time(0), time(rise) - 0.0015)
    }

    // MARK: - Cache

    private static let lock = NSLock()
    private static var cache: [ChopSignal] = []

    /// Decode [start, start + duration] of `url` (whole file from `start` when nil). Cached: a cached signal that
    /// covers the request is returned as is.
    static func load(url: URL, start: Double = 0, duration: Double? = nil, maxSeconds: Double = 300) throws -> ChopSignal {
        let key = url.standardizedFileURL.path
        lock.lock()
        if let d = duration, let hit = cache.first(where: { s in
            s.url.standardizedFileURL.path == key && s.start <= start + 0.0005 && (s.end >= start + d - 0.02 || s.toEnd) }) {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let (x, toEnd) = try decode(url: url, start: start, duration: duration, maxSeconds: maxSeconds)
        let sig = ChopSignal(url: url, start: max(0, start), x: x)
        sig.toEnd = toEnd
        lock.lock()
        cache.removeAll { $0.url.standardizedFileURL.path == key && $0.start >= sig.start && $0.end <= sig.end }
        cache.insert(sig, at: 0)
        var total = 0
        cache = cache.filter { s in total += s.x.count; return total < 12_000_000 }   // ≈ 9 min of audio, ~50 MB
        lock.unlock()
        return sig
    }

    static func cached(url: URL) -> ChopSignal? {
        let key = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        return cache.first { $0.url.standardizedFileURL.path == key }
    }

    /// Mono 22 050 Hz, peak-normalised samples of [start, start + duration], and whether that reached the file's end.
    static func decode(url: URL, start: Double, duration: Double?, maxSeconds: Double) throws -> ([Float], Bool) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sr = format.sampleRate
        guard sr > 0, file.length > 0 else { throw AudioAnalyzer.AnalysisError.empty }
        let a = min(max(0, AVAudioFramePosition(max(0, start) * sr)), file.length)
        let rest = Double(file.length - a) / sr
        var span = min(rest, maxSeconds)
        if let d = duration, d.isFinite, d > 0 { span = min(span, d) }
        let toEnd = span >= rest - 0.001
        let want = AVAudioFrameCount(max(0, (span * sr).rounded(.down)))
        guard want > 64, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: want) else {
            throw AudioAnalyzer.AnalysisError.empty
        }
        file.framePosition = a
        try file.read(into: buf, frameCount: want)
        let n = Int(buf.frameLength)
        guard n > 64, let ch = buf.floatChannelData else { throw AudioAnalyzer.AnalysisError.empty }
        var mono = [Float](repeating: 0, count: n)
        let cc = Int(format.channelCount)
        mono.withUnsafeMutableBufferPointer { m in
            for c in 0..<cc { vDSP_vadd(m.baseAddress!, 1, ch[c], 1, m.baseAddress!, 1, vDSP_Length(n)) }
        }
        var y = try AudioAnalyzer.resample(mono, from: sr)
        var peak: Float = 0
        vDSP_maxmgv(y, 1, &peak, vDSP_Length(y.count))
        if peak > 1e-9 {
            var g = 1 / peak
            y.withUnsafeMutableBufferPointer { p in vDSP_vsmul(p.baseAddress!, 1, &g, p.baseAddress!, 1, vDSP_Length(p.count)) }
        }
        return (y, toEnd)
    }

    // MARK: - Features

    private static func frames(_ x: [Float]) -> (flux: [Float], low: [Float], centroid: [Float], flatness: [Float], rms: [Float]) {
        let n = fftN, half = n / 2
        let binHz = Float(rate) / Float(n)
        let lowBins = max(2, Int(200 / binHz))
        var prev = [Float](repeating: 0, count: half)
        var cur = [Float](repeating: 0, count: half)
        var scaled = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        var logp = [Float](repeating: 0, count: half)
        var freqs = [Float](repeating: 0, count: half)
        for k in 0..<half { freqs[k] = Float(k) * binHz }
        var flux: [Float] = [], low: [Float] = [], cent: [Float] = [], flat: [Float] = []
        let count = x.count / hop + 1
        flux.reserveCapacity(count); low.reserveCapacity(count); cent.reserveCapacity(count); flat.reserveCapacity(count)
        var gain = Float(400.0 / Double(n))
        var halfCount = Int32(half)
        AudioAnalyzer.stft(x, n: n, hop: hop) { t, mag in
            vDSP_vsmul(mag, 1, &gain, &scaled, 1, vDSP_Length(half))
            vvlog1pf(&cur, scaled, &halfCount)
            var f: Float = 0, lf: Float = 0
            if t > 0 {
                for k in 1..<half {
                    let d = cur[k] - prev[k]
                    if d > 0 { f += d; if k <= lowBins { lf += d } }
                }
            }
            flux.append(f); low.append(lf)
            prev = cur
            vDSP_vsq(mag, 1, &power, 1, vDSP_Length(half))
            var tot: Float = 0, wsum: Float = 0
            vDSP_sve(power, 1, &tot, vDSP_Length(half))
            vDSP_dotpr(power, 1, freqs, 1, &wsum, vDSP_Length(half))
            cent.append(tot > 1e-10 ? wsum / tot / Float(rate / 2) : 0)
            // flatness over 100 Hz–8 kHz
            let k0 = 3, k1 = min(half, Int(8000 / binHz))
            var eps: Float = 1e-10
            var addEps = power
            vDSP_vsadd(power, 1, &eps, &addEps, 1, vDSP_Length(half))
            var cnt = Int32(k1 - k0)
            addEps.withUnsafeBufferPointer { src in
                logp.withUnsafeMutableBufferPointer { dst in vvlogf(dst.baseAddress! + k0, src.baseAddress! + k0, &cnt) }
            }
            var lm: Float = 0, am: Float = 0
            vDSP_meanv(Array(logp[k0..<k1]), 1, &lm, vDSP_Length(k1 - k0))
            vDSP_meanv(Array(addEps[k0..<k1]), 1, &am, vDSP_Length(k1 - k0))
            flat.append(am > 1e-9 ? min(1, exp(lm) / am) : 0)
        }
        // RMS per frame (window 2·hop centred on the frame).
        var rms = [Float](repeating: 0, count: flux.count)
        x.withUnsafeBufferPointer { p in
            for t in 0..<flux.count {
                let c = t * hop, lo = max(0, c - hop), hi = min(x.count, c + hop)
                guard hi > lo else { continue }
                var ms: Float = 0
                vDSP_measqv(p.baseAddress! + lo, 1, &ms, vDSP_Length(hi - lo))
                rms[t] = ms.squareRoot()
            }
        }
        func norm(_ a: [Float], pct: Double) -> [Float] {
            let sorted = a.filter { $0 > 0 }.sorted()
            guard !sorted.isEmpty else { return a }
            let ref = max(1e-9, sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * pct))])
            return a.map { min(1, $0 / ref) }
        }
        return (norm(flux, pct: 0.995), norm(low, pct: 0.995), cent, flat, norm(rms, pct: 1))
    }

    private static func chromagram(_ x: [Float]) -> [[Float]] {
        let n = chromaN, half = n / 2
        let binHz = rate / Double(n)
        var bins: [Int] = [], pcs: [Int] = [], weights: [Float] = []
        for k in 1..<half {
            let hz = Double(k) * binHz
            guard hz >= 55, hz <= 4000 else { continue }
            let midi = 69 + 12 * log2(hz / 440)
            let m = Int(midi.rounded())
            let c = cos(Double.pi * (midi - Double(m)))
            bins.append(k); pcs.append(((m % 12) + 12) % 12); weights.append(Float(c * c))
        }
        var out: [[Float]] = []
        AudioAnalyzer.stft(x, n: n, hop: chromaHop) { _, mag in
            var e = [Float](repeating: 0, count: 12)
            for j in 0..<bins.count { let a = mag[bins[j]]; e[pcs[j]] += weights[j] * a * a }
            out.append(e.map { log1p($0) })
        }
        return out
    }

    /// Flux peaks: local max within ±30 ms, above the local mean (−100/+70 ms) + δ, the strongest kept ≥ 50 ms apart.
    /// Strength = peak ÷ the 90th percentile of all peaks (clipped to 1), so one huge hit doesn't flatten the rest.
    private static func pickOnsets(_ f: [Float], fps: Double, start: Double) -> [Onset] {
        let n = f.count
        guard n > 8 else { return [] }
        let delta: Float = 0.04
        let half = max(1, Int(0.03 * fps)), pre = max(1, Int(0.10 * fps)), post = max(1, Int(0.07 * fps))
        var prefix = [Float](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + f[i] }
        var cands: [(Int, Float)] = []
        for t in 1..<(n - 1) {
            let v = f[t]
            guard v >= delta else { continue }
            var isMax = true
            for j in max(0, t - half)...min(n - 1, t + half) where f[j] > v || (f[j] == v && j < t) { isMax = false; break }
            guard isMax else { continue }
            let a = max(0, t - pre), b = min(n, t + post + 1)
            if v >= (prefix[b] - prefix[a]) / Float(b - a) + delta { cands.append((t, v)) }
        }
        let gap = max(1, Int(0.05 * fps))
        var blocked = [Bool](repeating: false, count: n)
        var kept: [(Int, Float)] = []
        for c in cands.sorted(by: { $0.1 > $1.1 }) where !blocked[c.0] {
            kept.append(c)
            for j in max(0, c.0 - gap + 1)...min(n - 1, c.0 + gap - 1) { blocked[j] = true }
        }
        let vals = kept.map(\.1).sorted()
        let ref = vals.isEmpty ? 1 : max(1e-6, vals[min(vals.count - 1, Int(Double(vals.count - 1) * 0.9))])
        return kept.sorted { $0.0 < $1.0 }.map { Onset(t: start + Double($0.0) / fps, s: min(1, $0.1 / ref)) }
    }
}

/// Sample-accurate zero crossings at the file's own rate (the 22 kHz analysis copy is too coarse for click-free cuts).
enum ZeroCross {
    /// Each time moved to the nearest zero crossing of the mono mix: the closest one up to `back` before it, else up
    /// to `fwd` after it, else unchanged.
    static func refine(url: URL, times: [Double], back: Double = 0.0025, fwd: Double = 0.001) -> [Double] {
        guard let file = try? AVAudioFile(forReading: url) else { return times }
        let sr = file.processingFormat.sampleRate
        return times.map { t in
            guard let w = window(file, t: t, before: back, after: fwd) else { return t }
            let c = Int(((t - w.t0) * sr).rounded())
            var best: Int? = nil
            for i in stride(from: min(c, w.x.count - 2), through: 1, by: -1) where crosses(w.x, i) { best = i; break }
            if best == nil { for i in max(1, c)..<(w.x.count - 1) where crosses(w.x, i) { best = i; break } }
            guard let b = best else { return t }
            return w.t0 + Double(b) / sr
        }
    }

    /// Whether `t` sits on a zero crossing (sign change within ±1 sample, or |x| below 0.5 % of full scale).
    static func check(url: URL, times: [Double]) -> [Bool] {
        guard let file = try? AVAudioFile(forReading: url) else { return times.map { _ in false } }
        let sr = file.processingFormat.sampleRate
        return times.map { t in
            guard let w = window(file, t: t, before: 0.0005, after: 0.0005) else { return false }
            let c = max(1, min(w.x.count - 2, Int(((t - w.t0) * sr).rounded())))
            return crosses(w.x, c) || crosses(w.x, c + 1) || abs(w.x[c]) < 0.005
        }
    }

    private static func crosses(_ x: [Float], _ i: Int) -> Bool { (x[i - 1] <= 0 && x[i] >= 0) || (x[i - 1] >= 0 && x[i] <= 0) }

    private static func window(_ file: AVAudioFile, t: Double, before: Double, after: Double) -> (x: [Float], t0: Double)? {
        let sr = file.processingFormat.sampleRate
        let a = max(0, AVAudioFramePosition(((t - before) * sr).rounded(.down)))
        let n = AVAudioFrameCount(max(4, Int((before + after) * sr) + 2))
        guard a < file.length, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n) else { return nil }
        file.framePosition = a
        guard (try? file.read(into: buf, frameCount: min(n, AVAudioFrameCount(file.length - a)))) != nil,
              buf.frameLength > 3, let ch = buf.floatChannelData else { return nil }
        let len = Int(buf.frameLength)
        var x = [Float](repeating: 0, count: len)
        for c in 0..<Int(file.processingFormat.channelCount) { for i in 0..<len { x[i] += ch[c][i] } }
        return (x, Double(a) / sr)
    }
}
