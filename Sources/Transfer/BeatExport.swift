import AVFoundation
import Accelerate
import Foundation

/// How much of the beat an export renders.
enum ExportLength: String, CaseIterable, Hashable {
    case loop1, loop4, loop8, bars8

    var label: String {
        switch self {
        case .loop1: return "1×"
        case .loop4: return "4×"
        case .loop8: return "8×"
        case .bars8: return "8 BARS"
        }
    }

    var spoken: String {
        switch self {
        case .loop1: return "1× LOOP"
        case .loop4: return "4× LOOP"
        case .loop8: return "8× LOOP"
        case .bars8: return "8 BARS"
        }
    }

    func steps(loopBars: Int) -> Int {
        let loop = max(1, loopBars) * 16
        switch self {
        case .loop1: return loop
        case .loop4: return loop * 4
        case .loop8: return loop * 8
        case .bars8: return 8 * 16
        }
    }

    /// A single loop wraps its ring-out back to the top (seamless when looped); the others get a short tail.
    var seamless: Bool { self == .loop1 }

    static func parse(_ s: String?) -> ExportLength {
        switch s?.lowercased() {
        case "1", "1x", "loop1": return .loop1
        case "8", "8x", "loop8": return .loop8
        case "8bars", "bars8", "bars": return .bars8
        default: return .loop4
        }
    }
}

enum ExportFormat: String, CaseIterable, Hashable {
    /// AAC 256 kbps in .m4a. (iOS has no MP3 encoder; MP3 would need an LGPL LAME build or a server conversion.)
    case m4a
    /// 24-bit PCM.
    case wav

    var label: String { rawValue.uppercased() }
}

/// Renders the beat offline, much faster than real time, without touching the live engine: the pattern's hits are
/// laid out on a timeline with the sequencer's own rules (swing, offsets, ratchets, note lengths, choke groups,
/// velocity curve, bank gain, MUTE), mixed from the pads' loaded buffers, then run through Apple's PeakLimiter in
/// an offline AVAudioEngine (the live master chain with every FX off) and encoded. No metronome, no count-in.
enum BeatExport {
    struct Snapshot {
        var pattern: Pattern
        var bpm: Double
        var swing: Double
        var audio: [PadID: AudioEngine.PadAudio]
        var muted: Set<PadID>
        var sampleRate: Double
    }

    enum Failure: LocalizedError {
        case noEngine, empty, writer(String)
        var errorDescription: String? {
            switch self {
            case .noEngine: return "Export needs the audio engine."
            case .empty: return "Nothing to export yet: the beat has no hits."
            case .writer(let m): return "Couldn't write the file: \(m)"
            }
        }
    }

