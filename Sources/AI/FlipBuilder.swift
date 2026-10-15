import Foundation

/// A chop as FLIP IT sees it.
struct FlipChop: Hashable {
    var pad: Int
    /// Natural length in 16ths at the playing tempo.
    var steps: Double
    var energy: Double
    var attack: Double
    var tonal: Double
    /// Pitch-class shares (sums to 1).
    var chroma: [Double]
    var pc: Int
    /// Bar of the chopped span it came from, and its start step there (source order).
    var srcBar: Int
    var srcStep: Int
    var rank: Int
    var hero: Bool

    init(pad: Int, steps: Double, feature c: ChopFeature) {
        self.pad = pad; self.steps = steps
        energy = c.energy; attack = c.attack; tonal = c.tonal; chroma = c.chroma; pc = c.pc
        srcBar = c.bar; srcStep = c.step; rank = c.rank; hero = c.hero
    }

    var feature: ChopFeature {
        var f = ChopFeature(start: 0, end: 0, step: srcStep, steps: max(1, Int(steps.rounded())))
        f.energy = energy; f.attack = attack; f.tonal = tonal; f.chroma = chroma; f.pc = pc
        return f
    }

    func fit(_ pcs: Set<Int>, shift: Int = 0) -> Double { feature.fit(pcs, shift: shift) }
}

/// One chop hit of a flip. `step` is absolute within the flip's cycle.
struct FlipEvent: Hashable {
    var step: Int
    var pad: Int
    var velocity: Int
    /// Steps to play before it's choked (nil = until its own end or the next chop).
    var hold: Double? = nil
    /// Semitones (played as a pitched note on the pad).
    var pitch: Int = 0
    var offset: Double = 0
    var role: Character = "H"
}

/// The flip: `events` over `cycleBars` bars, repeated to fill the pattern.
struct FlipPlan {
    var events: [FlipEvent]
    var cycleBars: Int
    var phraseBars: Int
    var name: String
}

/// What's under the chops while they flip (drums and bass never change).
struct FlipContext {
    var bars: Int
    /// Bars of the chopped span (the source's chord cycle).
    var span: Int
    /// A bass plays the source's chords bar by bar: chops must come from bars with the same chord.
    var chordFollow: Bool
    /// One chord per source bar (nil = unknown).
    var chords: [ChordInfo?]
    var key: (pc: Int, minor: Bool)?
    var laidback: Double
    var bpm: Double

    var scale: Set<Int>? { key.map { Set(Music.scale(pc: $0.pc, minor: $0.minor)) } }
}

/// FLIP IT, the producer's way, deterministic per seed (each tap = another seed = another flip):
///   • a 1–2 bar rhythm phrase repeated over the loop: hero chop on beat 1, a syncopated answer (mostly the "and"
///     of 2), a sustained harmonic chop, a pickup into the next bar, and RESTS ('.': the chop is choked, silence);
///   • reordering is the point: roles are filled from the chops by what they sound like (hero rank, attack,
///     contrast with the hero, harmonic stability), the pickup is the chop that leads into the next hero in the
///     original when there is one;
///   • when a bass plays the sample's chords, each bar only uses chops from source bars with the same chord, so the
///     flip never fights the bass (the drums and bass are never touched);
///   • at most one chop per phrase is pitched ±2–5 semitones, only if it stays in key; offbeat hits lean back a
///     little on laid-back styles.
enum FlipBuilder {
    /// Rhythm phrases (16 steps per bar). H hero · X second hero · h hero stutter · A answer · S sustained chop ·
    /// U pickup · '-' keeps ringing · '.' rest (the chop before it is choked).
    static let templates: [(name: String, bars: [String])] = [
        ("ANSWER", ["H-----A-..S---U-", "X-----A-A-..S-U-"]),
        ("STUTTER", ["H--.h-..A---..U-", "H-----..S-A-..U-"]),
        ("HELD", ["H-------..A-..A-", "S-------A-..U-U-"]),
        ("PUSH", ["H---..A---..S-U-", "X---..A-..S---.."]),
        ("BOUNCE", ["H-.A--..H-.A--U-", "S-------..A-U---"]),
        ("RUN", ["H-----..A-..S-..", "X-----..A-U-U-U-"]),
        ("CALL", ["H---A---..S---U-", "H---A---S-..A-U-"]),
        ("HALF", ["H-------A---..U-", "S-------..A-U-U-"]),
    ]

    static func velocity(_ role: Character) -> Int {
        switch role {
        case "H": return 116
        case "X": return 110
        case "h": return 90
        case "A": return 102
        case "S": return 96
        default: return 90
        }
    }

