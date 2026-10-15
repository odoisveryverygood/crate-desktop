import Foundation
import AVFoundation

enum SampleChopType: String, CaseIterable, Sendable {
    case threshold, regions16
    var label: String { self == .threshold ? "THRESH" : "REGIONS 16" }
}

struct SampleSlice: Equatable, Sendable {
    let start: Double
    let end: Double
}

struct SampleAnalysis: Sendable {
    let duration: Double
    let slices: [SampleSlice]
}

enum SampleChopError: LocalizedError {
    case emptyRecording, unreadableAudio
    var errorDescription: String? {
        switch self {
        case .emptyRecording: return "The take is too short. Hold SAMPLE RECORD a little longer."
        case .unreadableAudio: return "Couldn't read the recorded audio. Please record another take."
        }
    }
}

/// Stream the WAV in 10 ms windows instead of retaining the entire take in memory.
enum SampleChopper {
    static func analyze(url: URL, chop: SampleChopType) throws -> SampleAnalysis {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0, file.length > 0 else {
            throw SampleChopError.emptyRecording
        }
        let duration = Double(file.length) / format.sampleRate
        guard duration >= 0.08 else { throw SampleChopError.emptyRecording }
        let frames = AVAudioFrameCount(max(1, (format.sampleRate * 0.01).rounded()))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw SampleChopError.unreadableAudio
        }
        var rms: [Double] = []
        while file.framePosition < file.length {
            try Task.checkCancellation()
            // iOS 27 can throw when the requested read extends past EOF. Most takes
            // do not end on an exact 10 ms boundary; request only their remaining frames.
            let remaining = file.length - file.framePosition
            let requested = AVAudioFrameCount(min(AVAudioFramePosition(frames), remaining))
            try file.read(into: buffer, frameCount: requested)
            guard buffer.frameLength == requested, let channels = buffer.floatChannelData else {
                throw SampleChopError.unreadableAudio
            }
            var sum = 0.0
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    let value = Double(channels[channel][frame])
                    sum += value.isFinite ? value * value : 0
                }
            }
            rms.append(sqrt(sum / Double(Int(buffer.frameLength) * Int(format.channelCount))))
        }
        return SampleAnalysis(duration: duration, slices: slices(rms: rms,
            window: Double(frames) / format.sampleRate, duration: duration, chop: chop))
    }

    /// SAMPLE + hold a pad: where the sound is in a take (leading / trailing silence trimmed, a little pre-roll kept).
    static func trim(url: URL) throws -> (start: Double, end: Double, duration: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate > 0, file.length > 0 else { throw SampleChopError.emptyRecording }
        let duration = Double(file.length) / format.sampleRate
        guard duration >= 0.08 else { throw SampleChopError.emptyRecording }
        let frames = AVAudioFrameCount(max(1, (format.sampleRate * 0.01).rounded()))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw SampleChopError.unreadableAudio
        }
        var rms: [Double] = []
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let requested = AVAudioFrameCount(min(AVAudioFramePosition(frames), remaining))
            try file.read(into: buffer, frameCount: requested)
            guard let ch = buffer.floatChannelData else { throw SampleChopError.unreadableAudio }
            var sum = 0.0
            for c in 0..<Int(format.channelCount) {
                for f in 0..<Int(buffer.frameLength) { let v = Double(ch[c][f]); sum += v.isFinite ? v * v : 0 }
            }
            rms.append(sqrt(sum / Double(max(1, Int(buffer.frameLength) * Int(format.channelCount)))))
        }
        let peak = rms.max() ?? 0
        let threshold = max(0.004, peak * 0.06)
        guard peak > 0.004, let first = rms.firstIndex(where: { $0 > threshold }),
              let last = rms.lastIndex(where: { $0 > threshold }) else { return (0, duration, duration) }
        let window = Double(frames) / format.sampleRate
        let start = max(0, Double(first) * window - 0.01)
        let end = min(duration, Double(last + 1) * window + 0.06)
        return end - start >= 0.05 ? (start, end, duration) : (0, duration, duration)
    }

    /// Full-take coverage, ordered nonempty slices, at most 16; all times are seconds.
    static func slices(rms: [Double], window: Double = 0.01,
                       duration: Double, chop: SampleChopType) -> [SampleSlice] {
        guard duration.isFinite, duration > 0 else { return [] }
        if chop == .regions16 {
            return (0..<16).map { SampleSlice(start: duration * Double($0) / 16,
                                             end: duration * Double($0 + 1) / 16) }
        }
        guard window.isFinite, window > 0 else { return [SampleSlice(start: 0, end: duration)] }
        var starts = [0.0]
        var floor = 0.0
        var previous = 0.0
        for (index, raw) in rms.enumerated() {
            let value = raw.isFinite ? max(0, raw) : 0
            let time = Double(index) * window
            // Slow envelope follows room noise; a fast rising edge identifies an attack.
            let threshold = max(0.008, floor * 2.5)
            if value > threshold, value > previous * 1.8 + 0.002,
               time - starts[starts.count - 1] >= 0.08 - 0.000001,
               time < duration - 0.02, starts.count < 16 {
                starts.append(time)
            }
            floor = floor * 0.95 + value * 0.05
            previous = value
        }
        let ends = Array(starts.dropFirst()) + [duration]
        return zip(starts, ends).map { SampleSlice(start: $0.0, end: $0.1) }
    }
}
