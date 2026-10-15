import Foundation

/// FIND CHOPS (re-chop the sample, keeping favourite pads) and FLIP IT (an instant rule-based flip, then GPT's,
/// validated) on the session's chop bank: B after a DIG, D after an import. Drums and bass are never touched.
///
/// UI API: `await Orchestrator.current?.rechop(mode: .find)` (each call re-rolls; `.slice16` / `.slice8` = equal
/// slices; `.song` = imported songs: 16 picks across the whole song). Debug: `crate://rechop?mode=find|slice16|slice8|song`,
/// `crate://chopcheck[?b=B|D]`, `crate://flipcheck`.
enum ChopState {
    /// Re-chop rolls so far (each FIND re-roll gets a new seed).
    @MainActor static var rolls: UInt64 = 0
    /// The last flip (for GPT's reference and `crate://flipcheck`).
    @MainActor static var lastFlip: (plan: FlipPlan, chops: [Int: FlipChop], ctx: FlipContext, bank: Bank)?
}

extension Orchestrator {
    // MARK: - FLIP IT

    /// Instant flip from the rules (FlipBuilder), applied on the next bar; then gpt-6-sol's flip swaps in if it passes.
    func flipChops(_ plan: Plan, seed: UInt64, serial: Int) {
        guard let c = session?.chops else { return }
        let bank = chopBank
        let chops = flipChopsOnPads(bank: bank, set: c)
        let ctx = flipContext(bank: bank, set: c)
        guard let local = FlipBuilder.local(Array(chops.values), ctx: ctx, seed: seed) else {
            state.addLog("ERR", "not enough chops to flip — tap a sample first", tint: .red)
            return
        }
        applyFlip(local, chops: chops, bank: bank)
        let st = FlipBuilder.stats(local, chops: chops, ctx: ctx)
        ChopState.lastFlip = (local, chops, ctx, bank)
        state.addLog("FLIP", "▸ \(local.name) · \(local.phraseBars)-bar phrase · \(st.distinct) chops · \(Int(st.rest * 100))% rests"
                     + (st.pitched > 0 ? " · 1 pitched" : "") + (ctx.chordFollow ? " · follows the bass" : ""), tint: .blue)
        DebugLog.event("flip_local", ["name": local.name, "phrase": local.phraseBars, "cycle": local.cycleBars, "rest": st.rest,
                                      "distinct": st.distinct, "beatOne": st.beatOne, "pitched": st.pitched, "clash": st.clash,
                                      "chordFollow": ctx.chordFollow, "events": FlipBuilder.describe(local), "seed": "\(seed)"])
        startFlipGPT(local: local, chops: chops, ctx: ctx, bank: bank, serial: serial)
    }

    /// Chop-bank lanes and notes replaced by the plan (bank B's too: the flip is the sample part now).
    func applyFlip(_ plan: FlipPlan, chops: [Int: FlipChop], bank: Bank) {
        var p = lastPattern
        p.lanes = p.lanes.filter { $0.key.bank != .b && $0.key.bank != bank }
        p.notes = p.notes.filter { $0.key.bank != .b && $0.key.bank != bank }
        let roots = Dictionary(uniqueKeysWithValues: (0..<16).compactMap { i in
            state.sound(PadID(bank, i)).map { (i, $0.rootNote ?? 60) }
        })
        let r = FlipBuilder.render(plan, bars: p.bars, bank: bank, roots: roots)
        for (k, v) in r.lanes { p.lanes[k] = v }
        for (k, v) in r.notes { p.notes[k] = v }
        apply(p, bpm: nil, swing: nil)
    }