    // MARK: - Local flip

    static func local(_ chops: [FlipChop], ctx: FlipContext, seed: UInt64) -> FlipPlan? {
        let usable = chops.filter { $0.energy >= 0.12 }
        guard usable.count >= 2 else { return nil }
        var rng = SeededRNG(seed: seed ^ 0xF11F_F11F)
        var t = templates[Int(rng.next() % UInt64(templates.count))]
        if rng.unit() < 0.35 { t.bars.reverse() }           // the phrase's answer bar first
        let phrase = ctx.bars >= 2 ? 2 : 1
        let cycle = cycleBars(ctx, phrase: phrase)
        let laid = max(0, min(1, ctx.laidback))
        // Per-bar pools and roles.
        var events: [FlipEvent] = []
        var rolesByPool: [[Int]: [Character: FlipChop]] = [:]
        let pools = (0..<cycle).map { pool(usable, bar: $0, ctx: ctx) }
        let picks = Picks(&rng)
        for b in 0..<cycle {
            let poolKey = pools[b].map(\.pad).sorted()
            let next = pools[(b + 1) % cycle]
            let roles = rolesByPool[poolKey] ?? assign(pools[b], next: next, picks: picks)
            rolesByPool[poolKey] = roles
            let bar = Array(t.bars[b % phrase])
            var answers = 0
            for (i, ch) in bar.enumerated() where ch != "-" && ch != "." {
                var role = ch
                if ch == "A" { answers += 1; if answers > 1, roles["a"] != nil, rng.unit() < 0.5 { role = "a" } }
                guard let c = roles[role] ?? roles["H"] else { continue }
                var run = 1
                while i + run < bar.count && bar[i + run] == "-" { run += 1 }
                let restAfter = i + run < bar.count ? bar[i + run] == "." : false
                var hold: Double? = restAfter ? Double(run) : nil
                if ch == "h" { hold = min(Double(run), 2) }
                if let h = hold, c.steps <= h + 0.25 { hold = nil }        // ends on its own before the rest
                let step = b * 16 + i
                events.append(FlipEvent(step: step, pad: c.pad, velocity: velocity(ch == "a" ? "A" : ch), hold: hold,
                                        offset: i % 4 == 0 ? 0 : (laid * 0.14 * 100).rounded() / 100, role: ch))
            }
        }
        // One pitched chop per phrase: the first answer / pickup of the phrase's last bar, if a shift keeps it in key.
        if let scale = ctx.scale, rng.unit() < 0.65 {
            let targets = events.indices.filter { (events[$0].step / 16) % phrase == phrase - 1 && "AU".contains(events[$0].role) }
            if let first = targets.first {
                // The same slot in every phrase; each chop gets its own in-key shift (chord-follow bars differ).
                let slot = events[first].step % (16 * phrase), role = events[first].role
                var shifts: [Int: Int?] = [:]
                let pickA = rng.unit()
                for i in events.indices where events[i].step % (16 * phrase) == slot && events[i].role == role {
                    let pad = events[i].pad
                    if shifts[pad] == nil, let c = usable.first(where: { $0.pad == pad }) {
                        var r = SeededRNG(seed: UInt64(pickA * 1e9) ^ UInt64(pad))
                        shifts[pad] = shift(c, scale: scale, rng: &r)
                    }
                    if let s = shifts[pad] ?? nil {
                        events[i].pitch = s
                        if let h = events[i].hold, let c = usable.first(where: { $0.pad == pad }), c.steps / pow(2, Double(s) / 12) <= h + 0.25 {
                            events[i].hold = nil
                        }
                    }
                }
            }
        }
        return FlipPlan(events: events.sorted { $0.step < $1.step }, cycleBars: cycle, phraseBars: phrase, name: t.name)
    }

    /// Bars before the flip repeats exactly: the phrase, or the source's chord cycle when chops follow the bass.
    static func cycleBars(_ ctx: FlipContext, phrase: Int) -> Int {
        guard ctx.chordFollow else { return min(ctx.bars, phrase) }
        var c = max(1, ctx.span)
        // The shortest repeat of the chord sequence (A B A B → 2).
        for p in 1...c where c % p == 0 {
            if (0..<c).allSatisfy({ same(ctx.chords[safe: $0], ctx.chords[safe: $0 % p]) }) && ctx.chords.contains(where: { $0 != nil }) { c = p; break }
        }
        var cycle = max(phrase, c)
        if cycle % phrase != 0 { cycle *= phrase }
        return min(max(1, ctx.bars), cycle)
    }

    static func same(_ a: ChordInfo??, _ b: ChordInfo??) -> Bool {
        let x = a ?? nil, y = b ?? nil
        return x?.pc == y?.pc && x?.minor == y?.minor
    }

