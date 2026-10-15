import Foundation

/// SONG arranging (FL-Studio style, a bank × section grid; model in Core/Arrangement.swift).
///
/// PATTERN mode plays the live pattern = every bank's *edit* variation, so the AI scopes, step taps, REC and KEEP JAM
/// keep editing it unchanged; `syncFromPattern()` copies it into `state.song.variations` before anything reads the
/// variations. SONG mode renders the sections into one long pattern on the engine and leaves `lastPattern` (the AI's
/// copy of the PATTERN-mode beat) alone: anything that edits the beat first goes back to PATTERN mode (`leaveSong`).
///
/// ✦ ARRANGE (`arrangeSong`) builds a whole song from the beat in one tap: local, instant, one UNDO step.
/// Debug: `crate://song?mode=1|0`, `crate://arrange`, `crate://cell?s=2&b=a&v=1`, `crate://songlog`,
/// `crate://section?i=2&cmd=play|dup|del|bars&n=8|name&v=DROP`, `crate://songvar?b=a&cmd=new|edit|clear&n=2`.
extension Orchestrator {
    // MARK: - Live pattern ⇄ variations

    /// PATTERN mode: the live pattern's per-bank content becomes each bank's edit variation (variation 1 appears
    /// when a bank first gets content). SONG mode: nothing to do, the variations are what's playing.
    func syncFromPattern() {
        guard !state.song.songMode else { return }
        let p = state.engine.pattern
        var song = state.song
        for b in Bank.allCases {
            let seq = BankSeq.capture(p, bank: b)
            var vars = song.variations[b] ?? []
            if vars.isEmpty && seq.isEmpty { continue }
            let ev = min(song.edit(b), vars.count + 1)
            while vars.count < ev { vars.append(seq) }
            vars[ev - 1] = seq
            song.variations[b] = vars
            song.editVar[b] = ev
        }
        if song != state.song { state.song = song }
    }

    /// A song change wins over a GPT rewrite still in flight (it would land on the engine over the song).
    private func stopBackgroundEdits() {
        digSerial += 1
        if gptTask != nil, state.aiStatus == .arranging { state.setStatus(.done, "kept what's playing") }
        gptTask?.cancel()
        gptTask = nil
    }

    // MARK: - SONG ⇄ PATTERN

    /// SONG mode on: the song grid shows and the engine plays the song (from `bar`, at the next bar line while
    /// playing). `play` also starts the transport when it's stopped. An empty song keeps the loop playing.
    func enterSong(fromBar bar: Int = 0, play: Bool = false, tap: Bool = false) {
        if !state.song.songMode {
            if state.isRecording {
                state.setRecording(false)
                syncFromEngine()
            }
            syncFromPattern()
            lastPattern = state.engine.pattern
            stopBackgroundEdits()
            state.song.songMode = true
            if tap { Analytics.shared.tap("song_mode", ["on": true, "sections": state.song.sections.count]) }
            DebugLog.event("song_mode", ["on": true, "sections": state.song.sections.count, "bars": state.song.totalBars])
        }
        let e = state.engine
        if state.song.sections.isEmpty {
            e.setPattern(lastPattern, timing: .now)
        } else {
            let p = state.song.render(base: lastPattern)
            e.setPattern(p, fromBar: min(max(0, bar), p.bars - 1))
            logRender(p)
        }
        if play && !e.isPlaying {
            e.play()
            state.isPlaying = e.isPlaying
        }
    }

    /// Back to PATTERN mode: the edit pattern plays again (from the bar the pager shows, at the next bar line).
    /// Called by every edit of the beat, so the edit lands on the pattern, never on the rendered song.
    func leaveSong(toBar bar: Int? = nil, tap: Bool = false) {
        guard state.song.songMode else { return }
        state.song.songMode = false
        let p = lastPattern
        let b = min(max(0, bar ?? CrateUI.shared.viewBar ?? 0), max(1, p.bars) - 1)
        state.engine.setPattern(p, fromBar: b)
        state.bars = max(1, p.bars)
        if tap { Analytics.shared.tap("song_mode", ["on": false]) }
        DebugLog.event("song_mode", ["on": false, "bars": p.bars, "hits": PatternBuilder.hitCount(p),
                                     "notes": PatternBuilder.noteCount(p), "tap": tap])
    }

