import AVFoundation
import Foundation

/// One-pad edits from the lid: ‹ › swaps in the next library sound of the same type, and the pad editor trims a
/// pad's start / end. Every change is one UNDO step.
extension Orchestrator {
    /// Library one-shots can be swapped; slices of a loop, takes and imported files can't.
    func canSwap(_ pad: PadID) -> Bool {
        guard let s = state.sound(pad), ![.chop, .loop].contains(s.category) else { return false }
        return !library.candidates(s.category.rawValue).isEmpty
    }

    /// ‹ › : the next (step +1) or previous (−1) sound of the pad's type, ranked for the current style.
    func swapSound(_ pad: PadID, step: Int) async {
        guard canSwap(pad), let cur = state.sound(pad) else { return }
        let style = session?.drumStyle ?? .boombap
        var rng = SeededRNG(seed: 0xC4A7E)   // same order every time, so ‹ and › walk one list
        let ranked = Retrieval.ranked(library, category: cur.category.rawValue, style: style,
                                      target: library.styleInfo(style).kit, rng: &rng)
        guard ranked.count > 1 else { return }
        let at = ranked.firstIndex { $0.id == cur.id } ?? (step > 0 ? -1 : 0)
        let next = ranked[((at + step) % ranked.count + ranked.count) % ranked.count]
        let snd = Retrieval.padSound(next, lib: library)
        checkpoint("\(pad.bank.letter)\(pad.number) sound")
        var bank: [Int: PadSound] = [:]
        for i in 0..<16 {
            let id = PadID(pad.bank, i)
            if let s = state.engine.sound(for: id) ?? state.sounds[id] { bank[i] = s }
        }
        bank[pad.index] = snd
        let ms = await loadBanks([(pad.bank, bank)])
        state.hit(pad)
        state.addLog("KIT", "\(pad.bank.letter)\(pad.number) ← \(snd.name)", ms: ms, tint: .orange)
        DebugLog.event("swap", ["pad": "\(pad.bank.letter)\(pad.number)", "id": snd.id, "step": step])
        Analytics.shared.tap("sound_swap", ["pad": "\(pad.bank.letter)\(pad.number)", "dir": step, "sound": snd.name])
    }

    /// 🎲: a random sound for the pad, instant (library only, no network). A drum / one-shot gets one of the ~25
    /// best sounds of its kind for the beat's style; a chop pad gets a random loop from the ranked sample crate (not
    /// the current one or its near neighbours), re-chopped under the same beat. Goes through ‹ ›, so it's one UNDO
    /// step, logged and auditioned the same way.
    func randomSound(for pad: PadID) async {
        if canSwap(pad), let cur = state.sound(pad) {
            let style = session?.drumStyle ?? .boombap
            var rng = SeededRNG(seed: 0xC4A7E)   // the ‹ › order, so the step lands on the pick
            let ranked = Retrieval.ranked(library, category: cur.category.rawValue, style: style,
                                          target: library.styleInfo(style).kit, rng: &rng)
            let at = ranked.firstIndex { $0.id == cur.id }
            let pool = (0..<min(25, ranked.count)).filter { $0 != at }
            guard let pick = pool.randomElement() else { return }
            DebugLog.event("random", ["pad": pad.key, "kind": "sound", "pick": pick, "of": pool.count])
            await swapSound(pad, step: at.map { pick - $0 } ?? pick + 1)
        } else if canSwapSample(pad), let s = session, let cur = s.chops {
            let req = LoopRequest(sampleStyle: s.sampleStyle, drumStyle: s.drumStyle, instrument: cur.loop.instrument,
                                  bars: max(1, state.engine.pattern.bars), bpm: currentBPM(state))
            if !sampleCrate.contains(where: { $0.id == cur.loop.id }) {
                sampleCrate = Retrieval.rankedLoops(library, req, seed: 0x5A3D)
            }
            let n = sampleCrate.count
            guard n > 1 else { return }
            let at = sampleCrate.firstIndex { $0.id == cur.loop.id } ?? 0
            let far = (0..<n).filter { i in
                let d = abs(i - at)
                return min(d, n - d) > (n > 6 ? 2 : 0)
            }
            guard let pick = far.randomElement() else { return }
            DebugLog.event("random", ["pad": pad.key, "kind": "sample", "pick": pick, "of": n])
            await swapSample(step: pick - at)
        }
    }