    /// Chops allowed in pattern bar `b`: with a bass on the source's chords, chops from source bars holding the same
    /// chord (else from the same source bar); otherwise all of them.
    static func pool(_ chops: [FlipChop], bar b: Int, ctx: FlipContext) -> [FlipChop] {
        guard ctx.chordFollow, ctx.span > 0 else { return chops.sorted { $0.rank < $1.rank } }
        let src = b % ctx.span
        let chord = ctx.chords[safe: src] ?? nil
        var bars: Set<Int> = [src]
        if let c = chord {
            for (i, x) in ctx.chords.enumerated() where x?.pc == c.pc && x?.minor == c.minor { bars.insert(i) }
        }
        var p = chops.filter { bars.contains($0.srcBar % max(1, ctx.span)) }
        if p.count < 3, let c = chord {
            // Thin bar: add chops whose notes sit in that chord.
            let triad: Set<Int> = [c.pc, (c.pc + (c.minor ? 3 : 4)) % 12, (c.pc + 7) % 12]
            p += chops.filter { x in !p.contains(x) && x.fit(triad) >= 0.55 }
        }
        if p.count < 2 { p = chops }
        return p.sorted { $0.rank < $1.rank }
    }

    /// Seeded choices shared by every bar of one flip (so the bars agree on "second-best answer" etc.).
    struct Picks {
        var hero: Double, answer: Double, sustain: Double, pickup: Double
        init(_ rng: inout SeededRNG) { hero = rng.unit(); answer = rng.unit(); sustain = rng.unit(); pickup = rng.unit() }
    }

    /// Roles for one pool. `next` = the following bar's pool (its hero's lead-in is the pickup).
    static func assign(_ pool: [FlipChop], next: [FlipChop], picks: Picks) -> [Character: FlipChop] {
        var r: [Character: FlipChop] = [:]
        let heroes = pool.filter(\.hero).sorted { $0.rank < $1.rank }
        let ranked = heroes.isEmpty ? pool : heroes + pool.filter { !$0.hero }
        let h = heroes.count > 1 && picks.hero > 0.6 ? heroes[1] : ranked[0]
        r["H"] = h; r["h"] = h
        let others = pool.filter { $0.pad != h.pad }
        r["X"] = others.first(where: \.hero) ?? others.first ?? h
        func sim(_ a: FlipChop, _ b: FlipChop) -> Double { ChopFeature.similarity(a.feature, b.feature) }
        let answers = others.sorted { a, b in
            func s(_ c: FlipChop) -> Double { 0.6 * c.attack + 0.4 * (1 - sim(c, h)) + (c.steps <= 4.5 ? 0.2 : 0) + 0.1 * c.energy }
            return s(a) > s(b)
        }
        let ai = min(answers.count - 1, picks.answer < 0.5 ? 0 : picks.answer < 0.8 ? 1 : 2)
        let a = ai >= 0 ? answers[ai] : h
        r["A"] = a
        r["a"] = answers.first { $0.pad != a.pad } ?? a
        let sustains = pool.filter { $0.pad != h.pad && $0.pad != a.pad }.sorted { x, y in
            func s(_ c: FlipChop) -> Double { 0.6 * c.tonal + 0.4 * min(c.steps, 8) / 8 + 0.2 * c.energy }
            return s(x) > s(y)
        }
        r["S"] = (sustains.count > 1 && picks.sustain > 0.65 ? sustains[1] : sustains.first) ?? r["X"]
        // Pickup: the chop that led into the next bar's hero in the original, else a short punchy one.
        let nextHero = next.filter(\.hero).min { $0.rank < $1.rank } ?? next.first
        let leadIn = nextHero.flatMap { nh in pool.filter { $0.srcStep < nh.srcStep && $0.pad != nh.pad }.max { $0.srcStep < $1.srcStep } }
        let used = Set([h.pad, a.pad, r["S"]?.pad ?? -1])
        let punchy = pool.filter { !used.contains($0.pad) }.max { x, y in
            (x.attack - x.steps / 16) < (y.attack - y.steps / 16)
        }
        let natural = leadIn.flatMap { used.contains($0.pad) ? nil : $0 }
        r["U"] = (picks.pickup < 0.7 ? natural ?? punchy : punchy ?? natural) ?? leadIn ?? a
        return r
    }

