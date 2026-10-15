import Foundation

/// loadBank may silently skip failed decodes or be superseded. Read back before declaring success.
@MainActor
enum SampleBankCommit {
    @discardableResult
    static func publish(_ expected: [Int: PadSound], to state: AppState) -> Bool {
        var actual: [Int: PadSound] = [:]
        for index in 0..<16 {
            if let sound = state.engine.sound(for: PadID(.d, index)) { actual[index] = sound }
        }
        // Keep the pad display honest even if decoding was partial or a newer load won.
        state.sounds = state.sounds.filter { $0.key.bank != .d }
        for (index, sound) in actual { state.sounds[PadID(.d, index)] = sound }
        guard !expected.isEmpty, actual == expected else { return false }
        state.bank = .d
        state.selectedPad = PadID(.d, 0)
        return true
    }
}