    // MARK: Pad swipes

    /// Swipe left / right on a pad: whether there is another sound of its kind to walk to.
    func canSwipeSwap(_ pad: PadID) -> Bool { canSwap(pad) || canSwapSample(pad) }

    /// Swipe right = › (+1), left = ‹ (−1): the next library one-shot of the same type, or for a DIG's chop pad the
    /// next sample under the same beat. One UNDO step (the swap's own checkpoint).
    func swipeSwap(_ pad: PadID, step: Int) async {
        Analytics.shared.tap("pad_swipe_swap", ["pad": pad.key, "dir": step > 0 ? "next" : "prev"])
        DebugLog.event("pad_swipe", ["pad": pad.key, "kind": "swap", "step": step])
        if canSwap(pad) { await swapSound(pad, step: step) } else if canSwapSample(pad) { await swapSample(step: step) }
    }

    /// Swipe up: the pad leaves the beat. Its lanes / notes come out of the pattern and its sound is emptied, as one
    /// UNDO step ("removed A3 · undo brings it back"). An empty pad does nothing.
    func removePad(_ pad: PadID) async {
        guard state.sound(pad) != nil else { return }
        Analytics.shared.tap("pad_swipe_remove", ["pad": pad.key])
        leaveSong()
        checkpoint("remove \(pad.key)")
        digSerial += 1                      // a GPT rewrite still in flight would bring the lane back
        gptTask?.cancel()
        gptTask = nil
        var p = state.engine.pattern
        p.lanes[pad] = nil; p.notes[pad] = nil; p.late[pad] = nil
        state.engine.setPattern(p, timing: .now)
        lastPattern = p
        var bank: [Int: PadSound] = [:]
        for i in 0..<16 where i != pad.index {
            let id = PadID(pad.bank, i)
            if let s = state.engine.sound(for: id) ?? state.sounds[id] { bank[i] = s }
        }
        state.sounds[pad] = nil
        try? await state.engine.loadBank(pad.bank, sounds: bank)
        state.sounds[pad] = nil
        state.addLog("SEQ", "removed \(pad.key) · undo brings it back", tint: .orange)
        DebugLog.event("pad_swipe", ["pad": pad.key, "kind": "remove"])
    }

    // MARK: Session after a project opens

    /// Projects don't store the AI session. Rebuild it from the pads (the library loop behind bank B's chops) and the
    /// saved style label, so ‹ › on a chop, FLIP IT and the bass keep working after a relaunch. Imported songs and
    /// beats without a library sample get no session, as before.
    func restoreSession() {
        if let imported = (0..<16).compactMap({ state.sound(PadID(.d, $0)) }).first(where: { $0.id.hasPrefix("import-library-") }),
           var loop = library.loops.first(where: { library.fileURL($0.file).standardizedFileURL.path == imported.fileURL.standardizedFileURL.path }) {
            loop.id = "import-library-" + loop.id
            let chops = Retrieval.chops(loop, lib: library, bars: max(1, state.engine.pattern.bars))
            let style = Style.allCases.first { library.styleInfo($0).label.uppercased() == state.styleLabel.uppercased() } ?? .dilla
            session = Session(drumStyle: style, sampleStyle: style, bars: chops.spanBars, laidback: 0.5, energy: 0.5,
                              chops: chops, harmony: BassWriter.Harmony(chops))
            CrateUI.shared.flipHint = true
            restoreLayers()
            return
        }
        session = nil
        let chopSounds = (0..<16).compactMap { state.engine.sound(for: PadID(.b, $0)) ?? state.sounds[PadID(.b, $0)] }
        guard let path = chopSounds.first?.fileURL.standardizedFileURL.path,
              let loop = library.loops.first(where: { library.fileURL($0.file).standardizedFileURL.path == path })
        else { return }
        let bars = max(1, state.engine.pattern.bars)
        let chops = Retrieval.chops(loop, lib: library, bars: bars)
        let sampleStyle = Style.allCases.max { loop.style($0) < loop.style($1) } ?? .boombap
        let label = state.styleLabel.uppercased()
        let drumStyle = Style.allCases.first { library.styleInfo($0).label.uppercased() == label } ?? sampleStyle
        session = Session(drumStyle: drumStyle, sampleStyle: sampleStyle, bars: bars, laidback: 0.5, energy: 0.5,
                          chops: chops, harmony: BassWriter.Harmony(chops))
        restoreLayers()
        DebugLog.event("session_restore", ["loop": loop.id, "drum": drumStyle.rawValue, "sample": sampleStyle.rawValue])
    }