    /// Main actor: snapshot, then render + encode off the main thread. `progress` gets 0…1 on the main actor.
    @MainActor
    static func run(state: AppState, length: ExportLength, format: ExportFormat,
                    progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        guard let engine = state.engine as? AudioEngine else { throw Failure.noEngine }
        let pattern = engine.pattern
        var audio: [PadID: AudioEngine.PadAudio] = [:]
        for pad in Set(pattern.lanes.keys).union(pattern.notes.keys) {
            if let a = engine.audio(for: pad) { audio[pad] = a }
        }
        let snap = Snapshot(pattern: pattern, bpm: currentBPM(state), swing: engine.swing, audio: audio,
                            muted: state.mutedPads, sampleRate: engine.ensureFormat().sampleRate)
        let name = fileName(project: ProjectStore.shared.currentName, bpm: snap.bpm)
        let t0 = Date()
        let url = try await Task.detached(priority: .userInitiated) {
            try render(snap, length: length, format: format, name: name) { p in
                Task { @MainActor in progress(p) }
            }
        }.value
        let secs = Double(length.steps(loopBars: pattern.bars)) * 15 / snap.bpm
        DebugLog.event("export", ["file": url.lastPathComponent, "len": length.rawValue, "fmt": format.rawValue,
                                  "audio_s": (secs * 10).rounded() / 10,
                                  "ms": Int(Date().timeIntervalSince(t0) * 1000),
                                  "bytes": (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0])
        return url
    }

    /// "CRATE 03 · J DILLA" at 92 BPM → "CRATE 03 J DILLA 92 BPM".
    static func fileName(project: String, bpm: Double) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let clean = String(project.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
            .split(separator: " ").joined(separator: " ")
        return "\(clean.isEmpty ? "CRATE" : String(clean.prefix(60))) \(Int(bpm.rounded())) BPM"
    }

    // MARK: Render (background)

    private struct Voice {
        var pad: PadID
        var t: Double
        var velocity: Int
        var semitones: Double
        var end: Double?
    }

    static func render(_ s: Snapshot, length: ExportLength, format: ExportFormat, name: String,
                       progress: @escaping (Double) -> Void) throws -> URL {
        let sr = s.sampleRate
        let sps = 60 / max(30, s.bpm) / 4
        let loopSteps = max(1, s.pattern.bars) * 16
        let steps = length.steps(loopBars: s.pattern.bars)
        let comp = AudioEngine.CompiledPattern(s.pattern)

        // 1. The timeline, by the sequencer's rules.
        var voices: [Voice] = []
        for step in 0..<steps {
            let swingDelay = step % 2 == 1 ? max(0, 2 * s.swing / 100 - 1) : 0
            for ev in comp.byStep[step % loopSteps] where ev.velocity > 0 && !s.muted.contains(ev.pad) {
                guard let pa = s.audio[ev.pad] else { continue }
                let base = (Double(step) + swingDelay + ev.offset) * sps
                let r = max(1, min(8, ev.ratchet))
                // + the song KEY (pattern transpose), as the sequencer plays it: pitched pads of banks B–D only
                let key = s.pattern.transpose != 0 && ev.pad.bank != .a && pa.sound.category.isPitched ? Double(s.pattern.transpose) : 0
                let semis = semitones(ev, pa) + key
                for k in 0..<r {
                    let t = max(0, base + Double(k) * sps / Double(r))
                    let vel = Int((Double(ev.velocity) * pow(0.85, Double(k))).rounded())
                    voices.append(Voice(pad: ev.pad, t: t, velocity: vel, semitones: semis,
                                        end: ev.length.map { t + max(0.25, $0) * sps }))
                }
            }
        }
        guard !voices.isEmpty else { throw Failure.empty }
        voices.sort { $0.t < $1.t }
        // Choke groups / mono banks: a voice stops where the next event that cuts it starts.
        for i in voices.indices where AudioEngine.canBeCut(voices[i].pad) {
            let v = voices[i]
            if let cut = voices[(i + 1)...].first(where: { $0.t > v.t + 0.004 && AudioEngine.cuts($0.pad, v.pad) })?.t {
                voices[i].end = min(v.end ?? cut, cut)
            }
        }

        // 2. Mix into a stereo timeline.
        let body = Int((Double(steps) * sps * sr).rounded())
        let tailMax = length.seamless ? 0 : Int(2.0 * sr)
        let capacity = body + tailMax
        var left = [Float](repeating: 0, count: capacity + 1)
        var right = [Float](repeating: 0, count: capacity + 1)
        var lastFrame = body
        let fade = max(1, Int(0.012 * sr))
        let every = max(1, voices.count / 20)
        left.withUnsafeMutableBufferPointer { L in
            right.withUnsafeMutableBufferPointer { R in
                for (n, v) in voices.enumerated() {
                    guard let pa = s.audio[v.pad], let data = pa.buffer.floatChannelData else { continue }
                    let rate = min(4, max(0.25, pow(2, v.semitones / 12)))
                    var count = Int(Double(pa.frames) / rate)
                    var fadeN = 0
                    if let e = v.end {
                        let lim = Int(max(0.006, e - v.t) * sr)
                        if lim < count - Int(0.003 * sr) { count = lim; fadeN = min(lim, fade) }
                    }
                    guard count > 0 else { continue }
                    let start = Int((v.t * sr).rounded())
                    let gain = AudioEngine.velocityGain(v.velocity) * AudioEngine.bankGain
                    let chans = Int(pa.buffer.format.channelCount)
                    let srcL = data[0], srcR = data[min(1, chans - 1)]
                    lastFrame = max(lastFrame, min(capacity, start + count))
                    for j in 0..<count {
                        var o = start + j
                        if o >= body {
                            if length.seamless { o -= body; if o >= body { break } } else if o >= capacity { break }
                        }
                        let env: Float = j >= count - fadeN ? Float(count - j) / Float(fadeN) : 1
                        let g = gain * env
                        if rate == 1 {
                            L[o] += srcL[j] * g
                            R[o] += srcR[j] * g
                        } else {
                            let pos = Double(j) * rate
                            let i0 = Int(pos)
                            guard i0 < pa.frames else { break }
                            let i1 = min(i0 + 1, pa.frames - 1)
                            let f = Float(pos - Double(i0))
                            L[o] += (srcL[i0] + (srcL[i1] - srcL[i0]) * f) * g
                            R[o] += (srcR[i0] + (srcR[i1] - srcR[i0]) * f) * g
                        }
                    }
                    if n % every == 0 { progress(0.45 * Double(n) / Double(voices.count)) }
                }
            }
        }
        let total = length.seamless ? body : min(capacity, lastFrame)
        if total > body {   // ring-out tail: fade the last 300 ms
            let f = min(total - body, Int(0.3 * sr))
            for i in 0..<f {
                let k = Float(i) / Float(f)
                left[total - 1 - i] *= k
                right[total - 1 - i] *= k
            }
        }

        // 3. Master: PeakLimiter + master gain in an offline engine, encoded chunk by chunk.
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        guard let mix = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(total + 8192)) else {
            throw Failure.writer("out of memory")
        }
        mix.frameLength = mix.frameCapacity
        memset(mix.floatChannelData![0], 0, Int(mix.frameLength) * 4)
        memset(mix.floatChannelData![1], 0, Int(mix.frameLength) * 4)
        left.withUnsafeBufferPointer { memcpy(mix.floatChannelData![0], $0.baseAddress!, total * 4) }
        right.withUnsafeBufferPointer { memcpy(mix.floatChannelData![1], $0.baseAddress!, total * 4) }
        left = []; right = []

        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        let player = AVAudioPlayerNode()
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        engine.attach(player)
        engine.attach(limiter)
        try engine.crateConnect(player, to: limiter, format: fmt)
        try engine.crateConnect(limiter, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = AudioEngine.masterGain
        try engine.start()
        defer { engine.stop() }
        player.scheduleBuffer(mix, at: nil, options: [], completionHandler: nil)
        try player.cratePlay()
        let skip = max(0, Int((limiter.latency * sr).rounded()))

        let dir = CrateStorage.documents
            .appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name).appendingPathExtension(format.rawValue)
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any]
        switch format {
        case .m4a:
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
                        AVEncoderBitRateKey: 256_000]
        case .wav:
            settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
                        AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch { throw Failure.writer(error.localizedDescription) }

