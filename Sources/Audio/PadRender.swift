import Foundation
import AVFoundation
import Accelerate

// Offline rendering of the pad editor's controls (PadParams) into a pad's buffer. Runs on the loader queue when a
// bank loads or one pad's params change (`AudioEngine.rerender`). Order: reverse → key shift / time stretch
// (AVAudioUnitTimePitch in an offline engine, pitch and length independent) → filter (4-pole Butterworth LP or HP)
// → attack / release fades → level. The untouched slice stays in `PadAudio.raw` for the next change.

extension AudioEngine {

    enum PadRender {
        /// `raw` itself when nothing changes the audio; otherwise a new buffer.
        static func render(_ raw: AVAudioPCMBuffer, _ p: PadParams) -> AVAudioPCMBuffer {
            guard !p.isNeutral, raw.frameLength > 0, let first = copy(raw, reversed: p.reverse) else { return raw }
            var buf = first
            if p.needsTimePitch {
                if let tp = timePitch(buf, semitones: p.keyShift, rate: p.stretch) { buf = tp } else {
                    DebugLog.event("audio_error", ["where": "pad_timepitch", "key": p.keyShift, "stretch": p.stretch])
                }
            }
            if abs(p.filter) > 0.0005 { filter(buf, p.filter) }
            envelope(buf, attack: p.attack, release: p.release)
            let g = Float(pow(10, p.level / 20))
            if g != 1 { scale(buf, g) }
            return buf
        }

        // MARK: Steps

        static func copy(_ src: AVAudioPCMBuffer, reversed: Bool) -> AVAudioPCMBuffer? {
            let n = Int(src.frameLength)
            guard let out = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: AVAudioFrameCount(n)),
                  let s = src.floatChannelData, let d = out.floatChannelData else { return nil }
            out.frameLength = AVAudioFrameCount(n)
            for c in 0..<Int(src.format.channelCount) {
                if reversed {
                    for i in 0..<n { d[c][i] = s[c][n - 1 - i] }
                } else {
                    memcpy(d[c], s[c], n * MemoryLayout<Float>.size)
                }
            }
            return out
        }