    /// Rebuild independent layer allocations from saved pad IDs; audio and patterns are already restored.
    private func restoreLayers() {
        guard var s = session else { return }
        var layers: [Layer] = []
        for bank in [chopBank == .d ? Bank.b : Bank.d, .c] {
            var groups: [String: [Int]] = [:]
            for i in 0..<16 {
                guard let sound = state.sound(PadID(bank, i)), let marker = sound.id.range(of: "#L") else { continue }
                groups[String(sound.id[..<marker.lowerBound]), default: []].append(i)
            }
            for (id, pads) in groups.sorted(by: { ($0.value.min() ?? 0) < ($1.value.min() ?? 0) }) {
                guard let loop = library.loop(id: id) else { continue }
                layers.append(Layer(loopID: id, name: loop.name, bank: bank, pads: pads.sorted(), instrument: loop.instrument))
            }
        }
        s.layers = layers; s.layer = layers.last
        session = s
    }

    // MARK: Sample swap (crate digging)

    /// The beat's sample (bank B chops from a DIG) can be swapped for another library loop; an imported song can't.
    func canSwapSample(_ pad: PadID) -> Bool {
        guard pad.bank == .b, chopBank == .b, let c = session?.chops, let s = state.sound(pad) else { return false }
        return c.sounds.values.contains { $0.fileURL == s.fileURL }
    }

    /// ‹ › on a chop: the previous / next library loop for this beat (same instrument and style, close to the tempo),
    /// chopped onto bank B under the same rhythm while the beat keeps playing. The bass follows the new chords.
    /// One UNDO step each; no GPT round trip, so it's instant.
    func swapSample(step: Int) async {
        Analytics.shared.tap("sample_swap", ["dir": step])
        guard var s = session, let cur = s.chops else { return }
        leaveSong()
        let e = state.engine
        let bars = max(1, e.pattern.bars)
        let req = LoopRequest(sampleStyle: s.sampleStyle, drumStyle: s.drumStyle, instrument: cur.loop.instrument,
                              bars: bars, bpm: currentBPM(state))
        if !sampleCrate.contains(where: { $0.id == cur.loop.id }) {
            sampleCrate = Retrieval.rankedLoops(library, req, seed: 0x5A3D)
        }
        let ranked = sampleCrate
        guard ranked.count > 1 else { return }
        let at = ranked.firstIndex { $0.id == cur.loop.id } ?? (step > 0 ? -1 : 0)
        let next = ranked[((at + step) % ranked.count + ranked.count) % ranked.count]
        checkpoint("sample \(cur.loop.name)")
        digSerial += 1                      // a GPT rewrite still in flight was for the old sample
        gptTask?.cancel()
        gptTask = nil
        let chops = Retrieval.chops(next, lib: library, bars: bars)
        let ms = await loadBanks([(.b, chops.sounds)])
        var p = e.pattern
        // The loop playing straight stays straight with the new sample (its chops sit elsewhere); a flip keeps its
        // rhythm (pads are hero-ordered, so the new sample's heroes take the old heroes' places).
        if chops.spanBars != cur.spanBars || isStraight(p, chops: cur, bank: .b) {
            p.lanes = p.lanes.filter { $0.key.bank != .b }
            p.notes = p.notes.filter { $0.key.bank != .b }
            for (k, v) in PatternBuilder.chops(chops, bars: bars, swing: p.swing) { p.lanes[k] = v }
        }
        let harmony = BassWriter.Harmony(chops)
        if p.notes[PadID(.c, 0)] != nil {
            p.notes[PadID(.c, 0)] = BassWriter.write(rhythm: BassWriter.rhythm(library, style: s.drumStyle), bars: bars,
                                                     harmony: harmony, kicks: PatternBuilder.kickSteps(p.lanes),
                                                     padRoot: bassRoot())
        }
        s.chops = chops
        s.harmony = harmony
        session = s
        setLabels(drum: s.drumStyle, chops: chops)
        setTempo(next.bpm, checkpoint: false)
        e.setPattern(p, timing: e.isPlaying ? .nextBar : .now)
        lastPattern = p
        logSample(chops, bpm: next.bpm, ms: ms)
        if !e.isPlaying { state.hit(state.selectedPad.bank == .b ? state.selectedPad : PadID(.b, 0)) }
        DebugLog.event("sample_swap", ["from": cur.loop.id, "to": next.id, "step": step, "ms": ms])
    }

