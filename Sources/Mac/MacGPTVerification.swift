#if DEBUG
import AppKit
import AVFoundation

/// Opt-in live check, isolated from the user's projects. No credentials or raw API errors in output.
@MainActor enum MacGPTVerification {
    static func run(state: AppState, orchestrator: Orchestrator) async {
        var checks: [String: Bool] = [:]
        var details: [String: Any] = ["model": OpenAIClient.arrangeModel]
        checks["credential_available"] = AppConfig.hostedAIEnabled || AppConfig.openAIKey != nil
        details["hosted_backend"] = AppConfig.hostedAIEnabled
        checks["ai_consent_enabled"] = PrivacyChoices.aiAllowed
        checks["client_available"] = orchestrator.openAI.available
        if AppConfig.hostedAIEnabled {
            checks["automatic_session_ready"] = await MacHostedAI.shared.ensureSession()
            checks["personal_keys_unused"] = AppConfig.openAIKey == nil && AppConfig.typesafeKey == nil
            checks["hosted_jev_typed_plan"] = await orchestrator.jev.ask("plan", state: "house piano beat at 124 bpm", timeout: 5) != nil
        }
        if orchestrator.openAI.available {
            _ = await orchestrator.dig("house piano beat at 124 bpm")
            await orchestrator.waitForBackground()
            checks["live_arrangement_applied"] = orchestrator.lastArrangement != nil
            checks["drums_present"] = !state.engine.pattern.lanes.isEmpty
            checks["piano_loaded"] = orchestrator.session?.chops?.loop.instrument == "piano"
            details["arrange_ms"] = Int((state.gptSeconds ?? 0) * 1000)
            details["arrange_usage"] = orchestrator.openAI.lastUsage
            let originalA = (0..<16).map { state.engine.sound(for: PadID(.a, $0))?.id }
            let originalB = (0..<16).map { state.engine.sound(for: PadID(.b, $0))?.id }
            state.engine.stop(); state.isPlaying = false
            orchestrator.lastArrangement = nil
            _ = await orchestrator.dig("flip it")
            await orchestrator.waitForBackground()
            checks["live_flip_applied"] = state.log.contains { $0.text.contains("AI flip") }
            checks["flip_preserves_samples"] = originalA == (0..<16).map { state.engine.sound(for: PadID(.a, $0))?.id }
                && originalB == (0..<16).map { state.engine.sound(for: PadID(.b, $0))?.id }
            details["flip_usage"] = orchestrator.openAI.lastUsage
            state.engine.stop(); state.isPlaying = false
            do {
                let output = try await BeatExport.run(state: state, length: .loop1, format: .wav) { _ in }
                let f = try AVAudioFile(forReading: output)
                checks["export_nonempty"] = f.length > 0
                details["export_path"] = output.path
            } catch { checks["export_nonempty"] = false }
        }
        state.engine.stop(); state.isPlaying = false
        details["checks"] = checks; details["passed"] = checks.values.allSatisfy { $0 }
        let destination = AppConfig.devString("crateMacGPTOutput") ?? NSTemporaryDirectory() + "crate-gpt-verification.json"
        if let data = try? JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: destination), options: .atomic)
        }
        print("CRATE_GPT_CHECK \(checks.values.filter { $0 }.count)/\(checks.count)")
        NSApplication.shared.terminate(nil)
    }
}
#endif
