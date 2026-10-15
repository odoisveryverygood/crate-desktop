import Foundation

enum Scope: String, CaseIterable {
    case fullBeat = "full_beat", drumsOnly = "drums_only", sampleOnly = "sample_only", bassOnly = "bass_only"
    case changeGroove = "change_groove", singleSound = "single_sound", flip
    /// Surgical edits on a beat that's already playing: nothing outside the named part changes.
    /// add_layer = "add a sax line on top" / "add a shaker"; lane_edit = "more hats" / "simpler kick".
    case addLayer = "add_layer", laneEdit = "lane_edit"
}

/// Typed intent for one DIG. Built instantly by `KeywordParser`, upgraded by the Jev plan when it answers in time.
struct Plan {
    var prompt: String
    var scope: Scope = .fullBeat
    var drumStyle: Style? = nil
    var sampleStyle: Style? = nil
    var instrument = "any"
    var mood: String? = nil
    var bars: Int? = nil
    var bpm: Double? = nil
    var tempo: String? = nil
    /// 0...1 scores (nil = not stated).
    var laidback: Double? = nil
    var vintage: Double? = nil
    var energy: Double? = nil
    var brightness: Double? = nil
    var wantsBass: Double? = nil
    /// single_sound / add_layer / lane_edit: target pad category (oneshots.json category name).
    var category: String? = nil
    /// lane_edit: +1 = busier, -1 = sparser.
    var direction = 0
    var source = "kw"
    var jevMs: Int? = nil
    var jevOverrides: [String] = []
    /// An artist / producer reference the style came from ("NewJeans"); Jev doesn't override its style.
    var reference: String? = nil

    var summary: String {
        let d = drumStyle?.rawValue ?? "-", s = sampleStyle?.rawValue ?? "-"
        return "\(scope.rawValue) · \(d) × \(s) · \(instrument)" + (bars.map { " · \($0) bars" } ?? "")
    }
}

/// Offline, instant intent parse from grooves.json keywords + instrument/bars/bpm/scope heuristics.
enum KeywordParser {
    static let drumWords = ["drums", "drum", "kit", "kick", "kicks", "snare", "snares", "hats", "hat", "hihat", "hihats",
                            "hi-hat", "hi-hats", "percussion", "claps", "clap", "groove", "beat"]
    static let melodicWords = ["sample", "samples", "piano", "keys", "rhodes", "ep", "electric piano", "wurli", "wurlitzer",
                               "guitar", "strings", "synth pad", "ambient pad", "vibes", "vibraphone", "bells", "horn", "horns",
                               "brass", "trumpet", "sax", "saxophone", "flute", "vocal", "vocals", "voice", "choir",
                               "chords", "melody", "loop", "loops", "chop", "break", "breakbeat", "organ", "clav",
                               "marimba", "steelpan", "pluck", "lead", "synth", "bell", "harp"]
    static let instruments: [(String, String)] = [
        ("electric piano", "rhodes"), ("rhodes", "rhodes"), ("wurlitzer", "rhodes"), ("wurli", "rhodes"), ("ep", "rhodes"),
        ("piano", "piano"), ("keys", "keys"), ("organ", "organ"), ("clavinet", "clav"), ("clav", "clav"),
        ("guitar", "guitar"), ("strings", "strings"), ("violin", "strings"), ("cello", "strings"),
        ("synth pad", "pad"), ("ambient pad", "pad"), ("pad", "pad"), ("vibraphone", "vibes"), ("vibes", "vibes"),
        ("bells", "bell"), ("bell", "bell"), ("music box", "bell"), ("marimba", "marimba"), ("steel pan", "steelpan"),
        ("steelpan", "steelpan"), ("pluck", "pluck"), ("synth", "synth"), ("lead", "synth"),
        ("horns", "horns"), ("horn", "horns"), ("brass", "horns"), ("trumpet", "horns"), ("saxophone", "sax"),
        ("sax", "sax"), ("flute", "flute"), ("vocals", "vocal"), ("vocal", "vocal"), ("choir", "vocal"),
        ("breakbeat", "break"), ("drum break", "break"), ("break", "break"),
    ]
    static let moods: [(String, [String])] = [
        ("melancholic", ["sad", "melancholic", "melancholy", "bittersweet", "emotional", "crying"]),
        ("warm", ["warm", "cozy", "comforting"]), ("dreamy", ["dreamy", "floaty", "hazy", "ethereal"]),
        ("nostalgic", ["nostalgic", "memories", "nostalgia"]), ("uplifting", ["uplifting", "happy", "joyful", "sunny"]),
        ("dark", ["dark", "moody", "menacing", "evil", "sinister"]), ("smooth", ["smooth", "late night", "sensual"]),
        ("groovy", ["groovy", "funky", "bouncy"]),
    ]
    static let categoryWords: [(String, String)] = [
        ("open hat", "openhat"), ("openhat", "openhat"), ("hihat", "hat"), ("hi-hat", "hat"), ("hat", "hat"),
        ("kick", "kick"), ("snare", "snare"), ("clap", "clap"), ("snap", "clap"), ("rim", "rim"), ("shaker", "shaker"),
        ("crash", "cymbal"), ("ride", "cymbal"), ("cymbal", "cymbal"), ("808", "808"), ("bass", "bass"),
        ("riser", "fx"), ("impact", "fx"), ("fx", "fx"), ("vocal", "vocal"), ("voice", "vocal"), ("vinyl", "texture"),
        ("crackle", "texture"), ("rain", "texture"), ("texture", "texture"), ("piano", "keys"), ("rhodes", "keys"),
        ("keys", "keys"), ("chord", "keys"), ("pluck", "synth"), ("bell", "synth"), ("synth", "synth"),
        ("conga", "perc"), ("bongo", "perc"), ("tambourine", "perc"), ("bottle", "perc"), ("perc", "perc"),
    ]

    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()

