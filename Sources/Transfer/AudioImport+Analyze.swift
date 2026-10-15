import Foundation

/// Imported songs: on-device analysis (ChopSignal → SongRegion → Chopper, Sources/Library) picks the region worth
/// sampling and chops it. Demo-manifest songs keep their hand-checked tempo, first downbeat, key and chords.
extension AudioImport {
    @MainActor static func analyzed(_ audio: ImportedAudio, demo: DemoSample?, label: String, state: AppState) async
        -> (set: ChopSet, plan: SongPlan)? {
        let t0 = Date()
        let url = audio.url
        let result = await Task.detached(priority: .userInitiated) { () -> (ChopSet, SongPlan)? in
            guard let sig = try? ChopSignal.load(url: url, start: 0, duration: ChopSignal.songSeconds),
                  var plan = SongRegion.plan(sig, bpmHint: demo?.bpm, barsHint: demo?.bars, originHint: demo?.slicesSec?.first)
            else { return nil }
            if let k = demo?.key { plan.key = k }
            if let c = demo?.chords, c.count == plan.bars { plan.chords = c }
            guard let set = Orchestrator.importSet(url: url, label: label, plan: plan) else { return nil }
            return (set, plan)
        }.value
        let ms = Int((Date().timeIntervalSince(t0) * 1000).rounded())
        guard let (set, plan) = result else {
            DebugLog.event("analyze", ["ok": false, "ms": ms])
            return nil
        }
        state.addLog("ANALYZE", String(format: "▸ %.0f BPM · %@ · %d bars at %.1f s · 16 chops", plan.bpm, plan.key, plan.bars, plan.start),
                     ms: ms, tint: .blue)
        DebugLog.event("analyze", ["bpm": plan.bpm, "key": plan.key, "bars": plan.bars, "start": plan.start, "end": plan.end,
                                   "chords": plan.chords.map { $0 ?? "?" }, "ms": ms, "why": plan.why, "demo": demo != nil])
        return (set, plan)
    }
}
