import Foundation
import AVFoundation
import Accelerate

/// Tempo, key and chop points detected on-device for any imported song (see `AudioAnalyzer.analyze`).
/// All times are absolute seconds in the file (they already include `start`).
struct AudioAnalysis {
    /// Beats per minute, octave-folded into 70–150.
    let bpm: Double
    /// 0…1: how clearly the winning tempo beats its best non-octave rival.
    let bpmConfidence: Double
    /// "A", "F#m", … (sharps, minor = "m" suffix) — the format `Music.parseKey` reads.
    let key: String
    /// 0…1: Krumhansl–Schmuckler correlation strength and margin over the runner-up key.
    let keyConfidence: Double
    /// Detected onsets, ascending, ≥ 70 ms apart.
    let onsetsSec: [Double]
    /// 16 strictly ascending slice starts: equal divisions of the analysed span, each snapped to an onset within 40 ms.
    let slices16Sec: [Double]
}

/// On-device audio analysis (Foundation + AVFoundation + Accelerate only; no UI, no shared state, thread-safe).
/// Blocking — call it off the main thread. Analyses at most 60 s from `start`: mono, resampled to 22 050 Hz.
///   • onsets: STFT (Hann 1024, hop 256) → half-wave-rectified log-magnitude spectral flux → local-max peaks over an
///     adaptive (moving-mean) threshold, ≥ 70 ms apart.
///   • tempo: autocorrelation of the flux envelope, harmonic-summed over 1–4 beat periods for 60–180 BPM, weighted by a
///     log-Gaussian prior at 110 BPM, octave-folded into 70–150 BPM.
///   • key: chroma from an 8192-point STFT (55 Hz–4 kHz, cos²-weighted semitone bins, log-compressed per frame), averaged
///     over time → Krumhansl–Schmuckler major/minor profile correlation.
///   • slices: 16 equal divisions of the analysed span, each snapped to the nearest onset within 40 ms.
/// Cost: roughly 0.1–0.2 s for a 3-minute MP3 on an M-series Mac (decode of 60 s dominates).
enum AudioAnalyzer {
    enum AnalysisError: Error { case empty, conversionFailed }

    static func knob(_ k: String, _ d: Double) -> Double { Double(AppConfig.devEnv(k) ?? "") ?? d }
    static let sampleRate: Double = 22050
    static let maxSeconds: Double = 60

    static func analyze(url: URL, start: Double = 0, duration: Double? = nil) throws -> AudioAnalysis {
        let (signal, spanStart) = try loadMono(url: url, start: start, duration: duration)
        let spanSec = Double(signal.count) / sampleRate
        let fps = sampleRate / Double(onsetHop)
        let flux = spectralFlux(signal)
        let onsets = pickOnsets(flux, fps: fps).map { spanStart + $0 }
        let tempo = estimateTempo(flux, fps: fps)
        let key = estimateKey(signal)
        let slices = sliceStarts(spanStart: spanStart, spanSec: spanSec, onsets: onsets)
        return AudioAnalysis(bpm: tempo.bpm, bpmConfidence: tempo.confidence, key: key.name, keyConfidence: key.confidence,
                             onsetsSec: onsets, slices16Sec: slices)
    }

    // MARK: - Decode