    private static func regex(_ word: String) -> NSRegularExpression? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let r = regexCache[word] { return r }
        let r = try? NSRegularExpression(pattern: "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: word) + "(?![a-z0-9])")
        regexCache[word] = r
        return r
    }

    /// Character offsets of whole-word matches.
    static func find(_ word: String, in text: String) -> [Int] {
        guard let r = regex(word) else { return [] }
        let ns = text as NSString
        return r.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range.location)
    }

    static func has(_ word: String, _ text: String) -> Bool { !find(word, in: text).isEmpty }
    static func hasAny(_ words: [String], _ text: String) -> Bool { words.contains { has($0, text) } }

    static func normalize(_ s: String) -> String {
        var t = s.lowercased().replacingOccurrences(of: "’", with: "'")
        t = t.replacingOccurrences(of: "bar loop", with: "bar beat").replacingOccurrences(of: "bars loop", with: "bars beat")
        return t
    }

    static func parse(_ prompt: String, grooves: GroovesFile) -> Plan {
        var plan = Plan(prompt: prompt)
        let text = normalize(prompt)
        let ns = text as NSString

        // Clause boundaries so "dilla drums, nujabes piano" assigns each style to its own noun.
        var bounds: [Int] = [0, ns.length]
        if let r = try? NSRegularExpression(pattern: ",|;|\\.|\\+| and | with | plus | over | under ") {
            bounds += r.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range.location)
        }
        bounds.sort()
        func clause(_ pos: Int) -> (Int, Int) {
            let lo = bounds.last { $0 <= pos } ?? 0
            let hi = bounds.first { $0 > pos } ?? ns.length
            return (lo, hi)
        }
        // "vintage break with a rhodes": a break next to another instrument means break DRUMS.
        let breakWords = ["break", "breakbeat", "breaks"]
        let otherInstrument = instruments.contains { $0.1 != "break" && has($0.0, text) }
        let breakIsDrum = otherInstrument && hasAny(breakWords, text)
        var nouns: [(pos: Int, drum: Bool)] = []
        for w in drumWords where w != "beat" { nouns += find(w, in: text).map { ($0, true) } }
        for w in melodicWords where !(breakIsDrum && breakWords.contains(w)) { nouns += find(w, in: text).map { ($0, false) } }
        if breakIsDrum { for w in breakWords { nouns += find(w, in: text).map { ($0, true) } } }
        nouns.sort { $0.pos < $1.pos }

        // "new jeans type beat": an artist reference sets the style unless a genre word is named too; its own words
        // ("pop smoke", "metro") don't vote as genre keywords.
        let ref = ArtistReferences.match(text)
        var voteText = text
        if let r = ref?.range { voteText = ns.replacingCharacters(in: r, with: String(repeating: " ", count: r.length)) }
        var drumVotes: [Style: Double] = [:], sampleVotes: [Style: Double] = [:], anyVotes: [Style: Double] = [:]
        var firstSeen: [Style: Int] = [:]
        for (key, info) in grooves.styles {
            guard let style = Style(rawValue: key) else { continue }
            for kw in info.keywords {
                for pos in find(kw.lowercased(), in: voteText) {
                    let w = Double(kw.count)
                    firstSeen[style] = min(firstSeen[style] ?? Int.max, pos)
                    let (lo, hi) = clause(pos)
                    let after = nouns.first { $0.pos > pos && $0.pos < hi }
                    let before = nouns.last { $0.pos < pos && $0.pos >= lo }
                    if let n = after ?? before {
                        if n.drum { drumVotes[style, default: 0] += w } else { sampleVotes[style, default: 0] += w }
                    } else {
                        anyVotes[style, default: 0] += w
                    }
                }
            }
        }
        func top(_ v: [Style: Double]) -> Style? {
            v.max { a, b in a.value == b.value ? (firstSeen[a.key] ?? 0) > (firstSeen[b.key] ?? 0) : a.value < b.value }?.key
        }
        plan.drumStyle = top(drumVotes) ?? top(anyVotes) ?? top(sampleVotes)
        plan.sampleStyle = top(sampleVotes) ?? top(anyVotes) ?? plan.drumStyle
        if let r = ref?.ref {
            plan.reference = r.name
            if plan.drumStyle == nil { plan.drumStyle = r.drum; plan.sampleStyle = r.sample ?? r.drum }
        }

        // Instrument: earliest mention wins.
        var bestInst: (Int, String)?
        for (word, inst) in instruments where !(breakIsDrum && inst == "break") {
            if let pos = find(word, in: text).first, bestInst == nil || pos < bestInst!.0 { bestInst = (pos, inst) }
        }
        if let b = bestInst { plan.instrument = b.1 }

        // Bars / BPM.
        let words: [String: Int] = ["one": 1, "two": 2, "four": 4, "eight": 8, "sixteen": 16]
        if let m = firstMatch("(\\d{1,2}|one|two|four|eight|sixteen)\\s*-?\\s*bars?", text) {
            let n = Int(m) ?? words[m] ?? 4
            plan.bars = min(8, max(1, n))
        }
        if let m = firstMatch("(\\d{2,3})\\s*bpm", text), let v = Double(m), (50...200).contains(v) { plan.bpm = v }
        // A bare tempo ("deep house, 124"): a lone 2–3 digit number in 60–200 that isn't a bar count.
        if plan.bpm == nil, let m = firstMatch("(?<![a-z0-9.\\-])(\\d{2,3})(?![a-z0-9]|\\s*-?\\s*bars?)", text),
           let v = Double(m), (60...200).contains(v) { plan.bpm = v }

        // Feel scores.
        if hasAny(["laid back", "laid-back", "laidback", "drunk", "lazy", "behind the beat", "wonky", "loose", "unquantized", "sloppy"], text) {
            plan.laidback = 0.9
        } else if hasAny(["tight", "quantized", "rigid", "straight", "on grid"], text) { plan.laidback = 0.1 }
        if hasAny(["vintage", "dusty", "old", "vinyl", "crusty", "sp-1200", "sp1200", "lo-fi", "lofi", "crackly", "old school"], text) {
            plan.vintage = 0.9
        } else if hasAny(["clean", "modern", "crisp", "polished"], text) { plan.vintage = 0.1 }
        if hasAny(["hard", "hard-hitting", "hard hitting", "energetic", "banging", "aggressive", "hype", "punchy", "knock"], text) {
            plan.energy = 0.85
        } else if hasAny(["chill", "calm", "soft", "mellow", "relaxed", "sleepy", "gentle"], text) { plan.energy = 0.25 }
        if hasAny(["bright", "crisp", "airy", "shiny"], text) { plan.brightness = 0.8 }
        else if hasAny(["dark", "muffled", "warm", "moody", "murky"], text) { plan.brightness = 0.25 }
        for (mood, ws) in moods where plan.mood == nil && hasAny(ws, text) { plan.mood = mood }
        if hasAny(["slow"], text) { plan.tempo = "slow" } else if hasAny(["fast", "uptempo", "up-tempo"], text) { plan.tempo = "upbeat" }
        if let r = ref?.ref {
            // The reference's tempo only when its style is the one playing; its feel fills what the words didn't say.
            if plan.bpm == nil, plan.tempo == nil, plan.drumStyle == r.drum, let b = r.bpm { plan.bpm = b }
            plan.brightness = plan.brightness ?? r.brightness
            plan.energy = plan.energy ?? r.energy
            plan.laidback = plan.laidback ?? r.laidback
            plan.vintage = plan.vintage ?? r.vintage
            plan.mood = plan.mood ?? r.mood
        }

        // Scope.
        let hasDrum = hasAny(drumWords.filter { $0 != "beat" && $0 != "groove" }, text) || breakIsDrum
        let hasMel = plan.instrument != "any" || hasAny(melodicWords.filter { !(breakIsDrum && breakWords.contains($0)) }, text)
        let hasBass = hasAny(["bass", "bassline", "bass line", "808 line", "sub bass"], text)
        let wholeBeat = hasAny(["beat", "track", "song", "instrumental"], text)
        let change = hasAny(["more", "less", "busier", "simpler", "tighter", "looser", "make it", "swing it", "add fills",
                             "add a fill", "change the groove", "change the drums", "half time", "halftime", "switch it up",
                             "vary", "variation", "remix"], text)
        let load = hasAny(["sample", "loop", "kit", "new", "some", "find", "dig", "give me", "load", "get me", "generate"], text)
        let drumCats = drumCategories(text)
        let wholeKit = hasAny(["drums", "drum", "kit", "beat", "groove", "track", "song"], text)
        if has("flip", text) || has("flip it", text) {
            plan.scope = .flip
        } else if isAdd(text), !has("fill", text), !has("fills", text), hasMel || drumCats.count == 1 {
            // "add a sax line on top", "put some strings over it", "add a shaker": a new part, the rest stays.
            plan.scope = .addLayer
            if !hasMel { plan.category = drumCats.first }
        } else if drumCats.count == 1, !hasMel, !wholeKit, let dir = densityDirection(text) {
            // "more hats", "busier hats", "simpler kick", "double time hats": only that lane changes.
            plan.scope = .laneEdit
            plan.category = drumCats.first
            plan.direction = dir
        } else if drumCats.count == 1, !hasMel, !wholeKit, !hasBass {
            // "punchier snare", "different hats", "a dustier kick": that one sound, not a new kit.
            plan.scope = .singleSound
            plan.category = drumCats.first
        } else if firstMatch("pad\\s*(\\d{1,2})", text) != nil || hasAny(["this pad", "selected pad", "one sound", "single sound"], text) {
            plan.scope = .singleSound
            for (w, cat) in categoryWords where plan.category == nil && has(w, text) { plan.category = cat }
        } else if change && !load && !hasMel {
            plan.scope = .changeGroove
        } else if hasBass && !hasDrum && !hasMel && !wholeBeat {
            plan.scope = .bassOnly
        } else if hasDrum && !hasMel {
            plan.scope = .drumsOnly
        } else if hasMel && !hasDrum && !wholeBeat {
            plan.scope = .sampleOnly
        } else {
            plan.scope = .fullBeat
        }
        if hasAny(["no bass", "without bass", "no bassline"], text) { plan.wantsBass = 0 } else if hasBass { plan.wantsBass = 1 }
        return plan
    }

    static let addWords = ["add", "adds", "adding", "put", "layer", "throw in", "bring in", "drop in", "on top", "over it",
                           "over the top", "sprinkle", "include", "introduce"]

    static func isAdd(_ text: String) -> Bool { hasAny(addWords, text) }

    /// Drum lanes a prompt names ("hats", "open hat", "shaker"…) as bank-A slot names, open hat before hat.
    static func drumCategories(_ text: String) -> [String] {
        var t = text.replacingOccurrences(of: "open hats", with: "openhat").replacingOccurrences(of: "open hat", with: "openhat")
        t = t.replacingOccurrences(of: "hi hats", with: "hats").replacingOccurrences(of: "hi-hats", with: "hats")
            .replacingOccurrences(of: "hi hat", with: "hat").replacingOccurrences(of: "hi-hat", with: "hat")
        let table: [([String], String)] = [
            (["kick", "kicks", "kick drum"], "kick"), (["snare", "snares"], "snare"), (["clap", "claps", "snap", "snaps"], "clap"),
            (["openhat"], "openhat"), (["hat", "hats", "hihat", "hihats"], "hat"), (["rim", "rims", "rimshot"], "rim"),
            (["shaker", "shakers"], "shaker"), (["tambourine", "tamb", "conga", "congas", "bongo", "bongos", "perc",
                                                 "percussion", "cowbell", "bottle"], "perc"),
            (["crash", "cymbal", "cymbals", "ride"], "cymbal"), (["vinyl", "crackle", "texture", "rain"], "texture"),
            (["riser", "impact", "sweep"], "fx"),
        ]
        return table.filter { hasAny($0.0, t) }.map(\.1)
    }

    /// +1 for "more / busier / double", -1 for "less / simpler / fewer / half", nil when the prompt isn't about density.
    static func densityDirection(_ text: String) -> Int? {
        if hasAny(["more", "busier", "busy", "double time", "double-time", "faster", "rolling", "roll", "16ths", "sixteenths"], text) { return 1 }
        if hasAny(["less", "fewer", "simpler", "simple", "sparser", "sparse", "half", "minimal", "calmer", "chill out"], text) { return -1 }
        return nil
    }

    /// First capture group of a regex, or nil.
    static func firstMatch(_ pattern: String, _ text: String) -> String? {
        guard let r = try? NSRegularExpression(pattern: pattern),
              let m = r.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return (text as NSString).substring(with: m.range(at: 1))
    }
}
