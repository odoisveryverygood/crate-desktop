import Foundation

/// Imported songs: 16 chops on bank D. ＋ / drag-in only loads them (FLIP IT glows). Later DIGs (e.g. "dilla drums
/// for this") keep the chops. Where the chops come from: `SongRegion` picks the best 1/2/4-bar region of the song
/// (or the whole file when it's a loop) and `Chopper` cuts it (FIND), or `rechop(mode: .song)` picks 16 chops
/// across the whole song.
extension Orchestrator {
    /// Set by `wire()` so the import path (Transfer) can reach the running orchestrator.
    static weak var current: Orchestrator?

    /// The session's chops came from an imported song (they live on bank D, not bank B).
    var importedFlip: Bool { session?.chops?.loop.id.hasPrefix("import-") == true }
    var chopBank: Bank { importedFlip ? .d : .b }

    /// Song plans by file path (region, beats, key), so a re-chop doesn't analyse the song again.
    @MainActor static var songPlans: [String: SongPlan] = [:]

    /// ＋ or a drag-in: the song's chops onto bank D (one UNDO step) and chop 1 auditions. FLIP IT glows;
    /// nothing plays or flips until it's tapped.
    @discardableResult
    func importChops(_ set: ChopSet, plan: SongPlan?) async -> Bool {
        checkpoint("import \(set.loop.name)")
        Analytics.shared.track("import_song", ["name": set.loop.name, "sec": Int(set.loop.durationSec)])
        if let p = plan { Self.songPlans[set.loop.file] = p }
        guard let ms = await loadImportedChops(set) else { return false }
        state.hit(PadID(.d, 0))
        CrateUI.shared.flipHint = true
        let region = plan.map { String(format: " · %.1f–%.1f s", $0.start, $0.end) } ?? ""
        state.addLog("SAMPLE", "▸ \(set.loop.name) · \(set.spanBars) bars\(region) · \(set.loop.key ?? "?") · 16 chops on D · tap FLIP IT",
                     ms: ms, tint: .blue)
        DebugLog.event("import_chops", ["name": set.loop.name, "key": set.loop.key ?? "", "bpm": set.loop.bpm, "bars": set.spanBars,
                                        "start": plan?.start ?? 0, "end": plan?.end ?? set.spanSec, "ms": ms,
                                        "heroes": (0..<16).filter { set.info[$0]?.hero == true }.map { $0 + 1 },
                                        "why": plan?.why ?? [:]])
        return true
    }

    /// Loads the set onto bank D and makes it the session's chops (so FLIP IT and DIG use them).
    private func loadImportedChops(_ set: ChopSet) async -> Int? {
        digSerial += 1
        let serial = digSerial
        gptTask?.cancel()
        gptTask = nil
        let loadMs = await loadBanks([(.d, set.sounds)])
        guard serial == digSerial else { return nil }
        guard set.sounds.allSatisfy({ state.engine.sound(for: PadID(.d, $0.key))?.id == $0.value.id }) else { return nil }
        session = Session(drumStyle: .dilla, sampleStyle: .dilla, bars: 4, laidback: 0.8, energy: 0.55, chops: set,
                          harmony: BassWriter.Harmony(set))
        state.scaleKey = set.loop.key
        state.sampleLabel = "\(set.loop.name) · \(set.loop.key ?? "—")"
        state.chordsLabel = set.chordsLabel
        state.styleLabel = library.styleInfo(.dilla).label
        state.bank = .d
        state.selectedPad = PadID(.d, 0)
        return loadMs
    }

    /// An imported song's chop set (thread-safe, blocking: call off the main thread). FIND / slices inside the plan's
    /// region, or `.song`: 16 distinct chops across the whole song. `keep` = favourite pads left as they are.
    nonisolated static func importSet(url: URL, label: String, plan: SongPlan, mode: ChopMode = .find, seed: UInt64 = 0,
                                      keep: [Int: PadSound] = [:]) -> ChopSet? {
        let all = ChopSignal.songSeconds
        let need = mode == .song ? all : min(all, plan.end + plan.grid.stepLength(at: 0) * Double(plan.bars * 16) + 0.5)
        guard let sig = try? ChopSignal.load(url: url, start: 0, duration: need) else { return nil }
        var info: [Int: ChopFeature]
        if mode == .song {
            info = SongRegion.songChops(sig, plan: plan, seed: seed)
            for k in keep.keys { info.removeValue(forKey: k) }
        } else {
            info = Chopper.chop(sig, grid: plan.grid, spanSteps: plan.bars * 16, mode: mode, seed: seed,
                                keep: keep.mapValues { ($0.start, $0.end ?? plan.end) })
        }
        guard info.count + keep.count >= 4 else { return nil }
        let key = Music.parseKey(plan.key)
        let root = 60 + (key?.pc ?? 0)
        let short = label.split(separator: " ").prefix(2).joined(separator: " ")
        var sounds = keep
        for (i, c) in info {
            sounds[i] = PadSound(id: "import-chop-\(i)-" + UUID().uuidString, name: "\(short) \(String(format: "%02d", i + 1))",
                                 category: .chop, fileURL: url, start: c.start, end: c.end, rootNote: root, source: "import")
        }
        let starts = (0..<16).map { sounds[$0]?.start ?? 0 }
        var loop = LoopEntry(id: "import-" + DemoSamples.normalize(label), file: url.path, name: label, instrument: "sample",
                             bpm: plan.bpm, bars: plan.bars, durationSec: sig.end)
        loop.key = plan.key
        loop.keyConfidence = plan.keyConfidence
        loop.slices16Sec = starts
        loop.chordsPerBar = plan.chords
        loop.source = "import"
        let chords = plan.chords.map { ChordInfo.parse($0) }
        var names: [String] = []
        for c in chords.compactMap({ $0?.symbol }) where names.last != c { names.append(c) }
        return ChopSet(loop: loop, spanBars: plan.bars, spanSec: plan.end - plan.start, starts: starts, sounds: sounds,
                       chords: chords, bassPerBeat: [], keyPC: key?.pc, keyMinor: key?.minor ?? false, rootNote: root,
                       chordsLabel: names.joined(separator: " "), info: info, grid: plan.grid, mode: mode)
    }

    /// Flips used to be written on bank B; an imported song's chops live on `bank`: move lanes and notes there
    /// (offbeat hits humanized a little, as before).
    static func moveChops(_ p: Pattern, to bank: Bank) -> Pattern {
        let moved = p.lanes.filter { $0.key.bank == .b }
        let movedNotes = p.notes.filter { $0.key.bank == .b }
        guard bank != .b, !moved.isEmpty || !movedNotes.isEmpty else { return p }
        var out = p
        out.lanes = p.lanes.filter { $0.key.bank != .b && $0.key.bank != bank }
        out.notes = p.notes.filter { $0.key.bank != .b && $0.key.bank != bank }
        out.late = p.late.filter { $0.key.bank != .b && $0.key.bank != bank }
        for (k, hits) in moved {
            out.lanes[PadID(bank, k.index)] = hits.map { h in
                var h = h
                if h.offset == 0, h.step % 4 != 0 { h.offset = 0.12 }
                if h.step % 4 != 0 { h.velocity = min(h.velocity, 94) }
                return h
            }
        }
        for (k, notes) in movedNotes { out.notes[PadID(bank, k.index)] = notes }
        return out
    }
}