        guard let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else {
            throw Failure.writer("out of memory")
        }
        var rendered = 0
        let goal = total + skip
        while rendered < goal {
            let n = AVAudioFrameCount(min(4096, goal - rendered))
            let status = try engine.renderOffline(n, to: out)
            guard status == .success else { break }
            let got = Int(out.frameLength)
            // drop the limiter's look-ahead so the export starts on the downbeat
            let drop = max(0, min(got, skip - rendered))
            if drop < got {
                if drop > 0 {
                    for c in 0..<2 {
                        let d = out.floatChannelData![c]
                        memmove(d, d + drop, (got - drop) * 4)
                    }
                    out.frameLength = AVAudioFrameCount(got - drop)
                }
                try file.write(from: out)
            }
            rendered += got
            progress(0.45 + 0.55 * Double(rendered) / Double(goal))
        }
        file.close()
        progress(1)
        return url
    }

    /// Same pitch as the sequencer gives a note (pad root, 808 / bass octave-folded).
    private static func semitones(_ ev: AudioEngine.SeqEvent, _ pa: AudioEngine.PadAudio) -> Double {
        guard let midi = ev.midi else { return 0 }
        let root = AudioEngine.rootNote(pa.sound)
        var m = midi
        if pa.sound.category == .eight08 || pa.sound.category == .bass { m = Music.fold(midi, near: root) }
        return Double(max(-36, min(36, m - root)))
    }
}