    /// A shift of ±2…5 semitones that keeps the chop in key (≥ 80 % of its pitched energy in the scale), or nil.
    static func shift(_ c: FlipChop, scale: Set<Int>, rng: inout SeededRNG) -> Int? {
        let base = c.fit(scale)
        let options = [5, -5, 3, -3, 2, -2, 4, -4].filter { c.fit(scale, shift: $0) >= max(0.8, base - 0.05) }
        guard !options.isEmpty else { return nil }
        let best = options.sorted { c.fit(scale, shift: $0) > c.fit(scale, shift: $1) }
        return best[Int(rng.next() % UInt64(min(2, best.count)))]
    }

    // MARK: - Checks

    struct Stats {
        var rest: Double
        var distinct: Int
        var beatOne: Bool
        var pitched: Int
        var clash: Double
    }

    /// Rests = share of the cycle where no chop sounds; beatOne = a chop starts on beat 1 of every phrase;
    /// clash = share of hits (chord-follow) whose source chord isn't the chord under them.
    static func stats(_ plan: FlipPlan, chops: [Int: FlipChop], ctx: FlipContext) -> Stats {
        let total = max(1, plan.cycleBars * 16)
        let ev = plan.events.sorted { $0.step < $1.step }
        var sounding = 0.0
        for (i, e) in ev.enumerated() {
            let next = i + 1 < ev.count ? ev[i + 1].step : (ev.first.map { $0.step + total } ?? total)
            let natural = (chops[e.pad]?.steps ?? 1) / pow(2, Double(e.pitch) / 12)
            sounding += min(natural, e.hold ?? .infinity, Double(next - e.step))
        }
        let phraseSteps = plan.phraseBars * 16
        let beatOne = stride(from: 0, to: total, by: phraseSteps).allSatisfy { s in ev.contains { $0.step == s } }
        var clashes = 0
        if ctx.chordFollow, ctx.span > 0 {
            for e in ev {
                guard let c = chops[e.pad] else { continue }
                let under = ctx.chords[safe: (e.step / 16) % ctx.span] ?? nil
                let from = ctx.chords[safe: c.srcBar % ctx.span] ?? nil
                if let u = under, let f = from, u.pc != f.pc || u.minor != f.minor { clashes += 1 }
                else if under == nil, from == nil, (e.step / 16) % ctx.span != c.srcBar % ctx.span { clashes += 1 }
            }
        }
        return Stats(rest: max(0, 1 - sounding / Double(total)), distinct: Set(ev.map(\.pad)).count, beatOne: beatOne,
                     pitched: ev.filter { $0.pitch != 0 }.count, clash: ev.isEmpty ? 0 : Double(clashes) / Double(ev.count))
    }

    // MARK: - GPT output: validate + repair

    struct GPTChop { var bar: Int; var step: Int; var slice: Int; var len: Double; var pitch: Int }

