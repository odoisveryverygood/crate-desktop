import Foundation
import AVFoundation
import Accelerate

// Sample decoding / conversion / slicing for AudioEngine (Agent A). All types are nested in
// AudioEngine so nothing collides with the other agents' modules.

extension AudioEngine {

    /// Host clock in seconds (mach_absolute_time based, same clock AVAudioTime(hostTime:) uses).
    enum Clock {
        static let tickSeconds: Double = {
            var tb = mach_timebase_info_data_t()
            mach_timebase_info(&tb)
            return Double(tb.numer) / Double(tb.denom) / 1_000_000_000
        }()
        static func now() -> Double { Double(mach_absolute_time()) * tickSeconds }
        static func hostTicks(_ seconds: Double) -> UInt64 { UInt64(max(0, seconds) / tickSeconds) }
    }

    /// A decoded, converted pad buffer (engine format: stereo Float32 deinterleaved at the engine rate).
    final class PadAudio: @unchecked Sendable {
        let sound: PadSound
        /// What plays: `raw` with the pad's params rendered in (the same buffer when they're neutral).
        let buffer: AVAudioPCMBuffer
        /// The untouched slice (gain + edge fades only), kept so a params change re-renders without decoding.
        let raw: AVAudioPCMBuffer
        let frames: Int
        let sampleRate: Double
        /// Peak envelope (0...1) at a fixed resolution, for cheap waveform() calls.
        let envelope: [Float]

        convenience init(sound: PadSound, buffer: AVAudioPCMBuffer) {
            self.init(sound: sound, raw: buffer, rendered: buffer)
        }

        /// Renders `sound.params` into a copy of `raw`.
        convenience init(sound: PadSound, raw: AVAudioPCMBuffer) {
            self.init(sound: sound, raw: raw, rendered: PadRender.render(raw, sound.params))
        }

        init(sound: PadSound, raw: AVAudioPCMBuffer, rendered buffer: AVAudioPCMBuffer) {
            self.sound = sound
            self.raw = raw
            self.buffer = buffer
            self.frames = Int(buffer.frameLength)
            self.sampleRate = buffer.format.sampleRate
            self.envelope = Loader.envelope(buffer, bins: min(1024, max(1, Int(buffer.frameLength))))
        }

        var duration: Double { Double(frames) / sampleRate }

        func waveform(points: Int) -> [Float] {
            guard points > 0 else { return [] }
            if envelope.isEmpty { return [Float](repeating: 0, count: points) }
            if points == envelope.count { return envelope }
            if points > envelope.count { return Loader.envelope(buffer, bins: points) }
            var out = [Float](repeating: 0, count: points)
            let n = envelope.count
            for i in 0..<points {
                let a = i * n / points
                let e = max(a + 1, (i + 1) * n / points)
                var m: Float = 0
                for j in a..<min(e, n) where envelope[j] > m { m = envelope[j] }
                out[i] = m
            }
            return out
        }
    }

    enum LoadError: Error, CustomStringConvertible {
        case empty(String), alloc(String), convert(String)
        var description: String {
            switch self {
            case .empty(let s): return "empty file \(s)"
            case .alloc(let s): return "buffer alloc failed \(s)"
            case .convert(let s): return "convert failed \(s)"
            }
        }
    }

    enum Loader {
        /// Decode every unique file once (in parallel), then cut each pad's slice. Failed files are skipped + logged.
        static func load(_ sounds: [Int: PadSound], format: AVAudioFormat) -> [Int: PadAudio] {
            let urls = Array(Set(sounds.values.map { $0.fileURL.standardizedFileURL }))
            var decoded: [URL: AVAudioPCMBuffer] = [:]
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: urls.count) { i in
                let url = urls[i]
                do {
                    let buf = try decode(url: url, to: format)
                    lock.lock(); decoded[url] = buf; lock.unlock()
                } catch {
                    DebugLog.event("load_error", ["file": url.lastPathComponent, "error": "\(error)"])
                }
            }
            var out: [Int: PadAudio] = [:]
            for (index, sound) in sounds where (0..<16).contains(index) {
                guard let src = decoded[sound.fileURL.standardizedFileURL] else { continue }
                guard let buf = slice(src, start: sound.start, end: sound.end, gain: sound.gain) else {
                    DebugLog.event("load_error", ["file": sound.fileURL.lastPathComponent, "error": "empty slice", "pad": index])
                    continue
                }
                let t0 = Clock.now()
                let pa = PadAudio(sound: sound, raw: buf)
                if !sound.params.isNeutral {
                    var f = PadRender.stats(pa.buffer)
                    f["pad"] = index; f["ms"] = Int(((Clock.now() - t0) * 1000).rounded()); f["params"] = sound.params.summary
                    DebugLog.event("pad_render", f)
                }
                out[index] = pa
            }
            return out
        }