    /// The arrangement changed: re-render. Same length = in place; a different length carries on at the same spot of
    /// the same section on the next bar line (or that section's start if it got shorter, the top if it's gone).
    private func reflow(from old: SongArrangement) {
        guard state.song.songMode else { return }
        let e = state.engine
        let new = state.song
        guard !new.sections.isEmpty else {
            e.setPattern(lastPattern, fromBar: 0)
            return
        }
        let p = new.render(base: lastPattern)
        if old.sections.isEmpty {
            e.setPattern(p, fromBar: 0)
        } else if old.totalBars == new.totalBars {
            e.setPattern(p, timing: .now)
        } else {
            let oldBars = max(1, old.totalBars)
            // the bar that plays next: a cue in flight says where it lands; else the bar after the playhead
            let next = e.isPlaying ? (e.cuedBar() ?? (Int(max(0, e.position()) / 16) + 1)) % oldBars : min(e.startBar, oldBars - 1)
            var target = 0
            if let si = old.section(atBar: next) {
                let off = next - old.starts[si]
                if let ni = new.sections.firstIndex(where: { $0.id == old.sections[si].id }) {
                    target = new.starts[ni] + min(off, max(1, new.sections[ni].bars) - 1)
                } else if si < new.sections.count {
                    target = new.starts[si]
                }
            }
            e.setPattern(p, fromBar: target)
        }
        logRender(p)
    }

    private func logRender(_ p: Pattern) {
        DebugLog.event("song_render", ["sections": state.song.sections.map(\.name), "bars": p.bars,
                                       "hits": PatternBuilder.hitCount(p), "notes": PatternBuilder.noteCount(p)])
    }

    // MARK: - Grid edits (each is one UNDO step)

    /// Tap a cell: off → 1 → 2 → … → last variation → off.
    func cycleCell(section s: Int, bank: Bank) {
        let n = state.song.count(bank)
        guard n > 0, state.song.sections.indices.contains(s) else { return }
        let cur = state.song.sections[s].part(bank)
        setCell(section: s, bank: bank, variation: cur >= n ? 0 : cur + 1)
    }

    func setCell(section s: Int, bank: Bank, variation v: Int) {
        syncFromPattern()
        guard state.song.sections.indices.contains(s) else { return }
        let v = max(0, min(v, state.song.count(bank)))
        guard state.song.sections[s].part(bank) != v else { return }
        checkpoint("\(state.song.sections[s].short) \(rowName(bank).lowercased())")
        let old = state.song
        state.song.sections[s].parts[bank] = v == 0 ? nil : v
        reflow(from: old)
        Analytics.shared.tap("song_cell", ["s": s + 1, "b": bank.letter, "v": v])
        DebugLog.event("song_cell", ["s": s + 1, "section": state.song.sections[s].name, "b": bank.letter, "v": v])
    }

    func setSectionBars(_ s: Int, bars: Int) {
        guard state.song.sections.indices.contains(s), state.song.sections[s].bars != bars else { return }
        checkpoint("\(state.song.sections[s].short) length")
        let old = state.song
        state.song.sections[s].bars = max(1, bars)
        reflow(from: old)
        Analytics.shared.tap("song_section", ["cmd": "bars", "n": bars])
    }

    func renameSection(_ s: Int, to name: String) {
        guard state.song.sections.indices.contains(s), state.song.sections[s].name != name else { return }
        checkpoint("rename \(state.song.sections[s].short)")
        state.song.sections[s].name = name
        Analytics.shared.tap("song_section", ["cmd": "rename", "name": name])
    }

    func duplicateSection(_ s: Int) {
        guard state.song.sections.indices.contains(s) else { return }
        checkpoint("duplicate \(state.song.sections[s].short)")
        let old = state.song
        var copy = state.song.sections[s]
        copy.id = UUID()
        state.song.sections.insert(copy, at: s + 1)
        reflow(from: old)
        Analytics.shared.tap("song_section", ["cmd": "dup"])
    }