    /// GPT's flip → a plan, repaired where it's cheap (off-key / huge pitches → 0, a chop from the wrong chord →
    /// the closest chop of the right one, no hit on beat 1 → the local hero there, wall-to-wall sound → chops choked
    /// before the next hit), rejected when it isn't a flip: < 3 distinct chops, still no rest, or mostly repaired.
    static func fromGPT(_ items: [GPTChop], chops: [Int: FlipChop], ctx: FlipContext, local: FlipPlan?, barsWritten: Int)
        -> (plan: FlipPlan?, repairs: [String], reject: String?) {
        var repairs: [String] = []
        let cycle = max(1, min(barsWritten, ctx.bars))
        let usable = Array(chops.values)
        var events: [FlipEvent] = []
        var seen = Set<Int>()
        var remapped = 0
        let laid = max(0, min(1, ctx.laidback))
        for it in items.sorted(by: { ($0.bar, $0.step) < ($1.bar, $1.step) }) {
            guard it.bar >= 0, it.bar < cycle, (0..<16).contains(it.step) else { continue }
            let step = it.bar * 16 + it.step
            guard !seen.contains(step), var c = chops[it.slice] else { continue }
            seen.insert(step)
            if ctx.chordFollow {
                let allowed = pool(usable, bar: it.bar, ctx: ctx)
                if !allowed.contains(where: { $0.pad == c.pad }), let alt = closest(c, in: allowed) {
                    c = alt; remapped += 1
                }
            }
            var pitch = it.pitch
            if pitch != 0 {
                if abs(pitch) > 7 { pitch = 0; repairs.append("pitch>7") }
                else if let scale = ctx.scale, c.fit(scale, shift: pitch) < 0.75 { pitch = 0; repairs.append("offkey") }
            }
            var hold: Double? = it.len > 0 ? it.len : nil
            if let h = hold, c.steps / pow(2, Double(pitch) / 12) <= h + 0.25 { hold = nil }
            let role: Character = it.step == 0 ? "H" : "A"
            events.append(FlipEvent(step: step, pad: c.pad, velocity: it.step % 4 == 0 ? (it.step == 0 ? 114 : 104) : 94,
                                    hold: hold, pitch: pitch, offset: it.step % 4 == 0 ? 0 : (laid * 0.14 * 100).rounded() / 100,
                                    role: role))
        }
        if remapped > 0 { repairs.append("chord×\(remapped)") }
        guard !events.isEmpty else { return (nil, repairs, "empty") }
        if Double(remapped) > 0.4 * Double(events.count) { return (nil, repairs, "wrong chords") }
        let phrase = cycle >= 2 ? 2 : 1
        // Beat 1 of every phrase needs a chop.
        for s in stride(from: 0, to: cycle * 16, by: phrase * 16) where !events.contains(where: { $0.step == s }) {
            let pool = self.pool(usable, bar: s / 16, ctx: ctx)
            if let hero = local?.events.first(where: { $0.step == s }).flatMap({ e in chops[e.pad] }) ?? pool.first {
                events.append(FlipEvent(step: s, pad: hero.pad, velocity: 114, role: "H"))
                repairs.append("beat1")
            }
        }
        events.sort { $0.step < $1.step }
        var plan = FlipPlan(events: events, cycleBars: cycle, phraseBars: phrase, name: "GPT")
        var st = stats(plan, chops: chops, ctx: ctx)
        if st.distinct < 3 { return (nil, repairs, "\(st.distinct) chops") }
        if st.rest < 0.12 {
            // Choke the longest-ringing chops a 16th before the next hit until there's air.
            let order = plan.events.indices.sorted { plan.events[$0].step < plan.events[$1].step }
            for (k, i) in order.enumerated() where st.rest < 0.18 {
                let next = k + 1 < order.count ? plan.events[order[k + 1]].step : cycle * 16 + plan.events[order[0]].step
                let gap = Double(next - plan.events[i].step)
                guard gap >= 3, (chops[plan.events[i].pad]?.steps ?? 0) > gap - 1 else { continue }
                plan.events[i].hold = gap - 1
                st = stats(plan, chops: chops, ctx: ctx)
            }
            repairs.append("rests")
            if st.rest < 0.1 { return (nil, repairs, "no rest") }
        }
        return (plan, repairs, nil)
    }

    /// The chop in `pool` that plays the same part: similar attack, loudness, length and sound.
    static func closest(_ c: FlipChop, in pool: [FlipChop]) -> FlipChop? {
        pool.min { a, b in
            func d(_ x: FlipChop) -> Double {
                abs(x.attack - c.attack) + abs(x.energy - c.energy) + abs(x.steps - c.steps) / 8
                    + (1 - ChopFeature.similarity(x.feature, c.feature)) * 0.5
            }
            return d(a) < d(b)
        }
    }

    // MARK: - Pattern

    /// The plan as pattern lanes on `bank`, repeated over `bars`: plain hits as lanes, choked or pitched hits as
    /// notes (midi = the pad's root + pitch, length = hold).
    static func render(_ plan: FlipPlan, bars: Int, bank: Bank, roots: [Int: Int]) -> (lanes: [PadID: [Hit]], notes: [PadID: [NoteEvent]]) {
        var lanes: [PadID: [Hit]] = [:], notes: [PadID: [NoteEvent]] = [:]
        let cycle = max(1, plan.cycleBars) * 16, total = max(1, bars) * 16
        var rep = 0
        while rep * cycle < total {
            for e in plan.events {
                let step = rep * cycle + e.step
                guard step < total else { continue }
                let pad = PadID(bank, e.pad)
                if e.pitch != 0 || e.hold != nil {
                    let root = roots[e.pad] ?? 60
                    notes[pad, default: []].append(NoteEvent(step: step, length: e.hold ?? 16, midi: root + e.pitch, velocity: e.velocity))
                } else {
                    lanes[pad, default: []].append(Hit(step: step, velocity: e.velocity, offset: e.offset))
                }
            }
            rep += 1
        }
        return (lanes.mapValues { $0.sorted { $0.step < $1.step } }, notes.mapValues { $0.sorted { $0.step < $1.step } })
    }

    /// Compact text of a cycle ("0:H3 6:A12 …") for logs.
    static func describe(_ plan: FlipPlan) -> String {
        plan.events.map { e in
            "\(e.step):\(e.role)\(e.pad + 1)" + (e.pitch != 0 ? (e.pitch > 0 ? "+\(e.pitch)" : "\(e.pitch)") : "")
                + (e.hold.map { String(format: "/%.0f", $0) } ?? "")
        }.joined(separator: " ")
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}