    /// Reads [start, start + min(duration, 60 s)] → mono → 22 050 Hz → peak-normalised. Returns the span start actually used.
    private static func loadMono(url: URL, start: Double, duration: Double?) throws -> (samples: [Float], startSec: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat // deinterleaved Float32 at the file's rate
        let fileRate = format.sampleRate
        let length = file.length
        guard fileRate > 0, length > 0 else { throw AnalysisError.empty }
        let startFrame = min(max(0, AVAudioFramePosition((start.isFinite ? start : 0) * fileRate)), length)
        var span = min(Double(length - startFrame) / fileRate, maxSeconds)
        if let d = duration, d.isFinite, d > 0 { span = min(span, d) }
        let want = AVAudioFrameCount(max(0, (span * fileRate).rounded(.down)))
        guard want > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: want) else { throw AnalysisError.empty }
        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: want)
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { throw AnalysisError.empty }
        var mono = [Float](repeating: 0, count: frames)
        let channelCount = Int(format.channelCount)
        mono.withUnsafeMutableBufferPointer { m in
            guard let p = m.baseAddress else { return }
            for c in 0..<channelCount { vDSP_vadd(p, 1, channels[c], 1, p, 1, vDSP_Length(frames)) }
        }
        var samples = try resample(mono, from: fileRate)
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        if peak > 1e-9 {
            var gain = 1 / peak
            samples.withUnsafeMutableBufferPointer { s in
                guard let p = s.baseAddress else { return }
                vDSP_vsmul(p, 1, &gain, p, 1, vDSP_Length(s.count))
            }
        }
        return (samples, Double(startFrame) / fileRate)
    }

    static func resample(_ x: [Float], from rate: Double) throws -> [Float] {
        if abs(rate - sampleRate) < 0.5 { return x }
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(x.count)),
              let inData = input.floatChannelData else { throw AnalysisError.conversionFailed }
        input.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { inData[0].update(from: base, count: x.count) }
        }
        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        var out: [Float] = []
        out.reserveCapacity(Int(Double(x.count) * sampleRate / rate) + 1024)
        var fed = false
        let chunk: AVAudioFrameCount = 1 << 16
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk) else { throw AnalysisError.conversionFailed }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if fed { inputStatus.pointee = .endOfStream; return nil }
                fed = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error { throw error ?? AnalysisError.conversionFailed }
            let got = Int(output.frameLength)
            if got > 0, let data = output.floatChannelData {
                out.append(contentsOf: UnsafeBufferPointer(start: data[0], count: got))
            }
            if status == .endOfStream || got == 0 { break }
        }
        guard !out.isEmpty else { throw AnalysisError.conversionFailed }
        return out
    }

    // MARK: - STFT

    /// Hann-windowed, centre-padded STFT (frame t is centred on sample t·hop). Calls `body(t, |X[0..<n/2]|)` per frame.
    static func stft(_ x: [Float], n: Int, hop: Int, _ body: (Int, UnsafePointer<Float>) -> Void) {
        let half = n / 2
        let log2n = vDSP_Length(log2(Double(n)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }
        defer { vDSP_destroy_fftsetup(setup) }
        var padded = [Float](repeating: 0, count: x.count + n)
        padded.replaceSubrange(half..<(half + x.count), with: x)
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let frame = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let re = UnsafeMutablePointer<Float>.allocate(capacity: half)
        let im = UnsafeMutablePointer<Float>.allocate(capacity: half)
        let mag = UnsafeMutablePointer<Float>.allocate(capacity: half)
        defer { frame.deallocate(); re.deallocate(); im.deallocate(); mag.deallocate() }
        var split = DSPSplitComplex(realp: re, imagp: im)
        let frames = x.count / hop + 1
        padded.withUnsafeBufferPointer { p in
            window.withUnsafeBufferPointer { w in
                guard let src = p.baseAddress, let win = w.baseAddress else { return }
                for t in 0..<frames {
                    let offset = t * hop
                    guard offset + n <= p.count else { break }
                    vDSP_vmul(src + offset, 1, win, 1, frame, 1, vDSP_Length(n))
                    frame.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    im[0] = 0 // imagp[0] packs Nyquist; keep bin 0 = DC only
                    vDSP_zvabs(&split, 1, mag, 1, vDSP_Length(half))
                    body(t, mag)
                }
            }
        }
    }

    // MARK: - Onsets

    private static let onsetFrame = 1024
    private static let onsetHop = 256

    /// Half-wave-rectified spectral flux of log(1 + γ|X|), one value per STFT frame (≈ 86 fps).
    private static func spectralFlux(_ x: [Float]) -> [Float] {
        let n = onsetFrame, half = n / 2
        let scaled = UnsafeMutablePointer<Float>.allocate(capacity: half)
        let cur = UnsafeMutablePointer<Float>.allocate(capacity: half)
        let prev = UnsafeMutablePointer<Float>.allocate(capacity: half)
        let diff = UnsafeMutablePointer<Float>.allocate(capacity: half)
        defer { scaled.deallocate(); cur.deallocate(); prev.deallocate(); diff.deallocate() }
        prev.initialize(repeating: 0, count: half)
        var gain = Float(400.0 / Double(n)) // |X| of a full-scale sine ≈ n/4 → log1p(100)
        var zero: Float = 0
        var count = Int32(half)
        var flux: [Float] = []
        flux.reserveCapacity(x.count / onsetHop + 1)
        stft(x, n: n, hop: onsetHop) { t, mag in
            vDSP_vsmul(mag, 1, &gain, scaled, 1, vDSP_Length(half))
            vvlog1pf(cur, scaled, &count)
            var sum: Float = 0
            if t > 0 {
                vDSP_vsub(prev, 1, cur, 1, diff, 1, vDSP_Length(half)) // diff = cur − prev
                vDSP_vthres(diff, 1, &zero, diff, 1, vDSP_Length(half)) // negatives → 0
                vDSP_sve(diff + 1, 1, &sum, vDSP_Length(half - 1))      // skip DC
            }
            flux.append(sum)
            prev.update(from: cur, count: half)
        }
        return flux
    }

    /// Peak-picks the flux (normalised to its max): local max within ±35 ms, above the local mean (−100/+70 ms) + δ,
    /// then keeps the strongest peaks ≥ 70 ms apart. Returns seconds relative to the span start.
    private static func pickOnsets(_ flux: [Float], fps: Double) -> [Double] {
        let n = flux.count
        guard n > 4, let top = flux.max(), top > 0 else { return [] }
        let f = flux.map { $0 / top }
        let delta: Float = 0.05
        let halfMax = max(1, Int((0.035 * fps).rounded()))
        let preAvg = max(1, Int((0.10 * fps).rounded())), postAvg = max(1, Int((0.07 * fps).rounded()))
        var prefix = [Float](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + f[i] }
        var candidates: [(t: Int, v: Float)] = []
        for t in 1..<n {
            let v = f[t]
            guard v >= delta else { continue }
            var isMax = true
            for j in max(0, t - halfMax)...min(n - 1, t + halfMax) where f[j] > v || (f[j] == v && j < t) {
                isMax = false
                break
            }
            guard isMax else { continue }
            let a = max(0, t - preAvg), b = min(n, t + postAvg + 1)
            let mean = (prefix[b] - prefix[a]) / Float(b - a)
            if v >= mean + delta { candidates.append((t, v)) }
        }
        let gap = max(1, Int((0.07 * fps).rounded(.up)))
        var blocked = [Bool](repeating: false, count: n)
        var kept: [Int] = []
        for c in candidates.sorted(by: { $0.v > $1.v }) where !blocked[c.t] {
            kept.append(c.t)
            for j in max(0, c.t - gap + 1)...min(n - 1, c.t + gap - 1) { blocked[j] = true }
        }
        return kept.sorted().map { Double($0) / fps }
    }

    // MARK: - Tempo

    static func estimateTempo(_ flux: [Float], fps: Double) -> (bpm: Double, confidence: Double) {
        let n = flux.count
        let minBpm = 60.0, maxBpm = 180.0
        let minPeriod = 60 * fps / maxBpm, maxPeriod = 60 * fps / minBpm
        guard n > Int(minPeriod * 3) else { return (90, 0) }
        // Remove the local mean (±0.25 s) and half-wave rectify → a clean pulse train; then zero-mean it.
        let w = max(1, Int(0.25 * fps))
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + Double(flux[i]) }
        var e = [Double](repeating: 0, count: n)
        for t in 0..<n {
            let a = max(0, t - w), b = min(n, t + w + 1)
            e[t] = max(0, Double(flux[t]) - (prefix[b] - prefix[a]) / Double(b - a))
        }
        let mean = e.reduce(0, +) / Double(n)
        for t in 0..<n { e[t] -= mean }
        // Unbiased autocorrelation up to 4 beat periods of 60 BPM (or 2/3 of the envelope for short loops).
        let maxLag = max(Int(minPeriod) + 2, min(n - 1, Int(maxPeriod * knob("T_H", 4)) + 2, n * 2 / 3))
        var r = [Double](repeating: 0, count: maxLag + 1)
        e.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            for lag in 0...maxLag {
                var s = 0.0
                vDSP_dotprD(base, 1, base + lag, 1, &s, vDSP_Length(n - lag))
                r[lag] = s / Double(n - lag)
            }
        }
        guard r[0] > 1e-12 else { return (90, 0) }
        let r0 = r[0]
        for i in r.indices { r[i] /= r0 }
        func acf(_ lag: Double) -> Double {
            let i = Int(lag), frac = lag - Double(i)
            guard i + 1 < r.count else { return r[r.count - 1] }
            return r[i] * (1 - frac) + r[i + 1] * frac
        }
        var bpms: [Double] = [], raw: [Double] = [], scores: [Double] = []
        var bpm = minBpm
        while bpm <= maxBpm + 1e-9 {
            let period = 60 * fps / bpm
            var s = 0.0, k = 0.0
            for h in 1...Int(knob("T_H", 4)) {
                let lag = Double(h) * period
                if lag > Double(maxLag - 1) { break }
                s += acf(lag)
                k += 1
            }
            let avg = k > 0 ? s / k : 0
            let octaves = log2(bpm / 110) / 1.0
            bpms.append(bpm)
            raw.append(avg)
            scores.append(max(0, avg) * exp(-0.5 * octaves * octaves))
            bpm += 0.1
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] > 0 else { return (90, 0) }
        var tempo = bpms[best]
        // Prominence: margin over the strongest candidate that is not the same tempo or an octave of it.
        var rival = 0.0
        for i in scores.indices where scores[i] > rival {
            let ratio = bpms[i] / tempo
            if ![0.5, 1, 2].contains(where: { abs(ratio / $0 - 1) < 0.06 }) { rival = scores[i] }
        }
        let prominence = 1 - rival / scores[best]
        let strength = min(1, max(0, raw[best]) / 0.25)
        while tempo < 70 { tempo *= 2 }
        while tempo > 150 { tempo /= 2 }
        return ((tempo * 10).rounded() / 10, min(1, max(0, prominence * strength)))
    }

    // MARK: - Key

    private static let chromaFrame = 8192
    private static let chromaHop = 4096
    static let pitchNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func estimateKey(_ x: [Float]) -> (name: String, confidence: Double) {
        let n = chromaFrame, half = n / 2
        let binHz = sampleRate / Double(n)
        let lowMidi = Int(knob("K_LO", 33)), highMidi = Int(knob("K_HI", 107)) // A1 55 Hz … ≈ 4 kHz
        let pitches = highMidi - lowMidi + 1
        var bins: [Int] = [], binPitch: [Int] = [], binWeight: [Float] = []
        for k in 1..<half {
            let hz = Double(k) * binHz
            guard hz >= 30, hz <= 8000 else { continue }
            let midi = 69 + 12 * log2(hz / 440)
            let m = Int(midi.rounded())
            guard m >= lowMidi, m <= highMidi else { continue }
            let c = cos(Double.pi * (midi - Double(m)))
            bins.append(k)
            binPitch.append(m - lowMidi)
            binWeight.append(Float(c * c))
        }
        // Per-frame semitone energies (kept so quiet frames can be dropped relative to the loudest).
        var frames: [[Float]] = []
        var totals: [Float] = []
        stft(x, n: n, hop: chromaHop) { _, mag in
            var energy = [Float](repeating: 0, count: pitches)
            for j in 0..<bins.count {
                let a = mag[bins[j]]
                energy[binPitch[j]] += binWeight[j] * a * a
            }
            frames.append(energy)
            totals.append(energy.reduce(0, +))
        }
        guard let loudest = totals.max(), loudest > 0 else { return ("C", 0) }
        var chroma = [Double](repeating: 0, count: 12)
        let eta = Float(knob("K_ETA", 100)), hsub = Float(knob("K_HSUB", 0)), mode = Int(knob("K_MODE", 0))
        for (i, energy0) in frames.enumerated() where totals[i] > loudest * 1e-3 {
            var energy = energy0
            if hsub > 0 { for p in stride(from: pitches - 1, through: 0, by: -1) { var sub: Float = 0; if p >= 19 { sub += hsub * energy0[p - 19] }; if p >= 28 { sub += hsub * 0.5 * energy0[p - 28] }; energy[p] = max(0, energy0[p] - sub) } }
            let norm = 1 / totals[i]
            for p in 0..<pitches {
                let v: Double
                switch mode {
                case 1: v = Double(energy[p]).squareRoot()
                case 2: v = Double(energy[p])
                case 3: v = Double(energy[p] * norm).squareRoot()
                default: v = Double(log1p(eta * energy[p] * norm))
                }
                chroma[(p + lowMidi) % 12] += v
            }
        }
        guard chroma.contains(where: { $0 > 0 }) else { return ("C", 0) }
        var scored: [(pc: Int, minor: Bool, r: Double)] = []
        for pc in 0..<12 {
            for minor in [false, true] {
                let profile = minor ? minorProfile : majorProfile
                scored.append((pc, minor, pearson(chroma, (0..<12).map { profile[($0 - pc + 12) % 12] })))
            }
        }
        scored.sort { $0.r > $1.r }
        let best = scored[0], second = scored[1].r
        let confidence = min(1, max(0, 0.5 * best.r + 3 * (best.r - second)))
        return (pitchNames[best.pc] + (best.minor ? "m" : ""), confidence)
    }

    static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in a.indices {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y
            da += x * x
            db += y * y
        }
        return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
    }

    // MARK: - Slices

    private static func sliceStarts(spanStart: Double, spanSec: Double, onsets: [Double]) -> [Double] {
        var out: [Double] = []
        var j = 0
        for i in 0..<16 {
            let t = spanStart + spanSec * Double(i) / 16
            while j + 1 < onsets.count && onsets[j + 1] <= t { j += 1 }
            var s = t
            var bestDist = 0.04
            for c in [j, j + 1] where c < onsets.count && abs(onsets[c] - t) <= bestDist {
                bestDist = abs(onsets[c] - t)
                s = onsets[c]
            }
            if let last = out.last, s <= last { s = max(t, last + 0.001) }
            out.append(s)
        }
        return out
    }
}