    func deleteSection(_ s: Int) {
        guard state.song.sections.indices.contains(s) else { return }
        checkpoint("delete \(state.song.sections[s].short)")
        let old = state.song
        state.song.sections.remove(at: s)
        reflow(from: old)
        Analytics.shared.tap("song_section", ["cmd": "del"])
    }

    /// The grid's trailing ＋: a copy of the last section (the first one plays every bank's variation 1).
    func addSection() {
        syncFromPattern()
        checkpoint("add section")
        let old = state.song
        if var last = state.song.sections.last {
            last.id = UUID()
            state.song.sections.append(last)
        } else {
            var s = SongSection(name: "VERSE", bars: 4)
            for b in state.song.rows { s.parts[b] = 1 }
            state.song.sections.append(s)
        }
        reflow(from: old)
        Analytics.shared.tap("song_section", ["cmd": "add", "n": state.song.sections.count])
    }

    /// A section header's ▶: the song plays from that section (at the next bar line; stopped, it starts now).
    func playSection(_ s: Int) {
        guard state.song.sections.indices.contains(s) else { return }
        let bar = state.song.starts[s]
        enterSong(fromBar: bar, play: true)
        Analytics.shared.tap("song_section", ["cmd": "play", "s": s + 1])
        DebugLog.event("song_play_section", ["s": s + 1, "section": state.song.sections[s].name, "bar": bar + 1])
    }

    // MARK: - Variations (row menu)

    /// "Edit variation N": that variation becomes the bank's edit variation, loads into the live pattern and the
    /// lid goes back to PATTERN (the existing tools edit it; SONG plays it wherever it's placed).
    func editVariation(_ bank: Bank, _ n: Int, checkpoint cp: Bool = true) {
        syncFromPattern()
        guard let seq = state.song.seq(bank, n) else { return }
        if cp { checkpoint("edit \(rowName(bank).lowercased()) \(n)") }
        stopBackgroundEdits()
        var p = lastPattern
        if !state.song.songMode { p = state.engine.pattern }
        if seq.bars > p.bars { p = PatternBuilder.retile(p, to: seq.bars) }
        seq.replace(in: &p, bank: bank)
        state.song.editVar[bank] = n
        state.song.songMode = false
        lastPattern = p
        state.bars = max(1, p.bars)
        session?.bars = p.bars
        CrateUI.shared.viewBar = nil
        state.engine.setPattern(p, fromBar: 0)
        state.bank = bank
        if let i = (0..<16).first(where: { !(p.lanes[PadID(bank, $0)]?.isEmpty ?? true) || !(p.notes[PadID(bank, $0)]?.isEmpty ?? true) }) {
            state.selectedPad = PadID(bank, i)
        }
        state.addLog("SONG", "editing \(rowName(bank).lowercased()) \(n) · SONG plays it wherever it's placed", tint: .orange)
        Analytics.shared.tap("song_variation", ["cmd": "edit", "b": bank.letter, "n": n])
        DebugLog.event("song_edit_var", ["b": bank.letter, "n": n, "hits": seq.hitCount])
    }

    /// "New variation (copy of N)": a copy of the bank's edit variation, opened for editing.
    func newVariation(_ bank: Bank) {
        syncFromPattern()
        let src = state.song.edit(bank)
        guard let base = state.song.seq(bank, src) else { return }
        checkpoint("new \(rowName(bank).lowercased()) variation")
        state.song.variations[bank, default: []].append(base)
        let n = state.song.count(bank)
        Analytics.shared.tap("song_variation", ["cmd": "new", "b": bank.letter, "n": n])
        editVariation(bank, n, checkpoint: false)
    }

    /// "Clear row": the bank sits out every section (its variations stay).
    func clearRow(_ bank: Bank) {
        guard state.song.sections.contains(where: { $0.part(bank) > 0 }) else { return }
        checkpoint("clear \(rowName(bank).lowercased())")
        let old = state.song
        for i in state.song.sections.indices { state.song.sections[i].parts[bank] = nil }
        reflow(from: old)
        Analytics.shared.tap("song_variation", ["cmd": "clear", "b": bank.letter])
    }

