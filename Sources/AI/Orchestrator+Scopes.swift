import Foundation

extension Orchestrator {
    // MARK: - partial scopes

    /// drums_only: new bank A + drum lanes; chops, bass and tempo keep playing.
    func buildDrums(_ plan: Plan, seed: UInt64, variant: Int, serial: Int, report: inout DigReport) async {
        let ds = plan.drumStyle ?? plan.sampleStyle ?? session?.drumStyle ?? .boombap
        let bars = plan.bars ?? (session != nil ? lastPattern.bars : 4)
        let laid = plan.laidback ?? PatternBuilder.defaultLaidback(ds)
        let tR = Date()
        let target = Retrieval.kitTarget(library, style: ds, vintage: plan.vintage, brightness: plan.brightness, energy: plan.energy)
        let kit = Retrieval.kit(library, style: ds, target: target, seed: seed)
        report.retrievalMs = Self.ms(tR)
        report.kitIDs = (0..<16).compactMap { kit[$0]?.id }
        logKit(ds, kit, ms: report.retrievalMs)
        // Imported-song flip: drums join at the flip tempo and a bass enters in the song's key (bank C loads if it's new).
        let flipBass = importedFlip && lastPattern.notes[PadID(.c, 0)] == nil
        let bankC = flipBass ? Retrieval.bankC(library, style: ds, target: target, seed: seed) : [:]
        report.loadMs = await loadBanks([(.a, kit), (.c, bankC)])
        guard serial == digSerial else { return }
        let groove = PatternBuilder.groove(library, style: ds, seed: seed)
        if session?.drumStyle != ds { BassWriter.pickRhythm(library, style: ds, seed: seed) }
        let swing = PatternBuilder.swing(style: ds, groove: groove, laidback: laid, lib: library)
        var p = session != nil ? PatternBuilder.retile(lastPattern, to: bars) : Pattern(bars: bars)
        p.swing = swing
        p.lanes = p.lanes.filter { $0.key.bank != .a }
        p.late = p.late.filter { $0.key.bank != .a }
        if let g = groove { for (k, v) in PatternBuilder.drums(g, bars: bars, laidback: laid) { p.lanes[k] = v } }
        let bpm: Double? = session?.chops != nil ? nil : (plan.bpm ?? tempoBpm(plan.tempo, style: ds))
        if var s = session {
            s.drumStyle = ds; s.laidback = laid; s.energy = plan.energy ?? s.energy
            session = s
        } else {
            session = Session(drumStyle: ds, sampleStyle: plan.sampleStyle ?? ds, bars: bars, laidback: laid,
                              energy: plan.energy ?? 0.55, chops: nil, harmony: BassWriter.Harmony(keyPC: 9))
        }
        state.styleLabel = library.styleInfo(ds).label
        let withBass = importedFlip && (flipBass || p.notes[PadID(.c, 0)] != nil)
        if withBass, let h = session?.harmony {
            p.notes[PadID(.c, 0)] = BassWriter.write(rhythm: BassWriter.rhythm(library, style: ds), bars: bars, harmony: h,
                                                     kicks: PatternBuilder.kickSteps(p.lanes), padRoot: bassRoot())
        }
        logReference(plan, style: ds, bpm: bpm ?? state.bpm)
        apply(p, bpm: bpm, swing: swing)
        if withBass {
            state.addLog("BASS", "\(ds.rawValue) rule bass · \(bassSoundName()) · \(state.scaleKey ?? "key") · \(session?.chops?.chordsLabel ?? "")",
                         tint: .ochre)
        }
        startGPT(plan, take: withBass ? [.drums, .bass] : [.drums], flip: false, serial: serial)
    }

