#if DEBUG
import Foundation
import AVFoundation

/// Native integration checks run in the app process and use the actual engine/resources.
@MainActor enum MacVerification {
    static func run(state: AppState) async {
        let destination = AppConfig.devString("crateMacVerifyOutput") ?? NSTemporaryDirectory() + "crate-mac-check.json"
        var checks: [String: Bool] = [:]
        var details: [String: Any] = [:]
        let engine = state.engine
        checks["starter_has_16_decoded_pads"] = (0..<16).allSatisfy { engine.sound(for: PadID(.a, $0)) != nil }
        checks["starter_media_exists"] = state.sounds.values.allSatisfy { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        let keys = KeyboardPlayer(state: state)
        state.promptFocused = false
        checks["keyboard_pad_down"] = keys.press("z") && state.heldPads.contains(PadID(.a, 0))
        state.bank = .b
        _ = keys.release("z")
        checks["keyboard_up_after_bank_switch"] = state.heldPads.isEmpty
        state.bank = .a
        state.promptFocused = true
        checks["typing_does_not_trigger_pads"] = !keys.press("z")
        state.promptFocused = false
        state.mode = .keys
        _ = keys.press("a")
        checks["musical_typing_note_down"] = !state.heldNotes.isEmpty
        keys.releaseAll()
        checks["musical_typing_release_all"] = state.heldNotes.isEmpty
        state.mode = .seq
        engine.play()
        state.isPlaying = true
        var peak: Float = 0
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            peak = max(peak, engine.level())
        }
        checks["live_audio_output_nonzero"] = peak > 0.00001
        details["live_peak_level"] = peak
        details["sample_rate"] = (engine as? AudioEngine)?.ensureFormat().sampleRate ?? 0
        engine.stop()
        state.isPlaying = false
        do {
            let url = try await BeatExport.run(state: state, length: .loop1, format: .wav) { _ in }
            let file = try AVAudioFile(forReading: url)
            let expected = Double(max(1, engine.pattern.bars)) * 240 / state.bpm
            let duration = Double(file.length) / file.processingFormat.sampleRate
            checks["wav_duration_correct"] = abs(duration - expected) < 0.01
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            var maxSample: Float = 0
            if let data = buffer.floatChannelData {
                for c in 0..<Int(buffer.format.channelCount) {
                    for i in 0..<Int(buffer.frameLength) { maxSample = max(maxSample, abs(data[c][i])) }
                }
            }
            checks["wav_contains_audio"] = maxSample > 0.00001
            details["wav_path"] = url.path
            details["wav_seconds"] = duration
            details["wav_peak"] = maxSample
            let m4a = try await BeatExport.run(state: state, length: .loop1, format: .m4a) { _ in }
            checks["m4a_readable"] = try AVAudioFile(forReading: m4a).length > 0
            let project = ProjectStore.shared.save(state: state, name: "MAC CHECK", asNew: true)
            checks["saved_kit_paths_portable"] = project.sounds.values.allSatisfy { $0.filePath.hasPrefix("~kit/") }
            await ProjectStore.shared.load(project, into: state)
            checks["project_roundtrip_pads_and_pattern"] = (0..<16).allSatisfy { engine.sound(for: PadID(.a, $0)) != nil } && !engine.pattern.lanes.isEmpty
            let before = engine.sound(for: PadID(.a, 0))?.id
            await AudioImport.importPicked(url, state: state)
            checks["import_chops_16_pads"] = (0..<16).allSatisfy { engine.sound(for: PadID(.d, $0)) != nil }
            checks["import_preserves_other_banks"] = engine.sound(for: PadID(.a, 0))?.id == before
            let imported = ProjectStore.shared.save(state: state, name: "MAC IMPORT CHECK", asNew: true)
            checks["imported_paths_portable"] = imported.sounds.filter { $0.key.hasPrefix("D") }.values.allSatisfy { $0.filePath.hasPrefix("~docs/") }
            await ProjectStore.shared.load(imported, into: state)
            checks["import_survives_project_reload"] = (0..<16).allSatisfy { engine.sound(for: PadID(.d, $0)) != nil }
            if let orchestrator = Orchestrator.current {
                let report = await orchestrator.dig("house drums with piano")
                checks["local_dig_loads_playable_beat"] = !engine.pattern.lanes.isEmpty && engine.sound(for: PadID(.a, 0)) != nil
                details["local_dig_ms"] = report.totalMs
            }
        } catch { details["error"] = error.localizedDescription; checks["export_and_save"] = false }
        engine.stop()
        state.isPlaying = false
        details["ai_proxy_configured"] = AppConfig.appToken != nil
        details["checks"] = checks
        details["passed"] = checks.values.allSatisfy { $0 }
        if let data = try? JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: destination), options: .atomic)
        }
        print("CRATE_MAC_VERIFICATION \(checks.values.filter { $0 }.count)/\(checks.count) → \(destination)")
    }
}
#endif