        /// Pitch (cents) and speed independently through AVAudioUnitTimePitch, rendered offline. The unit's latency
        /// is trimmed off the front so the sound still starts on the hit; the output is `frames / rate` long.
        static func timePitch(_ src: AVAudioPCMBuffer, semitones: Int, rate: Double) -> AVAudioPCMBuffer? {
            let fmt = src.format
            let n = Int(src.frameLength)
            let r = min(2, max(0.5, rate))
            let want = max(1, Int((Double(n) / r).rounded()))
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let tp = AVAudioUnitTimePitch()
            let chunk: AVAudioFrameCount = 4096
            do {
                try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: chunk)
                engine.attach(player)
                engine.attach(tp)
                try engine.crateConnect(player, to: tp, format: fmt)
                try engine.crateConnect(tp, to: engine.mainMixerNode, format: fmt)
                tp.pitch = Float(semitones * 100)
                tp.rate = Float(r)
                engine.prepare()
                try engine.start()
            } catch {
                DebugLog.event("audio_error", ["where": "pad_timepitch_setup", "error": "\(error)"])
                return nil
            }
            defer { player.stop(); engine.stop() }
            player.scheduleBuffer(src, at: nil, options: [], completionHandler: nil)
            do { try player.cratePlay() } catch { return nil }
            let lat = tp.latency.isFinite ? max(0, tp.latency) : 0
            let skip = Int((lat * fmt.sampleRate).rounded())
            guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(want)),
                  let tmp = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk),
                  let od = out.floatChannelData else { return nil }
            let ch = Int(fmt.channelCount)
            var rendered = 0, written = 0
            let total = skip + want
            while rendered < total {
                let ask = AVAudioFrameCount(min(Int(chunk), total - rendered))
                let status: AVAudioEngineManualRenderingStatus
                do { status = try engine.renderOffline(ask, to: tmp) } catch { return nil }
                guard status == .success, let td = tmp.floatChannelData else { return nil }
                let got = Int(tmp.frameLength)
                if got == 0 { break }
                let from = max(0, skip - rendered)
                if from < got {
                    let k = min(got - from, want - written)
                    for c in 0..<ch { memcpy(od[c] + written, td[min(c, Int(tmp.format.channelCount) - 1)] + from, k * MemoryLayout<Float>.size) }
                    written += k
                }
                rendered += got
            }
            guard written > 32 else { return nil }
            out.frameLength = AVAudioFrameCount(written)
            // The phase vocoder smears the very first / last milliseconds: keep the ends click-free.
            edgeFade(out, frames: min(written / 8, Int(0.002 * fmt.sampleRate)))
            return out
        }

        /// 4-pole Butterworth (two RBJ biquads): low-pass for f < 0, high-pass for f > 0.
        static func filter(_ buf: AVAudioPCMBuffer, _ f: Double) {
            let sr = buf.format.sampleRate
            let n = Int(buf.frameLength)
            guard n > 0, let d = buf.floatChannelData else { return }
            let low = f < 0
            let f0 = min(0.45 * sr, low ? PadParams.lowPassHz(f) : PadParams.highPassHz(f))
            var coeffs: [Double] = []
            for q in [0.54119610, 1.3065630] { coeffs += biquad(lowPass: low, f0: f0, q: q, sr: sr) }
            guard let setup = vDSP_biquad_CreateSetup(coeffs, 2) else { return }
            defer { vDSP_biquad_DestroySetup(setup) }
            var tmp = [Float](repeating: 0, count: n)
            for c in 0..<Int(buf.format.channelCount) {
                var delay = [Float](repeating: 0, count: 2 * 2 + 2)
                tmp.withUnsafeMutableBufferPointer { t in
                    vDSP_biquad(setup, &delay, d[c], 1, t.baseAddress!, 1, vDSP_Length(n))
                    memcpy(d[c], t.baseAddress!, n * MemoryLayout<Float>.size)
                }
            }
        }

        /// RBJ cookbook biquad, normalized: [b0, b1, b2, a1, a2].
        static func biquad(lowPass: Bool, f0: Double, q: Double, sr: Double) -> [Double] {
            let w0 = 2 * Double.pi * f0 / sr
            let cw = cos(w0), alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha
            let b0 = lowPass ? (1 - cw) / 2 : (1 + cw) / 2
            let b1 = lowPass ? 1 - cw : -(1 + cw)
            return [b0 / a0, b1 / a0, b0 / a0, -2 * cw / a0, (1 - alpha) / a0]
        }

        /// Attack: linear fade-in. Release: a curved fade-out (gain = x², x = distance from the end / release).
        static func envelope(_ buf: AVAudioPCMBuffer, attack: Double, release: Double) {
            let sr = buf.format.sampleRate
            let n = Int(buf.frameLength)
            guard n > 1, let d = buf.floatChannelData else { return }
            let a = min(n, Int((max(0, attack) * sr).rounded()))
            let r = min(n, Int((max(0, release) * sr).rounded()))
            guard a > 1 || r > 1 else { return }
            for c in 0..<Int(buf.format.channelCount) {
                if a > 1 { for i in 0..<a { d[c][i] *= Float(i) / Float(a) } }
                if r > 1 {
                    for i in 0..<r {
                        let x = Float(i) / Float(r)
                        d[c][n - 1 - i] *= x * x
                    }
                }
            }
        }

        static func scale(_ buf: AVAudioPCMBuffer, _ g: Float) {
            guard let d = buf.floatChannelData else { return }
            var gain = g
            for c in 0..<Int(buf.format.channelCount) { vDSP_vsmul(d[c], 1, &gain, d[c], 1, vDSP_Length(buf.frameLength)) }
        }

        static func edgeFade(_ buf: AVAudioPCMBuffer, frames f: Int) {
            let n = Int(buf.frameLength)
            guard f > 1, n > 2 * f, let d = buf.floatChannelData else { return }
            for c in 0..<Int(buf.format.channelCount) {
                for i in 0..<f {
                    let g = Float(i) / Float(f)
                    d[c][i] *= g
                    d[c][n - 1 - i] *= g
                }
            }
        }

        // MARK: Measurements (debug log / self-test)

        /// RMS over frames [a, b) across channels.
        static func rms(_ buf: AVAudioPCMBuffer, _ a: Int, _ b: Int) -> Double {
            let n = Int(buf.frameLength)
            let lo = max(0, min(n, a)), hi = max(lo, min(n, b))
            guard hi > lo, let d = buf.floatChannelData else { return 0 }
            var sum: Double = 0
            let ch = Int(buf.format.channelCount)
            for c in 0..<ch {
                var ms: Float = 0
                vDSP_measqv(d[c] + lo, 1, &ms, vDSP_Length(hi - lo))
                sum += Double(ms)
            }
            return (sum / Double(ch)).squareRoot()
        }

        static func peak(_ buf: AVAudioPCMBuffer) -> (value: Double, at: Double) {
            let n = Int(buf.frameLength)
            guard n > 0, let d = buf.floatChannelData else { return (0, 0) }
            var best: Float = 0
            var at = 0
            for c in 0..<Int(buf.format.channelCount) {
                var m: Float = 0
                var i: vDSP_Length = 0
                vDSP_maxmgvi(d[c], 1, &m, &i, vDSP_Length(n))
                if m > best { best = m; at = Int(i) }
            }
            return (Double(best), Double(at) / Double(n))
        }

        /// Zero crossings per second on channel 0 (a pitch proxy for pure tones).
        static func zeroCrossingRate(_ buf: AVAudioPCMBuffer, from a: Int = 0, to b: Int? = nil) -> Double {
            let n = Int(buf.frameLength)
            let hi = min(n, b ?? n), lo = max(0, min(hi, a))
            guard hi - lo > 2, let d = buf.floatChannelData else { return 0 }
            var count = 0
            for i in (lo + 1)..<hi where (d[0][i - 1] < 0) != (d[0][i] < 0) { count += 1 }
            return Double(count) / (Double(hi - lo) / buf.format.sampleRate)
        }

        /// First frame whose |x| passes `threshold` (seconds), or nil.
        static func onset(_ buf: AVAudioPCMBuffer, threshold: Float) -> Double? {
            let n = Int(buf.frameLength)
            guard let d = buf.floatChannelData else { return nil }
            for i in 0..<n where abs(d[0][i]) > threshold { return Double(i) / buf.format.sampleRate }
            return nil
        }

        /// Level / energy summary for the debug log: rms, peak, and the first / last 10 ms.
        static func stats(_ buf: AVAudioPCMBuffer) -> [String: Any] {
            let n = Int(buf.frameLength)
            let w = max(1, Int(0.010 * buf.format.sampleRate))
            let pk = peak(buf)
            func r(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
            return ["frames": n, "dur": r(Double(n) / buf.format.sampleRate), "rms": r(rms(buf, 0, n)),
                    "peak": r(pk.value), "peakAt": r(pk.at), "head": r(rms(buf, 0, w)), "tail": r(rms(buf, n - w, n))]
        }
    }
}