    /// sample_only: new loop → bank B chops + a rule bass over its chords; drums keep playing (tempo follows the loop).
    func buildSample(_ plan: Plan, seed: UInt64, variant: Int, serial: Int, report: inout DigReport) async {
        guard var s = session else { return }
        let ss = plan.sampleStyle ?? plan.drumStyle ?? s.sampleStyle
        let bars = plan.bars ?? lastPattern.bars
        let tR = Date()
        let req = LoopRequest(sampleStyle: ss, drumStyle: s.drumStyle, instrument: plan.instrument, mood: plan.mood, bars: bars,
                              bpm: plan.bpm, excludeID: s.chops?.loop.id, vibes: Vibes.from(plan.prompt))
        guard let loop = Retrieval.loop(library, req, seed: seed) else {
            state.addLog("ERR", "no \(plan.instrument) loop in the crates", tint: .red)
            return
        }
        let chops = Retrieval.chops(loop, lib: library, bars: bars)
        report.retrievalMs = Self.ms(tR)
        report.loopID = loop.id
        report.loadMs = await loadBanks([(.b, chops.sounds)])
        guard serial == digSerial else { return }
        var p = PatternBuilder.retile(lastPattern, to: bars)
        p.lanes = p.lanes.filter { $0.key.bank != .b }
        for (k, v) in PatternBuilder.chops(chops, bars: bars, swing: p.swing) { p.lanes[k] = v }
        let harmony = BassWriter.Harmony(chops)
        if p.notes[PadID(.c, 0)] != nil || (plan.wantsBass ?? 0) > 0.5 {
            p.notes[PadID(.c, 0)] = BassWriter.write(rhythm: BassWriter.rhythm(library, style: s.drumStyle), bars: bars, harmony: harmony,
                                                     kicks: PatternBuilder.kickSteps(p.lanes), padRoot: bassRoot())
        }
        s.sampleStyle = ss; s.chops = chops; s.harmony = harmony
        session = s
        setLabels(drum: s.drumStyle, chops: chops)
        apply(p, bpm: loop.bpm, swing: nil)
        logSample(chops, bpm: loop.bpm, ms: report.loadMs)
        startGPT(plan, take: [.bass], flip: false, serial: serial)
    }

    /// bass_only: instant rule bass (style rhythm rotates on repeat digs), GPT rewrites it.
    func buildBass(_ plan: Plan, variant: Int, serial: Int) {
        guard let s = session else { return }
        let rotation: [Style] = [.jazzhop, .vintage, .boombap, .rnb, .lofi, .dilla].filter { $0 != s.drumStyle }
        let walking = plan.prompt.lowercased().contains("walking")
        let style = plan.drumStyle ?? (walking ? .jazzhop : rotation[variant % rotation.count])
        var p = lastPattern
        p.notes[PadID(.c, 0)] = BassWriter.write(rhythm: BassWriter.rhythm(library, style: style), bars: p.bars, harmony: s.harmony,
                                                 kicks: PatternBuilder.kickSteps(p.lanes), padRoot: bassRoot())
        apply(p, bpm: nil, swing: nil)
        state.addLog("BASS", "\(style.rawValue) rule bass · \(s.chops?.chordsLabel ?? "key root")", tint: .ochre)
        startGPT(plan, take: [.bass], flip: false, serial: serial)
    }