        /// Whole file → engine format (stereo Float32 deinterleaved at format.sampleRate). Mono is duplicated to L+R.
        static func decode(url: URL, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let inFmt = file.processingFormat
            let length = max(0, Int(file.length))
            let name = url.lastPathComponent
            guard length > 0, inFmt.channelCount > 0 else { throw LoadError.empty(name) }
            guard let raw = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(length)),
                  let chunk = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 32768) else { throw LoadError.alloc(name) }
            let ch = Int(inFmt.channelCount)
            var got = 0
            while got < length {
                let want = AVAudioFrameCount(min(32768, length - got))
                do { try file.read(into: chunk, frameCount: want) } catch {
                    if got > 0 { break }   // iOS 27: reading past EOF throws; keep what we have
                    throw error
                }
                let n = Int(chunk.frameLength)
                if n == 0 { break }
                let copy = min(n, length - got)
                for c in 0..<ch {
                    memcpy(raw.floatChannelData![c] + got, chunk.floatChannelData![c], copy * MemoryLayout<Float>.size)
                }
                got += copy
            }
            guard got > 0 else { throw LoadError.empty(name) }
            raw.frameLength = AVAudioFrameCount(got)

            let twoCh = ch > 2 ? try firstTwoChannels(raw) : raw
            let mid = abs(twoCh.format.sampleRate - format.sampleRate) < 0.5 ? twoCh : try resample(twoCh, to: format.sampleRate, name: name)

            let frames = Int(mid.frameLength)
            guard frames > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
                throw LoadError.alloc(name)
            }
            out.frameLength = AVAudioFrameCount(frames)
            let srcCh = Int(mid.format.channelCount)
            for c in 0..<2 {
                memcpy(out.floatChannelData![c], mid.floatChannelData![min(c, srcCh - 1)], frames * MemoryLayout<Float>.size)
            }
            return out
        }

        static func firstTwoChannels(_ src: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
            guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: src.format.sampleRate, channels: 2, interleaved: false),
                  let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: src.frameLength) else { throw LoadError.alloc("downmix") }
            out.frameLength = src.frameLength
            for c in 0..<2 {
                memcpy(out.floatChannelData![c], src.floatChannelData![c], Int(src.frameLength) * MemoryLayout<Float>.size)
            }
            return out
        }

        static func resample(_ src: AVAudioPCMBuffer, to sampleRate: Double, name: String) throws -> AVAudioPCMBuffer {
            guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                             channels: src.format.channelCount, interleaved: false),
                  let conv = AVAudioConverter(from: src.format, to: outFmt) else { throw LoadError.convert(name) }
            conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            let ratio = sampleRate / src.format.sampleRate
            let cap = AVAudioFrameCount(Double(src.frameLength) * ratio + 4096)
            guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { throw LoadError.alloc(name) }
            var fed = false
            var err: NSError?
            let status = conv.convert(to: out, error: &err) { _, inStatus in
                if fed { inStatus.pointee = .endOfStream; return nil }
                fed = true
                inStatus.pointee = .haveData
                return src
            }
            if status == .error || out.frameLength == 0 { throw err ?? LoadError.convert(name) }
            return out
        }

        /// Copy [start, end) seconds out of a decoded file, apply gain and click-free edges.
        static func slice(_ src: AVAudioPCMBuffer, start: Double, end: Double?, gain: Float) -> AVAudioPCMBuffer? {
            let sr = src.format.sampleRate
            let total = Int(src.frameLength)
            let a = min(max(0, Int((max(0, start) * sr).rounded())), total)
            var b = total
            if let e = end, e > start { b = min(total, max(a, Int((e * sr).rounded()))) }
            let n = b - a
            guard n > 32, let out = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: AVAudioFrameCount(n)) else { return nil }
            out.frameLength = AVAudioFrameCount(n)
            let fadeIn = a > 0 ? min(n / 4, Int(0.001 * sr)) : 0
            let fadeOut = min(n / 4, Int((b < total ? 0.004 : 0.002) * sr))
            let g = gain.isFinite ? max(0, gain) : 1
            for c in 0..<Int(src.format.channelCount) {
                let d = out.floatChannelData![c]
                memcpy(d, src.floatChannelData![c] + a, n * MemoryLayout<Float>.size)
                if g != 1 { for i in 0..<n { d[i] *= g } }
                if fadeIn > 0 { for i in 0..<fadeIn { d[i] *= Float(i) / Float(fadeIn) } }
                if fadeOut > 0 { for i in 0..<fadeOut { d[n - 1 - i] *= Float(i) / Float(fadeOut) } }
            }
            return out
        }

        /// First `frames` frames of `src` with a linear fade over the last `fadeFrames` (choke / note-length truncation).
        static func truncated(_ src: AVAudioPCMBuffer, frames: Int, fadeFrames: Int) -> AVAudioPCMBuffer? {
            let n = max(1, min(frames, Int(src.frameLength)))
            guard let out = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: AVAudioFrameCount(n)) else { return nil }
            out.frameLength = AVAudioFrameCount(n)
            let f = min(n, max(1, fadeFrames))
            for c in 0..<Int(src.format.channelCount) {
                let d = out.floatChannelData![c]
                memcpy(d, src.floatChannelData![c], n * MemoryLayout<Float>.size)
                for i in 0..<f { d[n - 1 - i] *= Float(i) / Float(f) }
            }
            return out
        }

        /// Peak (max |x| over channels) per bin, clamped to 0...1.
        static func envelope(_ buf: AVAudioPCMBuffer, bins: Int) -> [Float] {
            let n = Int(buf.frameLength)
            guard n > 0, bins > 0, let data = buf.floatChannelData else { return [Float](repeating: 0, count: max(0, bins)) }
            var out = [Float](repeating: 0, count: bins)
            let ch = Int(buf.format.channelCount)
            for b in 0..<bins {
                let a = min(n - 1, b * n / bins)
                let e = min(n, max(a + 1, (b + 1) * n / bins))
                var m: Float = 0
                for c in 0..<ch {
                    var cm: Float = 0
                    vDSP_maxmgv(data[c] + a, 1, &cm, vDSP_Length(e - a))
                    m = max(m, cm)
                }
                out[b] = min(1, m)
            }
            return out
        }
    }

    /// Streams 16-bit stereo PCM into a WAV whose header is patched after every append,
    /// so the file on disk is always valid (the self-test can pull it while the app runs).
    final class WavWriter {
        private let handle: FileHandle
        private let maxBytes: Int
        private(set) var dataBytes = 0
        let url: URL

        init?(url: URL, sampleRate: Double, maxSeconds: Double) {
            self.url = url
            let sr = Int(sampleRate.rounded())
            maxBytes = Int(maxSeconds * Double(sr)) * 4
            try? FileManager.default.removeItem(at: url)
            guard FileManager.default.createFile(atPath: url.path, contents: WavWriter.header(sampleRate: sr, dataBytes: 0)),
                  let h = try? FileHandle(forWritingTo: url) else { return nil }
            handle = h
        }

        var isFull: Bool { dataBytes >= maxBytes }

        func append(_ samples: [Int16]) {
            guard dataBytes < maxBytes, !samples.isEmpty else { return }
            var data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            if dataBytes + data.count > maxBytes { data = data.prefix(maxBytes - dataBytes) }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                dataBytes += data.count
                try handle.seek(toOffset: 4)
                try handle.write(contentsOf: WavWriter.le32(36 + dataBytes))
                try handle.seek(toOffset: 40)
                try handle.write(contentsOf: WavWriter.le32(dataBytes))
            } catch {
                DebugLog.event("audio_error", ["where": "debug_wav", "error": "\(error)"])
                dataBytes = maxBytes
            }
        }

        static func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { Data($0) } }
        static func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(truncatingIfNeeded: v).littleEndian) { Data($0) } }

        static func header(sampleRate sr: Int, dataBytes: Int) -> Data {
            var d = Data()
            d.append(contentsOf: Array("RIFF".utf8)); d.append(le32(36 + dataBytes))
            d.append(contentsOf: Array("WAVE".utf8))
            d.append(contentsOf: Array("fmt ".utf8)); d.append(le32(16))
            d.append(le16(1)); d.append(le16(2))              // PCM, stereo
            d.append(le32(sr)); d.append(le32(sr * 4))         // byte rate
            d.append(le16(4)); d.append(le16(16))              // block align, bits
            d.append(contentsOf: Array("data".utf8)); d.append(le32(dataBytes))
            return d
        }
    }
}
