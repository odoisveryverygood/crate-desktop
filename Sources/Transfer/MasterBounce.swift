import Foundation
import AVFoundation

/// Copies tap memory before returning; writes and finalizes the WAV on a serial utility queue.
final class MasterBounce: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.shuhan.crate.bounce", qos: .utility)
    private let lock = NSLock()
    private var accepting = true
    private var finished = false // queue only
    private var file: AVAudioFile? // queue only
    private var written = 0 // queue only
    private var acceptedFrames = 0 // tap callback only
    private var nextSampleTime: AVAudioFramePosition? // tap callback only
    private var captureID: UUID?
    private weak var engine: AudioEngine?
    private let url: URL
    private let start: Double
    private let duration: Double
    private let bpm: Double
    private let generation: Int
    private let sampleRate: Double
    private let completion: (Result<URL, Error>) -> Void

    init(engine: AudioEngine, bars: Int = 4, title: String, directory: URL? = nil,
         completion: @escaping (Result<URL, Error>) -> Void) throws {
        let snapshot = engine.stateLock.withLock { engine.shared }
        guard snapshot.playing, snapshot.timeline.playing else { throw AudioEngine.BounceError.playbackRequired }
        self.engine = engine
        self.completion = completion
        bpm = snapshot.bpm
        generation = snapshot.transportGen
        sampleRate = engine.ensureFormat().sampleRate
        let now = AudioEngine.Clock.now()
        let pos = snapshot.timeline.position(at: now)
        let nextBar = (floor(pos / 16) + 1) * 16
        start = now + (nextBar - pos) * snapshot.timeline.sps
        duration = Double(max(1, min(16, bars))) * 240 / bpm
        let docs = directory ?? CrateStorage.documents.appendingPathComponent("bounces", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let safeTitle = title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
        let name = safeTitle.isEmpty ? "CRATE" : String(safeTitle.prefix(60))
        url = docs.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).wav")
        guard let id = engine.attachMasterCapture({ [weak self] buffer, time in self?.capture(buffer, time: time) }) else {
            throw AudioEngine.BounceError.busy
        }
        captureID = id
        queue.asyncAfter(deadline: .now() + (start - now) + duration + 5) { [weak self] in
            self?.finish(.failure(AudioEngine.BounceError.timedOut))
        }
    }

    func cancel() { queue.async { self.finish(.failure(AudioEngine.BounceError.interrupted)) } }

    private func capture(_ input: TapBuffer, time: AVAudioTime) {
        guard lock.withLock({ accepting }) else { return }
        guard let engine else { cancel(); return }
        let snapshot = engine.stateLock.withLock { engine.shared }
        guard snapshot.playing, snapshot.transportGen == generation, abs(snapshot.bpm - bpm) < 0.001,
              abs(input.format.sampleRate - sampleRate) < 0.1, time.isHostTimeValid else { cancel(); return }
        let bufferStart = AVAudioTime.seconds(forHostTime: time.hostTime)
        let goal = Int((duration * sampleRate).rounded())
        // Align the first frame to the next bar, then count samples. Host timestamps can
        // drift by a few samples over a long take; trimming every buffer by host time
        // incorrectly rejects otherwise continuous audio.
        let skip = acceptedFrames == 0 ? min(input.frameLength, max(0, Int(((start - bufferStart) * sampleRate).rounded(.up)))) : 0
        guard skip < input.frameLength else { return }
        if let expected = nextSampleTime, time.isSampleTimeValid, abs(time.sampleTime - expected) > 1 { cancel(); return }
        if time.isSampleTimeValid { nextSampleTime = time.sampleTime + AVAudioFramePosition(input.frameLength) }
        let count = min(input.frameLength - skip, goal - acceptedFrames)
        guard count > 0 else { return }
        let range = skip..<(skip + count)
        acceptedFrames += count
        guard input.format.commonFormat == .pcmFormatFloat32,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)),
              let channels = copy.floatChannelData else { cancel(); return }
        copy.frameLength = AVAudioFrameCount(range.count)
        input.withUnsafeAudioBufferList { pointer in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: pointer))
            for channel in 0..<2 {
                let index = input.format.isInterleaved ? 0 : min(channel, list.count - 1)
                guard index >= 0, let data = list[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let stride = input.format.isInterleaved ? Int(input.format.channelCount) : 1
                let offset = input.format.isInterleaved ? min(channel, Int(input.format.channelCount) - 1) : 0
                for (destination, source) in range.enumerated() {
                    channels[channel][destination] = data[source * stride + offset]
                }
            }
        }
        let last = acceptedFrames == goal
        if last { lock.withLock { accepting = false } }
        queue.async {
            guard !self.finished else { return }
            do {
                if self.file == nil {
                    self.file = try AVAudioFile(forWriting: self.url, settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: self.sampleRate,
                        AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
                    ], commonFormat: .pcmFormatFloat32, interleaved: false)
                }
                try self.file?.write(from: copy)
                self.written += Int(copy.frameLength)
                if last { self.finishRecording() }
            } catch { self.finish(.failure(error)) }
        }
    }

    private func finishRecording() {
        let expected = Int((duration * sampleRate).rounded())
        guard written == expected else { finish(.failure(AudioEngine.BounceError.interrupted)); return }
        finish(.success(url))
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        lock.withLock { accepting = false }
        if let id = captureID { engine?.detachMasterCapture(id) }
        file = nil // Finalize the header before the file can be shared.
        if case .failure(let error) = result {
            try? FileManager.default.removeItem(at: url)
            DebugLog.event("bounce_error", ["error": error.localizedDescription, "frames": written, "expected": Int((duration * sampleRate).rounded())])
        }
        DispatchQueue.main.async { self.completion(result) }
    }

    deinit { if let id = captureID { engine?.detachMasterCapture(id) } }
}