    /// change_groove: instant local swing/late push in the asked direction, then GPT rewrites the drums + bass.
    func changeGroove(_ plan: Plan, serial: Int) {
        guard var s = session else { return }
        var p = lastPattern
        let text = plan.prompt.lowercased()
        let tighter = KeywordParser.hasAny(["tight", "tighter", "quantized", "quantize", "straight", "stiff", "less swing",
                                            "less laid back", "on grid", "rigid"], text)
        let looser = KeywordParser.hasAny(["laid back", "laid-back", "laidback", "looser", "loose", "drunk", "lazy", "swing more",
                                           "more swing", "behind", "wonky", "sloppy"], text)
        let dir: Double = tighter ? -1 : (looser || (plan.laidback ?? 0.5) >= 0.5) ? 1 : -1
        let swing = min(66, max(50, p.swing + dir * 4))
        p.swing = swing
        for (i, amount) in [(2, 0.08), (3, 0.08), (4, 0.04), (5, 0.04), (6, 0.04)] {
            let pad = PadID(.a, i)
            guard p.lanes[pad] != nil else { continue }
            p.late[pad] = max(-0.1, min(0.3, (p.late[pad] ?? 0) + dir * amount))
        }
        s.laidback = max(0, min(1, s.laidback + dir * 0.2))
        if let e = plan.energy { s.energy = e }
        session = s
        apply(p, bpm: nil, swing: swing)
        state.addLog("GROOVE", String(format: "%@ · swing %.0f%% · snare late %+.2f", dir > 0 ? "LAID BACK" : "TIGHTER", swing,
                                      p.late[PadID(.a, 2)] ?? p.late[PadID(.a, 3)] ?? 0), tint: .orange)
        // Feel requests ("more swing", "tighter") are done by the instant edit above. Only requests for new drum
        // ideas ("busier", "add fills", "switch it up") go to GPT, and it may rewrite the drums only: never the bass.
        let ideas = KeywordParser.hasAny(["busier", "busy", "simpler", "fill", "fills", "vary", "variation", "switch it up",
                                          "remix", "half time", "halftime", "change the drums", "change the groove", "bounce"], text)
        if ideas { startGPT(plan, take: [.drums], flip: false, serial: serial) }
    }

    /// single_sound: Jev `route` → category → best library match onto the selected pad (auditioned).
    func singleSound(_ plan: Plan, seed: UInt64, report: inout DigReport) async {
        var category = plan.category
        // The prompt named the drum ("punchier snare"): that's the pad, whatever Jev's router guesses.
        if category == nil, jev.available, let r = await jev.ask("route", state: "Sound description: \"\(plan.prompt)\"", timeout: 0.9),
           let a = r.answers["category"], let c = a.choice, a.choiceProb > 0.3 {
            category = c
        }
        let cat = category ?? "perc"
        let style = session?.drumStyle ?? plan.drumStyle ?? .boombap
        let pad = singleSoundPad(cat)
        let current = (state.engine.sound(for: pad) ?? state.sounds[pad])?.id
        guard let snd = Retrieval.single(library, category: cat, style: style, prompt: plan.prompt, seed: seed,
                                         exclude: current) else {
            state.addLog("ERR", "no \(cat) in the crates", tint: .red)
            return
        }
        var bank: [Int: PadSound] = [:]
        for i in 0..<16 {
            let id = PadID(pad.bank, i)
            if let s = state.engine.sound(for: id) ?? state.sounds[id] { bank[i] = s }
        }
        bank[pad.index] = snd
        report.kitIDs = [snd.id]
        report.loadMs = await loadBanks([(pad.bank, bank)])
        state.bank = pad.bank
        state.selectedPad = pad          // the pad line shows it, so ‹ › keeps browsing from here
        state.engine.trigger(pad, velocity: 110, semitones: 0)
        state.addLog("KIT", "PAD \(pad.bank.letter)\(pad.number) ← \(snd.name) (\(cat))", ms: report.loadMs, tint: .orange)
        DebugLog.event("kit", ["style": style.rawValue, "ids": [snd.id], "pad": "\(pad.bank.letter)\(pad.number)"])
    }

    /// Where a described sound goes: the selected pad if it already holds that kind of sound ("punchier" with the
    /// snare selected), else that instrument's home: its bank-A drum slot, or the bank-C pad holding (or meant for)
    /// bass / keys / synth. Anything else lands on the selected pad.
    func singleSoundPad(_ cat: String) -> PadID {
        if let fp = forcedPad { return fp }
        let sel = state.selectedPad
        func category(_ p: PadID) -> String? { (state.engine.sound(for: p) ?? state.sounds[p])?.category.rawValue }
        if category(sel) == cat { return sel }
        if let i = BankA.slots.firstIndex(of: cat) { return PadID(.a, i) }
        let homes = ["bass": 0, "keys": 1, "synth": 2]
        if let home = homes[cat] {
            if let i = (0..<16).first(where: { category(PadID(.c, $0)) == cat }) { return PadID(.c, i) }
            return PadID(.c, home)
        }
        return sel
    }