    /// The chop bank's pads as the flip sees them: the session's chop info where the pads still hold those chops,
    /// else measured from the audio (trimmed pads, re-chops, projects from before FIND).
    func flipChopsOnPads(bank: Bank, set c: ChopSet) -> [Int: FlipChop] {
        let stepSec = 60 / max(30, state.bpm) / 4
        var ranges: [Int: (start: Double, end: Double)] = [:]
        var url: URL? = nil
        var matches = true
        for i in 0..<16 {
            guard let s = state.sound(PadID(bank, i)), s.category == .chop || s.category == .loop else { continue }
            if url == nil { url = s.fileURL }
            guard s.fileURL == url else { continue }
            let end = s.end ?? (c.info[i]?.end ?? s.start + 0.5)
            ranges[i] = (s.start, end)
            if let f = c.info[i], abs(f.start - s.start) < 0.002, abs(f.end - end) < 0.002 {} else { matches = false }
        }
        var info: [Int: ChopFeature] = [:]
        if matches, !ranges.isEmpty {
            info = c.info.filter { ranges[$0.key] != nil }
        } else if let u = url, let lo = ranges.values.map(\.start).min(), let hi = ranges.values.map(\.end).max(),
                  let sig = try? ChopSignal.load(url: u, start: max(0, lo - 0.05), duration: hi - lo + 0.1) {
            let grid = c.grid ?? ChopGrid(origin: 0, stepSec: 60 / max(1, c.loop.bpm) / 4)
            info = Chopper.describe(sig, grid: grid, ranges: ranges)
        }
        var out: [Int: FlipChop] = [:]
        for (i, f) in info { out[i] = FlipChop(pad: i, steps: (f.end - f.start) / stepSec, feature: f) }
        return out
    }

    /// What's under the flip: chord-follow when a bass plays the sample's chords (bank B with a C1 bassline).
    func flipContext(bank: Bank, set c: ChopSet) -> FlipContext {
        let harmony = BassWriter.Harmony(c)
        let hasBass = !(lastPattern.notes[PadID(.c, 0)] ?? []).isEmpty && bank == .b
        let known = c.chords.contains { $0 != nil } || !c.bassPerBeat.isEmpty
        let chords: [ChordInfo?] = (0..<max(1, c.spanBars)).map { b in
            if let x = c.chords[safe: b] ?? nil { return x }
            guard !c.bassPerBeat.isEmpty else { return nil }
            let r = harmony.root(bar: b)
            return ChordInfo(pc: r.pc, minor: r.minor, symbol: Music.noteNames[r.pc] + (r.minor ? "m" : ""))
        }
        let key = Music.parseKey(state.scaleKey) ?? c.keyPC.map { ($0, c.keyMinor) }
        return FlipContext(bars: max(1, lastPattern.bars), span: max(1, c.spanBars), chordFollow: hasBass && known && c.spanBars > 1,
                           chords: chords, key: key, laidback: session?.laidback ?? 0.5, bpm: state.bpm)
    }

    // MARK: GPT

