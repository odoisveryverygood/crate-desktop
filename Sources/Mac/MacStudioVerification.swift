#if DEBUG
import AppKit
import AVFoundation

/// Offline, isolated integration checks: never boots or saves a user project.
@MainActor enum MacStudioVerification {
    static func run(state: AppState, orchestrator: Orchestrator) async {
        let lib = orchestrator.library
        var checks: [String: Bool] = [:]
        var details: [String: Any] = [:]
        checks["full_library_loaded"] = lib.oneshots.count >= 1000 && lib.loops.count >= 500 && !lib.isFallback && lib.problems.isEmpty
        checks["all_16_categories_populated"] = BankA.slots.allSatisfy { !lib.candidates(Retrieval.slotCategory($0)).isEmpty }
        checks["library_ids_unique"] = Set(lib.oneshots.map(\.id)).count == lib.oneshots.count && Set(lib.loops.map(\.id)).count == lib.loops.count
        let requests: [(String, String)] = [
            ("piano", "piano"), ("electric piano", "rhodes"), ("organ", "organ"), ("clavinet", "clav"),
            ("guitar", "guitar"), ("pluck", "pluck"), ("bells", "bell"), ("vibraphone", "vibes"),
            ("marimba", "marimba"), ("steel pan", "steelpan"), ("flute", "flute"), ("sax", "sax"),
            ("brass", "horns"), ("strings", "strings"), ("ambient pad", "pad"), ("choir", "vocal"), ("synth lead", "synth")]
        var picks: [String: String] = [:]
        for (word, inst) in requests {
            let p = KeywordParser.parse("house \(word) sample at 124 bpm", grooves: lib.grooves)
            checks["parse_\(inst)"] = p.instrument == inst
            let req = LoopRequest(sampleStyle: .house, drumStyle: .house, instrument: p.instrument, bars: 4, bpm: 124)
            guard let loop = Retrieval.loop(lib, req, seed: 731026) else { checks["retrieve_\(inst)"] = false; continue }
            checks["retrieve_\(inst)"] = loop.instrument == inst && loop.bpm == 124
            let chops = Retrieval.chops(loop, lib: lib, bars: 4)
            _ = await orchestrator.loadBanks([(.b, chops.sounds)])
            checks["decode_chops_\(inst)"] = (0..<16).allSatisfy { state.engine.sound(for: PadID(.b, $0)) != nil }
            checks["waveform_\(inst)"] = state.engine.waveform(PadID(.b, 0), points: 128).contains { abs($0) > 0.0001 }
            picks[inst] = loop.id
        }
        for style in Style.allCases {
            let kit = Retrieval.kit(lib, style: style, target: lib.styleInfo(style).kit, seed: 31)
            _ = await orchestrator.loadBanks([(.a, kit)])
            checks["kit_\(style.rawValue)"] = (0..<16).allSatisfy { state.engine.sound(for: PadID(.a, $0)) != nil }
        }
        if var loop = lib.loops.first(where: { $0.instrument == "flute" }) {
            loop.id = "import-library-" + loop.id
            let imported = await orchestrator.importChops(Retrieval.chops(loop, lib: lib, bars: 4), plan: nil)
            checks["browser_chop_bank_d"] = imported && orchestrator.chopBank == .d
                && (0..<16).allSatisfy { state.engine.sound(for: PadID(.d, $0)) != nil }
            orchestrator.session = nil
            orchestrator.restoreSession()
            checks["browser_chop_session_restore"] = orchestrator.chopBank == .d && orchestrator.session != nil
            await orchestrator.undo()
            checks["browser_chop_undo"] = state.engine.sound(for: PadID(.d, 0)) == nil && !CrateUI.shared.flipHint
        }
        // The actual orchestration paths, offline: full beat, surgical layering and Undo.
        let full = await orchestrator.dig("house piano beat at 124 bpm")
        state.engine.stop(); state.isPlaying = false
        checks["prompt_house_piano"] = full.loopID?.contains("PIANO") == true && state.bpm == 124 && !state.engine.pattern.lanes.isEmpty
        let beforeA = (0..<16).map { state.engine.sound(for: PadID(.a, $0))?.id }
        let beforeB = (0..<16).map { state.engine.sound(for: PadID(.b, $0))?.id }
        let layer = await orchestrator.dig("add a flute line")
        state.engine.stop(); state.isPlaying = false
        checks["flute_layer_scope"] = layer.plan.scope == .addLayer && layer.loopID?.contains("FLUTE") == true
        checks["flute_preserves_drums_and_chops"] = beforeA == (0..<16).map { state.engine.sound(for: PadID(.a, $0))?.id }
            && beforeB == (0..<16).map { state.engine.sound(for: PadID(.b, $0))?.id }
        let fluteIDs = (0..<4).map { state.engine.sound(for: PadID(.d, $0))?.id }
        let strings = await orchestrator.dig("add strings on top")
        state.engine.stop(); state.isPlaying = false
        checks["second_melodic_layer"] = strings.plan.scope == .addLayer && orchestrator.session?.activeLayers.count == 2
        checks["second_layer_preserves_flute"] = fluteIDs == (0..<4).map { state.engine.sound(for: PadID(.d, $0))?.id }
            && state.engine.sound(for: PadID(.d, 4))?.id.contains("STRINGS") == true
        checks["second_layer_preserves_drums"] = beforeA == (0..<16).map { state.engine.sound(for: PadID(.a, $0))?.id }
        let protectedC = (0..<4).map { state.engine.sound(for: PadID(.c, $0))?.id }
        for prompt in ["add a guitar line", "add bells on top", "add an organ line"] {
            _ = await orchestrator.dig(prompt)
            state.engine.stop(); state.isPlaying = false
        }
        checks["five_independent_layers"] = orchestrator.session?.activeLayers.count == 5
        checks["layers_use_spare_c_pads"] = orchestrator.session?.activeLayers.contains { $0.bank == .c && $0.pads.allSatisfy { $0 >= 4 } } == true
        checks["layers_preserve_bass_and_keys"] = protectedC == (0..<4).map { state.engine.sound(for: PadID(.c, $0))?.id }
        for _ in 0..<3 { await orchestrator.undo() }
        orchestrator.session = nil
        orchestrator.restoreSession()
        checks["multiple_layers_restore"] = orchestrator.session?.activeLayers.count == 2
        await orchestrator.undo()
        checks["undo_second_layer_only"] = fluteIDs == (0..<4).map { state.engine.sound(for: PadID(.d, $0))?.id }
            && state.engine.sound(for: PadID(.d, 4)) == nil && orchestrator.session?.activeLayers.count == 1
        await orchestrator.undo()
        checks["undo_flute_layer"] = state.engine.sound(for: PadID(.d, 0)) == nil
        let hat = await orchestrator.dig("more hats")
        checks["hat_edit_scope"] = hat.plan.scope == .laneEdit
        checks["hat_edit_preserves_samples"] = beforeB == (0..<16).map { state.engine.sound(for: PadID(.b, $0))?.id }
        state.engine.stop(); state.isPlaying = false
        do {
            let output = try await BeatExport.run(state: state, length: .loop1, format: .wav) { _ in }
            let audio = try AVAudioFile(forReading: output)
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))!
            try audio.read(into: buffer)
            var peak: Float = 0; var square: Double = 0; var clipped = 0
            if let data = buffer.floatChannelData {
                for c in 0..<Int(buffer.format.channelCount) {
                    for i in 0..<Int(buffer.frameLength) {
                        let v = abs(data[c][i]); peak = max(peak, v); square += Double(v * v)
                        if v >= 0.99999 { clipped += 1 }
                    }
                }
            }
            checks["export_has_audio"] = peak > 0.001
            checks["export_duration"] = abs(duration - 4 * 240 / state.bpm) < 0.01
            checks["export_not_clipped"] = clipped == 0
            details["export"] = ["path": output.path, "seconds": duration, "peak": peak, "clipped_samples": clipped,
                                 "rms": sqrt(square / Double(max(1, buffer.frameLength * buffer.format.channelCount)))]
        } catch { checks["export"] = false; details["error"] = error.localizedDescription }
        state.engine.stop(); state.isPlaying = false
        details["one_shots"] = lib.oneshots.count; details["loops"] = lib.loops.count; details["picks"] = picks
        details["checks"] = checks; details["passed"] = checks.values.allSatisfy { $0 }
        details["offline"] = AppConfig.offline
        let destination = AppConfig.devString("crateMacStudioOutput") ?? NSTemporaryDirectory() + "crate-studio-verification.json"
        if let data = try? JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: destination), options: .atomic)
        }
        print("CRATE_STUDIO_CHECK \(checks.values.filter { $0 }.count)/\(checks.count)")
        NSApplication.shared.terminate(nil)
    }
}
#endif