    /// flip: an instant rule-based flip of the chops (drums + bass untouched), then gpt-6-sol's, validated, on the
    /// next bar (Orchestrator+Chop.swift).
    func flip(_ plan: Plan, seed: UInt64, serial: Int) {
        guard session?.chops != nil else {
            state.addLog("ERR", "nothing to flip yet — dig a sample first", tint: .red)
            return
        }
        flipChops(plan, seed: seed, serial: serial)
    }

    func bassSoundName() -> String {
        (state.engine.sound(for: PadID(.c, 0)) ?? state.sounds[PadID(.c, 0)])?.name ?? "bass"
    }

    func bassRoot() -> Int? {
        (state.engine.sound(for: PadID(.c, 0)) ?? state.sounds[PadID(.c, 0)])?.rootNote
    }

    // MARK: - GPT (background, swapped in on the next bar)

    func startGPT(_ plan: Plan, take: Set<ArrangePart>, flip: Bool, serial: Int) {
        guard openAI.available, let s = session else { return }
        let model = flip ? OpenAIClient.flipModel : OpenAIClient.arrangeModel
        let msg = arrangeMessage(plan, session: s, flip: flip)
        let bars = lastPattern.bars
        let root = bassRoot()
        gptTask = Task { [weak self] in
            guard let self else { return }
            // GPT only upgrades a beat that's already playing, so give phones on cellular room (8 s missed often).
            let result = await self.openAI.arrange(msg, model: model, timeout: flip ? 16 : 14)
            guard !Task.isCancelled, serial == self.digSerial else { return }
            switch result {
            case .success(let (arr, ms)):
                self.lastArrangement = arr
                var p = OpenAIClient.pattern(from: arr, base: self.lastPattern, bars: bars, take: take, bassRoot: root,
                                             style: self.session?.drumStyle)
                let chopBank = self.chopBank
                if take.contains(.chops), chopBank != .b { p = Self.moveChops(p, to: chopBank) }
                self.apply(p, bpm: nil, swing: take.contains(.drums) ? p.swing : nil)
                if take.contains(.chops), chopBank != .b {
                    self.state.addLog("FLIP", "▸ AI re-flip · \(arr.chops?.count ?? 0) chops · in on the next bar", ms: ms, tint: .blue)
                }
                self.state.gptSeconds = Double(ms) / 1000
                let what = arr.comment.isEmpty ? arr.title.lowercased() : arr.comment
                self.state.addLog("GPT", "✓ \(what)", ms: ms, tint: .orange)
                self.state.setStatus(.done, what)
                self.gptTask = nil
                if let c = self.changeCtx, c.serial == serial {
                    self.recordChange(id: c.id, prompt: c.prompt, scope: c.scope, before: c.before, gpt: true, ms: ms)
                }
                DebugLog.event("gpt", ["model": model, "ms": ms, "ok": true, "title": arr.title, "comment": arr.comment,
                                       "drums": arr.drums.count, "bass": arr.bass.count, "chops": arr.chops?.count ?? 0,
                                       "chords": arr.chords?.count ?? 0])
            case .failure(let err):
                DebugLog.event("error", ["where": "gpt", "msg": String(err.description.prefix(200))])
                self.state.addLog("GPT", "kept the instant version", tint: .grey)
                Analytics.shared.track("ai_gpt_failed", ["model": model, "msg": String(err.description.prefix(120))])
                self.state.setStatus(.done, "kept the instant version")   // quiet: no network = the instant beat
                self.gptTask = nil
                DebugLog.event("gpt", ["model": model, "ms": -1, "ok": false])
                DebugLog.event("error", ["where": "gpt", "msg": String(err.description.prefix(300))])
            }
        }
    }

