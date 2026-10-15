import Foundation

/// Silent engine for SwiftUI previews and the macOS harness. Keeps time so playheads move.
final class MockEngine: SamplerEngine {
    private var sounds: [PadID: PadSound] = [:]
    private(set) var pattern = Pattern.empty
    private var startDate: Date?
    private var startStep: Double = 0
    var bpm: Double = 90
    var swing: Double = 56
    var onBar: ((Int) -> Void)?
    var isPlaying: Bool { startDate != nil }

    func start() throws {}
    func loadBank(_ bank: Bank, sounds new: [Int: PadSound]) async throws {
        sounds = sounds.filter { $0.key.bank != bank }
        for (i, s) in new { sounds[PadID(bank, i)] = s }
    }
    func sound(for pad: PadID) -> PadSound? { sounds[pad] }
    func trigger(_ pad: PadID, velocity: Int, semitones: Double) {}
    func release(_ pad: PadID) {}
    func setPattern(_ p: Pattern, timing: ApplyTiming) { pattern = p }
    func play() { startDate = Date(); startStep = 0 }
    func stop() { startDate = nil }
    func position() -> Double {
        guard let s = startDate else { return 0 }
        return startStep + Date().timeIntervalSince(s) / (60 / bpm / 4)
    }
    func queueFill(_ fill: FillDef, atBar bar: Int) {}
    func setRecording(_ on: Bool) {}
    func setPunch(_ amount: Double) {}
    func drop() {}
    func level() -> Float { isPlaying ? 0.4 : 0 }
    func waveform(_ pad: PadID, points: Int) -> [Float] {
        (0..<max(points, 1)).map { i in
            let x = Double(i) / Double(max(points, 1))
            return Float(abs(sin(x * 40)) * exp(-x * 2.5) * 0.9 + 0.05)
        }
    }
}