    /// A new whole beat: the old song's variations belong to the old beat (UNDO brings them back).
    func resetSongForNewBeat() {
        guard state.song.isUsed || state.song.songMode else { state.song = SongArrangement(); return }
        state.song = SongArrangement()
        DebugLog.event("song_reset", ["why": "new beat"])
    }

    /// The row label: A DRUMS, the chop bank SAMPLE, C BASS, the other free bank LAYER.
    func rowName(_ bank: Bank) -> String {
        switch bank {
        case .a: return "DRUMS"
        case .c: return "BASS"
        case .b: return chopBank == .d && state.song.hasContent(.d) ? "LAYER" : "SAMPLE"
        case .d: return chopBank == .d ? "SAMPLE" : "LAYER"
        }
    }

    // MARK: - ✦ ARRANGE

    static func isArrangeRequest(_ prompt: String) -> Bool {
        let p = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        return ["arrange", "arrange it", "arrange this", "arrange the beat", "arrange my beat", "arrange a song",
                "make it a full song", "make a full song", "make a song", "make it a song", "full song",
                "turn it into a song", "turn this into a song", "make this a song", "make this a full song"].contains(p)
    }

    /// ✦ ARRANGE: a whole song from the beat in one tap (no network). INTRO 4 · VERSE 8 · HOOK 8 · BRIDGE 4 ·
    /// HOOK 8 · OUTRO 4 (fewer sections for a beat with few parts). Makes the variations it needs (drums 2 = busier
    /// hats + a kick pickup; sample 2 = a flip of the chops), switches to SONG and plays it from the top.
    func arrangeSong(prompt: String = "✦ ARRANGE", changeID: String? = nil, via: String = "button") {
        let t0 = Date()
        let id = changeID ?? "\(Analytics.shared.session)-arrange-\(digSerial)"
        let before = beatState()
        syncFromPattern()
        var song = state.song
        let has = { (b: Bank) in song.hasContent(b) }
        guard Bank.allCases.contains(where: has) else {
            state.addLog("ARRANGE", "dig a beat first · then ✦ ARRANGE makes it a song", tint: .grey)
            return
        }
        checkpoint("arrange")
        stopBackgroundEdits()
        if !song.songMode { lastPattern = state.engine.pattern }

        // Roles: drums = A, sample = the chop bank, bass = C, layer = the other free bank.
        let drums: Bank? = has(.a) ? .a : nil
        let sample: Bank? = [chopBank, .b, .d].first(where: has)
        let bass: Bank? = has(.c) ? .c : nil
        let layer: Bank? = [Bank.b, .d].first { $0 != sample && has($0) }

        var made: [String] = []
        if let d = drums, song.count(d) < 2, let v1 = song.seq(d, 1), !v1.isEmpty {
            let v2 = busierDrums(v1)
            if v2 != v1 { song.variations[d, default: []].append(v2); made.append("drums 2") }
        }
        if let s = sample, song.count(s) < 2, let v1 = song.seq(s, 1), !v1.isEmpty {
            let v2 = flippedSample(v1, bank: s)
            if v2 != v1, !v2.isEmpty { song.variations[s, default: []].append(v2); made.append("sample 2") }
        }
        let d2 = drums.map { song.count($0) >= 2 ? 2 : 1 } ?? 0
        let s2 = sample.map { song.count($0) >= 2 ? 2 : 1 } ?? 0

        func sec(_ name: String, _ bars: Int, _ cells: [(Bank?, Int)]) -> SongSection {
            var s = SongSection(name: name, bars: bars)
            for (b, v) in cells { if let b, v > 0, s.parts[b] == nil { s.parts[b] = v } }
            return s
        }
        let lead = sample ?? layer
        let intro = sec("INTRO", 4, [(lead ?? bass ?? drums, 1)])
        let verse = sec("VERSE", 8, [(drums, 1), (sample, 1), (bass, 1), (sample == nil ? layer : nil, 1)])
        let hook = sec("HOOK", 8, [(drums, d2), (sample, 1), (bass, 1), (layer, 1)])
        let bridge = sec("BRIDGE", 4, [(sample, s2), (bass, 1), (sample == nil ? layer : nil, 1)])
        let outro = sec("OUTRO", 4, [(lead, 1), (drums, 1)])
        var hook2 = hook
        hook2.id = UUID()
        let parts = [drums, sample, bass, layer].compactMap { $0 }.count
        var sections: [SongSection]
        switch parts {
        case ...1: sections = [intro, hook, outro]
        case 2: sections = [intro, verse, hook, outro]
        default: sections = [intro, verse, hook, bridge, hook2, outro]
        }
        sections = sections.filter { !$0.parts.isEmpty }
        song.sections = sections
        song.songMode = true
        state.song = song

        let e = state.engine
        let p = song.render(base: lastPattern)
        e.setPattern(p, fromBar: 0)
        if !e.isPlaying { e.play() }
        state.isPlaying = e.isPlaying
        CrateUI.shared.viewBar = nil

        let names = sections.map(\.short).joined(separator: " · ")
        state.addLog("ARRANGE", "\(names) · \(song.totalBars) bars" + (made.isEmpty ? "" : " · new \(made.joined(separator: ", "))"),
                     tint: .orange)
        state.setStatus(.done, "arranged a \(song.totalBars)-bar song")
        let ms = Self.ms(t0)
        Analytics.shared.tap("arrange", ["via": via, "sections": sections.count, "bars": song.totalBars, "made": made])
        recordChange(id: id, prompt: prompt, scope: "arrange", before: before, ms: ms)
        AIChangeLog.shared.update(id) { c in
            c.changed = ["added song · \(song.totalBars) bars"] + made.map { "added \($0)" }
            c.kept = song.rows.map { rowName($0).lowercased() }
        }
        DebugLog.event("arrange", ["sections": sections.map(\.name), "bars": song.totalBars, "made": made, "ms": ms,
                                   "hits": PatternBuilder.hitCount(p), "notes": PatternBuilder.noteCount(p),
                                   "roles": ["drums": drums?.letter ?? "", "sample": sample?.letter ?? "",
                                             "bass": bass?.letter ?? "", "layer": layer?.letter ?? ""]])
    }