    // MARK: Trim

    /// Seconds of audio in a pad's source file (cached).
    func sourceDuration(_ s: PadSound) -> Double {
        if let d = Self.durations[s.fileURL] { return d }
        let d = (try? AVAudioFile(forReading: s.fileURL)).map { Double($0.length) / max(1, $0.processingFormat.sampleRate) } ?? 0
        if d > 0 { Self.durations[s.fileURL] = d }
        return d
    }

    private static var durations: [URL: Double] = [:]

    /// A chop slice shares its edges with the slices next to it in time (same file, touching boundaries; FIND puts
    /// heroes on pads 1–8, so the neighbours can be any pad of the bank).
    func sharedEdges(_ pad: PadID) -> (prev: PadSound?, next: PadSound?) {
        let (p, n) = sharedEdgePads(pad)
        return (p.flatMap { state.sound($0) }, n.flatMap { state.sound($0) })
    }

    func sharedEdgePads(_ pad: PadID) -> (prev: PadID?, next: PadID?) {
        guard let s = state.sound(pad) else { return (nil, nil) }
        func near(_ a: Double?, _ b: Double?) -> Bool { a != nil && b != nil && abs(a! - b!) < 0.002 }
        var prev: PadID? = nil, next: PadID? = nil
        for i in 0..<16 where i != pad.index {
            let id = PadID(pad.bank, i)
            guard let x = state.sound(id), x.fileURL == s.fileURL else { continue }
            if prev == nil, near(x.end, s.start) { prev = id }
            if next == nil, near(x.start, s.end) { next = id }
        }
        return (prev, next)
    }

    /// The editor's START / END handles and knobs (seconds in the source file). Moving a slice edge moves the
    /// neighbouring slice's edge with it, like dragging the line between them.
    func trimPad(_ pad: PadID, start: Double? = nil, end: Double? = nil) async {
        guard var s = state.sound(pad) else { return }
        let dur = sourceDuration(s)
        guard dur > 0 else { return }
        var (prev, next) = sharedEdges(pad)
        let (prevPad, nextPad) = sharedEdgePads(pad)
        let oldStart = s.start, oldEnd = s.end ?? dur
        if let t = start {
            let lo = prev.map { $0.start + 0.03 } ?? 0
            s.start = min(oldEnd - 0.02, max(lo, t))
            if prev != nil { prev!.end = s.start }
        }
        if let t = end {
            let hi = next.map { ($0.end ?? dur) - 0.03 } ?? dur
            let e = min(hi, max(s.start + 0.02, t))
            s.end = e >= dur - 0.0005 ? nil : e
            if next != nil { next!.start = e }
        }
        guard abs(s.start - oldStart) > 0.0005 || abs((s.end ?? dur) - oldEnd) > 0.0005 else { return }
        checkpoint("trim \(pad.bank.letter)\(pad.number)")
        var bank: [Int: PadSound] = [:]
        for i in 0..<16 {
            let id = PadID(pad.bank, i)
            if let x = state.engine.sound(for: id) ?? state.sounds[id] { bank[i] = x }
        }
        bank[pad.index] = s
        if let p = prev, let i = prevPad?.index { bank[i] = p }
        if let n = next, let i = nextPad?.index { bank[i] = n }
        _ = await loadBanks([(pad.bank, bank)])
        state.hit(pad)
        state.addLog("EDIT", String(format: "%@%d · %.2f – %.2f s", pad.bank.letter, pad.number, s.start, s.end ?? dur),
                     tint: Self.tint(pad.bank))
        DebugLog.event("trim", ["pad": "\(pad.bank.letter)\(pad.number)", "start": s.start, "end": s.end ?? dur])
    }

    static func tint(_ b: Bank) -> Tint { [.orange, .blue, .ochre, .grey][b.rawValue] }
}