    func arrangeMessage(_ plan: Plan, session s: Session, flip: Bool) -> [String: Any] {
        var sample: Any = NSNull()
        if let c = s.chops {
            sample = ["name": c.loop.name, "instrument": c.loop.instrument, "key": c.loop.key ?? "unknown", "bars": c.spanBars,
                      "chordsPerBar": c.chords.map { ($0?.symbol).map { $0 as Any } ?? NSNull() },
                      "bassPerBeat": c.bassPerBeat.map { $0.map { $0 as Any } ?? NSNull() }] as [String: Any]
        }
        var msg: [String: Any] = ["request": plan.prompt, "style": s.drumStyle.rawValue, "sampleStyle": s.sampleStyle.rawValue,
                "bpm": Int(state.bpm.rounded()), "swing": Int(state.swing.rounded()), "bars": lastPattern.bars,
                "laidback": (s.laidback * 100).rounded() / 100, "energy": (s.energy * 100).rounded() / 100,
                "lanesAvailable": Array(BankA.slots.prefix(12)), "template": PatternBuilder.laneStrings(lastPattern),
                "sample": sample, "flip": flip,
                "units": "bass.len, chops.len and chords.len are in 16th-note steps (4 steps = 1 beat); bar strings are 16 steps"]
        if let pr = s.chordProg, s.chops == nil {
            msg["harmony"] = ["key": pr.key, "chordsPerBar": pr.chords.map(\.symbol), "voicings": pr.chords.map(\.voicing),
                              "stabSteps": [2, 6, 10, 14], "stabLen": 2] as [String: Any]
        }
        return msg
    }

    // MARK: - log lines

    func logPlan(_ plan: Plan, kwMs: Int) {
        let jevd = plan.source == "jev"
        let d = plan.drumStyle.map { library.styleInfo($0).label } ?? "—"
        let s = plan.sampleStyle.map { library.styleInfo($0).label } ?? "—"
        let scope = plan.scope.rawValue.replacingOccurrences(of: "_", with: " ")
        let styled = [.fullBeat, .drumsOnly, .sampleOnly].contains(plan.scope) && (plan.drumStyle != nil || plan.sampleStyle != nil)
        let text = scope + (styled ? " · \(d) × \(s)" : "") + (plan.instrument == "any" ? "" : " · \(plan.instrument)")
            + (plan.bars.map { " · \($0) BARS" } ?? "")
        state.addLog(jevd ? "JEV" : "KW", text, ms: jevd ? plan.jevMs : kwMs, tint: jevd ? .orange : .grey)
        DebugLog.event("jev_plan", ["ms": plan.jevMs ?? -1, "source": plan.source, "scope": plan.scope.rawValue,
                                    "drum_style": plan.drumStyle?.rawValue ?? "", "sample_style": plan.sampleStyle?.rawValue ?? "",
                                    "instrument": plan.instrument, "bars": plan.bars ?? -1, "laidback": plan.laidback ?? -1,
                                    "vintage": plan.vintage ?? -1, "energy": plan.energy ?? -1, "overrides": plan.jevOverrides,
                                    "bpm": plan.bpm ?? -1, "reference": plan.reference ?? ""])
    }

    func logKit(_ style: Style, _ kit: [Int: PadSound], ms: Int) {
        let names = [0, 2, 4].compactMap { kit[$0]?.name }.joined(separator: " / ")
        state.addLog("KIT", "\(library.styleInfo(style).label) · \(names)", ms: ms, tint: .orange)
        DebugLog.event("kit", ["style": style.rawValue, "ids": (0..<16).compactMap { kit[$0]?.id },
                               "sources": [0, 2, 4].compactMap { kit[$0]?.source }])
    }

    func logSample(_ c: ChopSet, bpm: Double, ms: Int) {
        state.addLog("SAMPLE", "\(c.loop.name) · \(c.loop.instrument) · \(c.loop.key ?? "?") · \(Int(bpm)) BPM · \(c.spanBars) BAR CHOPS",
                     ms: ms, tint: .blue)
        DebugLog.event("loop", ["id": c.loop.id, "bpm": c.loop.bpm, "key": c.loop.key ?? "", "bars": c.spanBars,
                                "instrument": c.loop.instrument, "name": c.loop.name, "chords": c.chordsLabel])
    }
}