    /// Drums 2: busier hats (`denser` on the hat lane, or 8th hats if the kit has a hat the beat doesn't use) and a
    /// kick pickup on the "and" of 3 every second bar (a perc there if there's no kick lane).
    func busierDrums(_ v1: BankSeq) -> BankSeq {
        var v = v1
        let bars = max(1, v.bars)
        let total = bars * 16
        let hats = ["hat", "hat2", "shaker"].compactMap(BankA.index(forLane:))
        if let i = hats.first(where: { !(v.lanes[$0]?.isEmpty ?? true) }), let hits = v.lanes[i] {
            v.lanes[i] = Self.denser(hits, total: total)
        } else if let i = BankA.index(forLane: "hat"), state.sound(PadID(.a, i)) != nil {
            v.lanes[i] = Swift.stride(from: 0, to: total, by: 2).map { Hit(step: $0, velocity: $0 % 4 == 0 ? 84 : 62) }
        }
        let pickupBars = bars == 1 ? [0] : Array(Swift.stride(from: 1, to: bars, by: 2))
        let kick = BankA.index(forLane: "kick")
        if let k = kick, var kicks = v.lanes[k], !kicks.isEmpty {
            let vel = Int(Double(kicks.map(\.velocity).max() ?? 100) * 0.8)
            for bar in pickupBars {
                let s = bar * 16 + 10
                if !kicks.contains(where: { abs($0.step - s) <= 1 }) { kicks.append(Hit(step: s, velocity: vel)) }
            }
            v.lanes[k] = kicks.sorted { $0.step < $1.step }
        } else if let i = ["perc", "rim", "perc2"].compactMap(BankA.index(forLane:))
                    .first(where: { state.sound(PadID(.a, $0)) != nil }) {
            var hits = v.lanes[i] ?? []
            for bar in pickupBars where !hits.contains(where: { $0.step == bar * 16 + 14 }) {
                hits.append(Hit(step: bar * 16 + 14, velocity: 70))
            }
            v.lanes[i] = hits.sorted { $0.step < $1.step }
        }
        return v
    }