    func startFlipGPT(local: FlipPlan, chops: [Int: FlipChop], ctx: FlipContext, bank: Bank, serial: Int) {
        guard openAI.available else { return }
        let barsToWrite = ctx.chordFollow ? local.cycleBars : min(ctx.bars, 2)
        let msg = flipMessage(local: local, chops: chops, ctx: ctx, barsToWrite: barsToWrite)
        let model = OpenAIClient.flipModel
        gptTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.openAI.flip(msg, model: model, timeout: 16)
            guard !Task.isCancelled, serial == self.digSerial else { return }
            switch result {
            case .success(let (arr, ms)):
                let items = arr.chops.map { FlipBuilder.GPTChop(bar: $0.bar, step: $0.step, slice: $0.slice, len: $0.len, pitch: $0.pitch) }
                let r = FlipBuilder.fromGPT(items, chops: chops, ctx: ctx, local: local, barsWritten: barsToWrite)
                if var plan = r.plan {
                    plan.name = arr.title.isEmpty ? "AI flip" : arr.title
                    self.applyFlip(plan, chops: chops, bank: bank)
                    let st = FlipBuilder.stats(plan, chops: chops, ctx: ctx)
                    ChopState.lastFlip = (plan, chops, ctx, bank)
                    self.state.addLog("FLIP", "▸ AI flip · \(st.distinct) chops · in on the next bar", ms: ms, tint: .blue)
                    let what = arr.comment.isEmpty ? plan.name.lowercased() : arr.comment
                    self.state.addLog("GPT", "✓ \(what)", ms: ms, tint: .orange)
                    self.state.setStatus(.done, what)
                    DebugLog.event("gpt", ["model": model, "ms": ms, "ok": true, "title": arr.title, "comment": arr.comment,
                                           "chops": arr.chops.count, "flip": true, "rest": st.rest, "distinct": st.distinct,
                                           "repairs": r.repairs, "events": FlipBuilder.describe(plan)])
                } else {
                    self.state.addLog("GPT", "kept the instant flip", ms: ms, tint: .grey)
                    self.state.setStatus(.done, "kept the instant flip")
                    DebugLog.event("gpt", ["model": model, "ms": ms, "ok": false, "flip": true, "reject": r.reject ?? "",
                                           "repairs": r.repairs])
                }
            case .failure(let err):
                self.state.addLog("GPT", "kept the instant flip", tint: .grey)
                self.state.setStatus(.done, "kept the instant flip")   // quiet: the instant flip is a real flip
                DebugLog.event("gpt", ["model": model, "ms": -1, "ok": false, "flip": true])
                DebugLog.event("error", ["where": "gpt_flip", "msg": String(err.description.prefix(300))])
            }
            self.gptTask = nil
        }
    }

    /// The flip prompt's input: per-chop features, the rules' constraints (allowed chops per bar), the drums to play
    /// around and the instant flip to beat.
    func flipMessage(local: FlipPlan, chops: [Int: FlipChop], ctx: FlipContext, barsToWrite: Int) -> [String: Any] {
        func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        let list: [[String: Any]] = chops.keys.sorted().compactMap { i in
            guard let c = chops[i] else { return nil }
            let chord = (ctx.chords[safe: c.srcBar % max(1, ctx.span)] ?? nil)?.symbol
            return ["slice": i, "lenSteps": (c.steps * 10).rounded() / 10, "energy": r2(c.energy), "attack": r2(c.attack),
                    "tonal": r2(c.tonal), "pitch": Music.noteNames[c.pc], "chord": chord.map { $0 as Any } ?? NSNull(),
                    "srcBar": c.srcBar, "role": c.hero ? "hero" : "support"]
        }
        let usable = Array(chops.values).filter { $0.energy >= 0.12 }
        let allowed: Any = ctx.chordFollow ? (0..<barsToWrite).map { FlipBuilder.pool(usable, bar: $0, ctx: ctx).map(\.pad) } : NSNull()
        var drums: [String: [String]] = [:]
        for lane in ["kick", "snare", "clap"] {
            guard let pad = BankA.pad(forLane: lane), let hits = lastPattern.lanes[pad], !hits.isEmpty else { continue }
            drums[lane] = (0..<barsToWrite).map { b in
                String((0..<16).map { s in hits.contains { $0.step == b * 16 + s } ? "x" : "." })
            }
        }
        let instant = local.events.filter { $0.step < barsToWrite * 16 }.map { [$0.step / 16, $0.step % 16, $0.pad, $0.pitch] }
        return ["bpm": Int(state.bpm.rounded()), "key": state.scaleKey ?? "unknown", "style": session?.drumStyle.rawValue ?? "dilla",
                "barsToWrite": barsToWrite, "chops": list, "allowedPerBar": allowed, "drums": drums,
                "instant": instant, "units": "steps are 16th notes; bar = 16 steps; instant = [bar, step, slice, pitch]"]
    }

    // MARK: - FIND CHOPS (re-chop)

    /// Re-chops the session's sample onto its chop bank (one UNDO step). `.find` re-rolls each call; favourite pads
    /// (PadSound.params.favorite, when the build has it) stay. A loop playing straight stays straight on the new chops;
    /// a flip keeps its rhythm.
    func rechop(mode: ChopMode) async {
        guard var s = session, let cur = s.chops else {
            state.addLog("ERR", "nothing to chop yet — dig a sample or ＋ a song", tint: .red)
            return
        }
        leaveSong()
        let bank = chopBank
        let keep = favoritePads(bank)
        ChopState.rolls &+= 1
        let seed = mode == .find || mode == .song ? ChopState.rolls &* 0x9E37_79B9 : 0
        checkpoint("chop \(mode.rawValue)")
        digSerial += 1
        gptTask?.cancel()
        gptTask = nil
        let t0 = Date()
        let next: ChopSet?
        if importedFlip {
            let url = URL(fileURLWithPath: cur.loop.file)
            let label = cur.loop.name
            let known = Self.songPlans[cur.loop.file]
            let bpm = cur.loop.bpm, bars = cur.spanBars
            next = await Task.detached(priority: .userInitiated) { () -> ChopSet? in
                var plan = known
                if plan == nil, let sig = try? ChopSignal.load(url: url, start: 0, duration: ChopSignal.songSeconds) {
                    plan = SongRegion.plan(sig, bpmHint: bpm, barsHint: bars)
                }
                guard let p = plan else { return nil }
                return Orchestrator.importSet(url: url, label: label, plan: p, mode: mode, seed: seed, keep: keep)
            }.value
        } else {
            next = Retrieval.chops(cur.loop, lib: library, bars: cur.spanBars, mode: mode, seed: seed, keep: keep)
        }
        guard let set = next else {
            state.addLog("ERR", "couldn't re-chop this sample", tint: .red)
            return
        }
        let ms = await loadBanks([(bank, set.sounds)])
        let e = state.engine
        var p = lastPattern
        if isStraight(p, chops: cur, bank: bank) {
            p.lanes = p.lanes.filter { $0.key.bank != bank }
            p.notes = p.notes.filter { $0.key.bank != bank }
            for (k, v) in PatternBuilder.chops(set, bars: p.bars, swing: p.swing, bank: bank) { p.lanes[k] = v }
            e.setPattern(p, timing: e.isPlaying ? .nextBar : .now)
            lastPattern = p
        }
        s.chops = set
        session = s
        if !e.isPlaying { state.hit(PadID(bank, keep[0] == nil ? 0 : (0..<16).first { keep[$0] == nil } ?? 0)) }
        let label = ["find": "FIND CHOPS", "slice16": "16 SLICES", "slice8": "8 SLICES", "song": "WHOLE SONG"][mode.rawValue] ?? mode.rawValue
        state.addLog("CHOP", "▸ \(label) · \(set.sounds.count) pads" + (mode == .find || mode == .song ? " · best on \(bank.letter)1–\(bank.letter)8" : "")
                     + (keep.isEmpty ? "" : " · kept ★\(keep.count)"), ms: Self.ms(t0), tint: .blue)
        DebugLog.event("rechop", ["mode": mode.rawValue, "bank": bank.letter, "kept": keep.keys.sorted().map { $0 + 1 },
                                  "pads": set.sounds.count, "ms": Self.ms(t0), "loadMs": ms, "seed": "\(seed)"])
    }

    /// Drag of the line between two slices that touch in time (CHOP waveform): `left` ends and `right` starts at `t`.
    func moveChopBoundary(bank: Bank, left: Int, right: Int, to t: Double) {
        guard left != right, var a = state.sound(PadID(bank, left)), var b = state.sound(PadID(bank, right)),
              a.fileURL == b.fileURL else { return }
        let t = min((b.end ?? .infinity) - 0.03, max(a.start + 0.03, t))
        guard abs(t - b.start) > 0.002 else { return }
        checkpoint("slice \(right + 1) start")
        a.end = t
        b.start = t
        var sounds: [Int: PadSound] = [:]
        for i in 0..<16 { if let x = state.sound(PadID(bank, i)) { sounds[i] = x } }
        sounds[left] = a
        sounds[right] = b
        state.sounds[PadID(bank, left)] = a
        state.sounds[PadID(bank, right)] = b
        let e = state.engine
        Task { @MainActor in
            try? await e.loadBank(bank, sounds: sounds)
            state.hit(PadID(bank, right))
        }
        state.addLog("CHOP", String(format: "%@%d starts at %.2f s", bank.letter, right + 1, t), tint: .blue)
        DebugLog.event("slice_move", ["bank": bank.letter, "left": left, "right": right, "t": t])
    }

    /// The chop bank plays the chops in their original order (DIG's sample), not a flip.
    func isStraight(_ p: Pattern, chops c: ChopSet, bank: Bank) -> Bool {
        let lanes = p.lanes.filter { $0.key.bank == bank }
        guard !lanes.isEmpty, p.notes.allSatisfy({ $0.key.bank != bank || $0.value.isEmpty }) else { return false }
        return lanes == PatternBuilder.chops(c, bars: p.bars, swing: p.swing, bank: bank)
    }

    /// Pads marked favourite (★) in the pad editor. Read by reflection so this builds with or without
    /// `PadSound.params.favorite`.
    func favoritePads(_ bank: Bank) -> [Int: PadSound] {
        var out: [Int: PadSound] = [:]
        for i in 0..<16 {
            guard let s = state.sound(PadID(bank, i)) else { continue }
            if Self.isFavorite(s) { out[i] = s }
        }
        return out
    }

    nonisolated static func isFavorite(_ s: PadSound) -> Bool {
        for child in Mirror(reflecting: s).children {
            if child.label == "favorite", let b = child.value as? Bool { return b }
            if child.label == "params" {
                for c in Mirror(reflecting: child.value).children where c.label == "favorite" { return (c.value as? Bool) ?? false }
            }
        }
        return false
    }

    // MARK: - Debug checks

    /// `crate://chopcheck`: per chop start, length, energy and whether it starts on the grid / an attack / a zero
    /// crossing, plus the set's mid-note and distinct-material scores (ChopMetrics).
    func chopCheck(bank requested: Bank?) {
        let bank = requested ?? chopBank
        var pads: [Int: (start: Double, end: Double)] = [:]
        var url: URL? = nil
        for i in 0..<16 {
            guard let s = state.sound(PadID(bank, i)) else { continue }
            if url == nil { url = s.fileURL }
            guard s.fileURL == url else { continue }
            pads[i] = (s.start, s.end ?? s.start + 1)
        }
        guard let u = url, let lo = pads.values.map(\.start).min(), let hi = pads.values.map(\.end).max(),
              let sig = try? ChopSignal.load(url: u, start: max(0, lo - 0.2), duration: hi - lo + 0.4) else {
            DebugLog.event("chopcheck", ["bank": bank.letter, "error": "no chops"])
            return
        }
        let c = session?.chops
        let grid = (c?.sounds.values.contains { $0.fileURL == u } ?? false ? c?.grid : nil)
            ?? ChopGrid(origin: lo, stepSec: 60 / max(30, state.bpm) / 4)
        let r = ChopMetrics.measure(sig, grid: grid, pads: pads)
        for ch in r.chops {
            DebugLog.event("chopcheck_pad", ["pad": "\(bank.letter)\(ch.pad + 1)", "start": (ch.start * 1000).rounded() / 1000,
                                             "len": (ch.length * 1000).rounded() / 1000, "energyDB": (ch.energyDB * 10).rounded() / 10,
                                             "onGrid": ch.onGrid, "nearOnset": ch.nearOnset, "zeroCross": ch.zeroCross,
                                             "midNote": ch.midNote, "hero": c?.info[ch.pad]?.hero ?? false])
        }
        var summary = r.summary
        summary["bank"] = bank.letter
        summary["file"] = u.lastPathComponent
        DebugLog.event("chopcheck", summary)
        let p = r.pct
        state.addLog("CHOP", String(format: "check · attack %.0f%% · zero %.0f%% · grid %.0f%% · mid-note %.0f%% · distinct %.2f",
                                    p.onset, p.zero, p.grid, p.midNote, r.distinct), tint: .grey)
    }

    /// `crate://flipcheck`: the flip now playing (rests, distinct chops, beat 1, pitched hits, clashes with the bass).
    func flipCheck() {
        guard let f = ChopState.lastFlip else { DebugLog.event("flipcheck", ["error": "no flip"]); return }
        let st = FlipBuilder.stats(f.plan, chops: f.chops, ctx: f.ctx)
        let drums = lastPattern.lanes.filter { $0.key.bank == .a }.values.reduce(0) { $0 + $1.count }
        DebugLog.event("flipcheck", ["name": f.plan.name, "bank": f.bank.letter, "rest": st.rest, "distinct": st.distinct,
                                     "beatOne": st.beatOne, "pitched": st.pitched, "clash": st.clash, "cycle": f.plan.cycleBars,
                                     "drumHits": drums, "bass": lastPattern.notes[PadID(.c, 0)]?.count ?? 0,
                                     "events": FlipBuilder.describe(f.plan)])
    }
}