    /// Sample 2: an instant rule flip of the chops (FlipBuilder, as FLIP IT's first pass); without chop info, the same
    /// part with the second half of every bar thinned (beat 3 stays).
    func flippedSample(_ v1: BankSeq, bank: Bank) -> BankSeq {
        if bank == chopBank, let c = session?.chops {
            let chops = flipChopsOnPads(bank: bank, set: c)
            let ctx = flipContext(bank: bank, set: c)
            if let plan = FlipBuilder.local(Array(chops.values), ctx: ctx, seed: Self.fnv("arrange " + c.loop.id)) {
                let roots = Dictionary(uniqueKeysWithValues: (0..<16).compactMap { i in
                    state.sound(PadID(bank, i)).map { (i, $0.rootNote ?? 60) }
                })
                let r = FlipBuilder.render(plan, bars: max(1, v1.bars), bank: bank, roots: roots)
                var v = BankSeq(bars: max(1, v1.bars))
                for (pad, hits) in r.lanes where pad.bank == bank && !hits.isEmpty { v.lanes[pad.index] = hits }
                for (pad, notes) in r.notes where pad.bank == bank && !notes.isEmpty { v.notes[pad.index] = notes }
                if !v.isEmpty {
                    DebugLog.event("arrange_flip", ["name": plan.name, "events": plan.events.count, "hits": v.hitCount])
                    return v
                }
            }
        }
        var v = v1
        func keep(_ step: Int) -> Bool { step % 16 <= 8 }
        v.lanes = v.lanes.mapValues { $0.filter { keep($0.step) } }.filter { !$0.value.isEmpty }
        v.notes = v.notes.mapValues { $0.filter { keep($0.step) } }.filter { !$0.value.isEmpty }
        v.late = v.late.filter { v.lanes[$0.key] != nil || v.notes[$0.key] != nil }
        return v
    }

    // MARK: - Debug

    /// `crate://songlog`: the sections and, per section, the rendered song's hits per bank.
    func songLog() {
        let song = state.song
        let p = song.render(base: song.songMode ? lastPattern : state.engine.pattern)
        var rows: [[String: Any]] = []
        for (i, sec) in song.sections.enumerated() {
            let a = song.starts[i] * 16, b = a + max(1, sec.bars) * 16
            var hits: [String: Int] = [:]
            for bank in Bank.allCases {
                let n = p.lanes.filter { $0.key.bank == bank }.values.reduce(0) { $0 + $1.filter { $0.step >= a && $0.step < b }.count }
                    + p.notes.filter { $0.key.bank == bank }.values.reduce(0) { $0 + $1.filter { $0.step >= a && $0.step < b }.count }
                hits[bank.letter] = n
            }
            rows.append(["i": i + 1, "name": sec.name, "bars": sec.bars,
                         "parts": Dictionary(uniqueKeysWithValues: sec.parts.map { ($0.key.letter, $0.value) }), "hits": hits])
        }
        let live = state.engine.pattern
        let edit = song.songMode ? lastPattern : live
        DebugLog.event("songlog", ["mode": song.songMode ? "song" : "pattern", "sections": rows, "songBars": p.bars,
                                   "songHits": PatternBuilder.hitCount(p), "songNotes": PatternBuilder.noteCount(p),
                                   "engineBars": live.bars, "engineHits": PatternBuilder.hitCount(live),
                                   "engineNotes": PatternBuilder.noteCount(live),
                                   "editBars": edit.bars, "editHits": PatternBuilder.hitCount(edit),
                                   "editNotes": PatternBuilder.noteCount(edit), "transpose": live.transpose,
                                   "variations": Dictionary(uniqueKeysWithValues: song.variations.map { ($0.key.letter, $0.value.map(\.hitCount)) }),
                                   "editVar": Dictionary(uniqueKeysWithValues: song.editVar.map { ($0.key.letter, $0.value) }),
                                   "playing": state.engine.isPlaying, "pos": (state.engine.position() * 10).rounded() / 10])
    }
}
