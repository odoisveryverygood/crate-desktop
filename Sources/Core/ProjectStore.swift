import Foundation
import Observation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A saved CRATE session: pads (by file path), pattern, tempo, labels. JSON in Documents/projects/<id>.json.
struct Project: Codable, Identifiable, Hashable {
    struct Sound: Codable, Hashable {
        var id: String
        var name: String
        var category: String
        /// "~lib/<rel>" for the bundled sample library, "~docs/<rel>" for files in the app's Documents
        /// (both container paths change with every install or update), otherwise an absolute path.
        var filePath: String
        var start: Double
        var end: Double?
        var rootNote: Int?
        var gain: Float
        /// The pad editor's controls; absent (older projects, or nothing changed) = defaults.
        var params: PadParams?
    }

    struct PatternData: Codable, Hashable {
        var bars: Int
        var swing: Double
        var lanes: [String: [Hit]]
        var late: [String: Double]
        var notes: [String: [NoteEvent]]
        /// Song KEY shift in semitones (absent = 0; older projects don't have it).
        var transpose: Int? = nil
    }

    var id: String
    var name: String
    var created: Date
    var updated: Date
    var bpm: Double
    var swing: Double
    var bars: Int
    var scaleKey: String?
    var styleLabel: String
    var sampleLabel: String
    var chordsLabel: String
    /// Keyed by pad, e.g. "A3" = bank A, pad 3.
    var sounds: [String: Sound]
    var pattern: PatternData
    var fxType: String?
    /// The name is a placeholder we made up ("CRATE 03", a demo's copy "FRENCH JAZZ 2"), so the first dig may name
    /// the project. false = named (from a prompt, GPT or by hand). nil = an older file (decided by the name's shape).
    var autoNamed: Bool? = nil
    /// MUTE: muted pads ("A3"…); absent in older projects.
    var muted: [String]? = nil
    /// SONG: sections, per-bank variations, edit variations and SONG/PATTERN mode; absent in older projects and when
    /// nothing was arranged. `pattern` is always the edit pattern (PATTERN mode's beat), never the rendered song.
    var arrangement: SongArrangement? = nil
}

// MARK: - Codable-friendly encodings

extension PadID {
    /// "A3" = bank A, pad number 3 (index 2).
    var key: String { bank.letter + String(number) }
    init?(key: String) {
        guard let first = key.first, let bank = Bank.allCases.first(where: { $0.letter == String(first).uppercased() }),
              let n = Int(key.dropFirst()), (1...16).contains(n) else { return nil }
        self.init(bank, n - 1)
    }
}

extension Project.PatternData {
    init(_ p: Pattern) {
        bars = p.bars
        swing = p.swing
        lanes = Dictionary(uniqueKeysWithValues: p.lanes.map { ($0.key.key, $0.value) })
        late = Dictionary(uniqueKeysWithValues: p.late.map { ($0.key.key, $0.value) })
        notes = Dictionary(uniqueKeysWithValues: p.notes.map { ($0.key.key, $0.value) })
        transpose = p.transpose == 0 ? nil : p.transpose
    }

    var pattern: Pattern {
        var p = Pattern()
        p.bars = max(1, bars)
        p.swing = swing
        for (k, v) in lanes { if let id = PadID(key: k) { p.lanes[id] = v } }
        for (k, v) in late { if let id = PadID(key: k) { p.late[id] = v } }
        for (k, v) in notes { if let id = PadID(key: k) { p.notes[id] = v } }
        p.transpose = max(-11, min(11, transpose ?? 0))
        return p
    }
}

extension Project.Sound {
    static let docsPrefix = "~docs/"
    static let libPrefix = "~lib/"

    init(_ s: PadSound) {
        id = s.id; name = s.name; category = s.category.rawValue
        start = s.start; end = s.end; rootNote = s.rootNote; gain = s.gain
        params = s.params.isDefault ? nil : s.params
        let path = s.fileURL.standardizedFileURL.path
        let docs = ProjectStore.documents.standardizedFileURL.path + "/"
        let lib = AppConfig.libraryURL.standardizedFileURL.path + "/"
        if let kit = Bundle.main.url(forResource: "DefaultKit", withExtension: nil), path.hasPrefix(kit.path + "/") {
            filePath = "~kit/" + String(path.dropFirst(kit.path.count + 1))
        } else if path.hasPrefix(docs) {
            filePath = Self.docsPrefix + String(path.dropFirst(docs.count))
        } else if path.hasPrefix(lib) {
            filePath = Self.libPrefix + String(path.dropFirst(lib.count))
        } else {
            filePath = path
        }
    }

    var padSound: PadSound {
        PadSound(id: id, name: name, category: Category(rawValue: category) ?? .perc, fileURL: fileURL,
                 start: start, end: end, rootNote: rootNote, gain: gain, source: "project", params: params ?? PadParams())
    }

    /// Older projects (and the bundled demo projects) hold absolute paths: the dev Mac's library or a previous
    /// install's app bundle. Anything under a ".../library/" folder is found again in this install's library.
    var fileURL: URL {
        if filePath.hasPrefix("~kit/"), let dir = Bundle.main.url(forResource: "DefaultKit", withExtension: nil) {
            return dir.appendingPathComponent(String(filePath.dropFirst(5)))
        }
        if filePath.hasPrefix(Self.docsPrefix) {
            return ProjectStore.documents.appendingPathComponent(String(filePath.dropFirst(Self.docsPrefix.count)))
        }
        if filePath.hasPrefix(Self.libPrefix) {
            let rel = String(filePath.dropFirst(Self.libPrefix.count))
            return Self.inLibrary(rel) ?? AppConfig.libraryURL.appendingPathComponent(rel)
        }
        if let r = filePath.range(of: "/library/", options: .backwards),
           let moved = Self.inLibrary(String(filePath[r.upperBound...])) {
            return moved
        }
        return URL(fileURLWithPath: filePath)
    }

    /// A library file by relative path. The app bundles the library as AAC `.caf` (`tools/encode_library.sh`) while
    /// older projects name the `.wav` originals, so either extension finds the file that's there.
    private static func inLibrary(_ rel: String) -> URL? {
        let url = AppConfig.libraryURL.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let ext = url.pathExtension.lowercased()
        guard ext == "wav" || ext == "caf" else { return nil }
        let other = url.deletingPathExtension().appendingPathExtension(ext == "wav" ? "caf" : "wav")
        return FileManager.default.fileExists(atPath: other.path) ? other : nil
    }
}

// MARK: - Store

/// Save / list / open / new, autosave (debounced 1 s on pattern / pad / tempo changes, and on background),
/// and restore of the last project on launch (skipped with `-crateFresh 1`).
@MainActor
@Observable
final class ProjectStore {
    static let shared = ProjectStore()

    private(set) var current: Project?
    private(set) var projects: [Project] = []

    @ObservationIgnored private weak var state: AppState?
    @ObservationIgnored private var booted = false
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var lastSig: Int?
    @ObservationIgnored private var savedSig: Int?
    @ObservationIgnored private var bgObserver: NSObjectProtocol?

    private static let lastKey = "crateLastProject"

    nonisolated static var documents: URL {
        CrateStorage.documents
    }
    nonisolated static var folder: URL {
        let u = documents.appendingPathComponent("projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    nonisolated static func url(_ id: String) -> URL { folder.appendingPathComponent(id + ".json") }

    var currentName: String { current?.name ?? "UNTITLED" }

    // MARK: Boot

    /// Call once at launch: restore the last project, then start the autosave watcher.
    func boot(state: AppState) async {
        guard !booted else { return }
        booted = true
        self.state = state
        Self.seedDefaults()
        refresh()
        if !AppConfig.devFlag("crateFresh"),
           let id = UserDefaults.standard.string(forKey: Self.lastKey),
           let p = projects.first(where: { $0.id == id }) {
            await load(p, into: state)
        }
        bgObserver = NotificationCenter.default.addObserver(forName: CrateLifecycle.saveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosaveNow() }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
    }

    /// First launch: the bundled FRENCH JAZZ, HIP HOP and HOUSE demo projects go into Projects, and FRENCH JAZZ opens.
    private static func seedDefaults() {
        #if os(macOS)
        let flag = "crateMacSeededDefaultsV1"
        let resource = "MacDefaultProjects"
        let ids = ["default-starter"]
        #else
        let flag = "crateSeededDefaultsV3"
        let resource = "DefaultProjects"
        let ids = ["default-frenchjazz", "default-hiphop", "default-house"]
        #endif
        guard !UserDefaults.standard.bool(forKey: flag),
              let dir = Bundle.main.url(forResource: resource, withExtension: nil) else { return }
        let fm = FileManager.default
        for id in ids {
            let src = dir.appendingPathComponent(id + ".json"), dst = url(id)
            // templates are refreshed on a new seed version (edits live in forked copies, never in these)
            if fm.fileExists(atPath: src.path) { try? fm.removeItem(at: dst); try? fm.copyItem(at: src, to: dst) }
        }
        UserDefaults.standard.set(true, forKey: flag)
        if UserDefaults.standard.string(forKey: lastKey) == nil
            || (resource == "MacDefaultProjects" && ["default-frenchjazz", "default-hiphop", "default-house"].contains(UserDefaults.standard.string(forKey: lastKey) ?? "")) {
            UserDefaults.standard.set(ids[0], forKey: lastKey)
        }
    }

    /// Debounce: save once the signature has been stable for ≥ 1 s (two consecutive 0.5 s ticks) and differs from the saved one.
    private func tick() {
        guard let state, !loading else { return }
        checkAutoName(state)
        let sig = signature(state)
        defer { lastSig = sig }
        guard sig == lastSig, sig != savedSig else { return }
        if current == nil && isEmpty(state) { return }
        save(state: state)
    }

    private func autosaveNow() {
        guard let state, !loading else { return }
        if current == nil && isEmpty(state) { return }
        if signature(state) != savedSig { save(state: state) }
    }

    private func isEmpty(_ s: AppState) -> Bool { pads(s).isEmpty && s.engine.pattern.lanes.isEmpty && s.engine.pattern.notes.isEmpty }

    private func signature(_ s: AppState) -> Int {
        var h = Hasher()
        h.combine(s.engine.pattern)
        h.combine(s.bpm); h.combine(s.swing); h.combine(s.fxType); h.combine(s.scaleKey)
        h.combine(s.styleLabel); h.combine(s.sampleLabel)
        h.combine(s.mutedPads)
        h.combine(s.song)
        for (k, v) in pads(s).sorted(by: { $0.key < $1.key }) { h.combine(k); h.combine(v) }
        return h.finalize()
    }

    private func pads(_ s: AppState) -> [String: PadSound] {
        var out: [String: PadSound] = [:]
        for bank in Bank.allCases {
            for i in 0..<16 {
                let pad = PadID(bank, i)
                if let snd = s.sound(pad) { out[pad.key] = snd }
            }
        }
        return out
    }

    // MARK: API

    func list() -> [Project] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(Project.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }

    func refresh() { projects = list() }

    /// Saves the state into the current project (creating one if there is none). `asNew` forks a new project.
    @discardableResult
    func save(state: AppState, name: String? = nil, asNew: Bool = false) -> Project {
        let now = Date()
        var p: Project
        // The bundled demo projects are templates: the first change forks a copy so they're never overwritten.
        var name = name
        var asNew = asNew
        // A name passed in was chosen (by hand, or from a prompt); otherwise it's a placeholder the first dig replaces.
        let chosen = !(name ?? "").isEmpty
        if !asNew, let c = current, c.id.hasPrefix("default-") {
            asNew = true
            if name == nil { name = uniqueName(c.name + " 2") }
        }
        if let c = current, !asNew {
            p = c
        } else {
            p = Project(id: UUID().uuidString, name: name ?? autoName(state), created: now, updated: now,
                        bpm: 90, swing: 50, bars: 1, scaleKey: nil, styleLabel: "", sampleLabel: "", chordsLabel: "",
                        sounds: [:], pattern: .init(.empty), fxType: nil, autoNamed: !chosen)
        }
        if let name, !name.isEmpty { p.name = name }
        if chosen { p.autoNamed = false }
        // SONG mode plays the rendered song; the project keeps the beat (the edit pattern) + the arrangement.
        if state.song.isUsed { Orchestrator.current?.syncFromPattern() }
        let pattern = state.song.songMode ? (Orchestrator.current?.lastPattern ?? state.engine.pattern) : state.engine.pattern
        p.arrangement = state.song.isUsed || state.song.songMode ? state.song : nil
        p.updated = now
        p.bpm = state.bpm; p.swing = state.swing; p.bars = pattern.bars
        p.scaleKey = state.scaleKey
        p.styleLabel = state.styleLabel; p.sampleLabel = state.sampleLabel; p.chordsLabel = state.chordsLabel
        p.sounds = pads(state).mapValues(Project.Sound.init)
        p.pattern = .init(pattern)
        p.fxType = state.fxType
        p.muted = state.mutedPads.isEmpty ? nil : state.mutedPads.map(\.key).sorted()
        write(p)
        current = p
        savedSig = signature(state)
        UserDefaults.standard.set(p.id, forKey: Self.lastKey)
        refresh()
        DebugLog.event("project_save", ["id": p.id, "name": p.name, "pads": p.sounds.count])
        return p
    }

    func load(_ p: Project, into state: AppState) async {
        loading = true
        defer { loading = false }
        let e = state.engine
        var byBank: [Bank: [Int: PadSound]] = [:]
        for (k, snd) in p.sounds {
            guard let pad = PadID(key: k) else { continue }
            byBank[pad.bank, default: [:]][pad.index] = snd.padSound
        }
        // Every bank reloads (empty = cleared) so the previous project's pads don't linger.
        if e is MockEngine {
            for b in Bank.allCases { try? await e.loadBank(b, sounds: byBank[b] ?? [:]) }
        } else {
            await withTaskGroup(of: Void.self) { g in
                for b in Bank.allCases {
                    let snd = byBank[b] ?? [:]
                    g.addTask { try? await e.loadBank(b, sounds: snd) }
                }
            }
        }
        var sounds: [PadID: PadSound] = [:]
        for (b, m) in byBank { for (i, s) in m { sounds[PadID(b, i)] = s } }
        state.sounds = sounds
        e.bpm = p.bpm; state.bpm = p.bpm
        e.swing = p.swing; state.swing = p.swing
        let pattern = p.pattern.pattern
        e.setPattern(pattern, timing: .now)
        Orchestrator.current?.lastPattern = pattern
        state.bars = pattern.bars
        var song = p.arrangement ?? SongArrangement()
        let songMode = song.songMode
        song.songMode = false
        state.song = song
        state.scaleKey = p.scaleKey
        state.styleLabel = p.styleLabel.isEmpty ? "CRATE" : p.styleLabel
        state.sampleLabel = p.sampleLabel
        state.chordsLabel = p.chordsLabel
        Orchestrator.current?.restoreSession()
        state.selectFX(p.fxType.flatMap(FXType.init(rawValue:)))
        state.setMutes(Set((p.muted ?? []).compactMap { PadID(key: $0) }))
        if songMode { Orchestrator.current?.enterSong() }
        current = p
        naming = nil
        titleWatch = nil
        UserDefaults.standard.set(p.id, forKey: Self.lastKey)
        savedSig = signature(state)
        lastSig = savedSig
        state.addLog("PROJECT", "open \(p.name)", tint: .grey)
        DebugLog.event("project_open", ["id": p.id, "name": p.name, "pads": p.sounds.count])
    }

    /// Stop, clear the pattern and banks B–D (bank A's drum kit stays), 90 BPM, then start a fresh project.
    func newProject(state: AppState) async {
        let e = state.engine
        loading = true
        if e.isPlaying { e.stop() }
        state.isPlaying = false
        if state.isRecording { state.setRecording(false) }
        e.setPattern(Pattern(bars: 4, swing: 50), timing: .now)
        Orchestrator.current?.lastPattern = .empty
        Orchestrator.current?.session = nil
        state.song = SongArrangement()
        for b in [Bank.b, .c, .d] { try? await e.loadBank(b, sounds: [:]) }
        state.sounds = state.sounds.filter { $0.key.bank == .a }
        e.bpm = 90; state.bpm = 90
        e.swing = 50; state.swing = 50
        state.bars = 4
        state.styleLabel = "CRATE"; state.sampleLabel = ""; state.chordsLabel = ""; state.scaleKey = nil
        state.selectFX(nil)
        state.setMutes([])
        current = nil
        naming = nil
        titleWatch = nil
        loading = false
        save(state: state, asNew: true)
        state.addLog("PROJECT", "new \(currentName)", tint: .grey)
    }

    func delete(_ p: Project) {
        try? FileManager.default.removeItem(at: Self.url(p.id))
        if current?.id == p.id {
            current = nil
            savedSig = nil
            UserDefaults.standard.removeObject(forKey: Self.lastKey)
        }
        refresh()
    }

    /// "CRATE 03 · J DILLA" (a placeholder: the project's first dig renames it).
    func autoName(_ state: AppState) -> String {
        let n = String(format: "%02d", list().count + 1)
        let style = state.styleLabel.trimmingCharacters(in: .whitespaces).uppercased()
        return uniqueName(style.isEmpty || style == "CRATE" ? "CRATE \(n)" : "CRATE \(n) · \(style)")
    }

    /// `name`, or "name 2", "name 3"… if another project has it already ("FRENCH JAZZ 2" → "FRENCH JAZZ 3").
    func uniqueName(_ name: String, excluding id: String? = nil) -> String {
        let taken = Set(list().filter { $0.id != id }.map { $0.name.uppercased() })
        guard taken.contains(name.uppercased()) else { return name }
        var base = name, n = 2
        if let r = name.range(of: #" \d+$"#, options: .regularExpression), let k = Int(name[r].dropFirst()) {
            base = String(name[..<r.lowerBound])
            n = k + 1
        }
        while taken.contains("\(base) \(n)".uppercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Auto-naming

    /// A dig waiting to be confirmed as a beat prompt (commands like "undo" or "100 bpm" never name a project).
    @ObservationIgnored private var naming: (prompt: String, at: Date, title: String?)?
    /// After the prompt named the project: GPT's title for that same dig replaces the name once.
    @ObservationIgnored private var titleWatch: (projectID: String, prompt: String, title: String?, at: Date)?

    /// Every typed (or chip) prompt comes through here (AppState.dig). The first dig of a project that still has a
    /// placeholder name names it: right away from the prompt ("Boom Bap Piano"), then once more from GPT's title
    /// if it arrives for that dig. A project that has a real name is never renamed.
    func promptSubmitted(_ prompt: String) {
        titleWatch = nil   // a new dig: an earlier dig's title no longer counts
        guard needsName else { naming = nil; return }
        naming = (prompt, Date(), arrangementSignature)
    }

    /// The current project still has a made-up name (or there's no project yet, or it's a demo template).
    private var needsName: Bool {
        guard let c = current else { return true }
        if c.id.hasPrefix("default-") { return true }   // the dig forks the demo under the new name
        return c.autoNamed ?? Self.looksAutoNamed(c.name)
    }

    /// Older project files have no `autoNamed`: "CRATE 03 · J DILLA", "UNTITLED" and a demo's copy are placeholders.
    static func looksAutoNamed(_ name: String) -> Bool {
        let n = name.uppercased()
        if n == "UNTITLED" || n.range(of: #"^CRATE \d+( · .*)?$"#, options: .regularExpression) != nil { return true }
        return ["FRENCH JAZZ", "HIP HOP", "HOUSE"].contains { n.range(of: "^\($0) \\d+$", options: .regularExpression) != nil }
    }

    /// GPT's last applied arrangement (title + timing), to notice a new one arriving.
    private var arrangementSignature: String? {
        guard let a = Orchestrator.current?.lastArrangement else { return nil }
        return "\(a.title)|\(state?.gptSeconds ?? 0)"
    }

    /// Polled by the autosave tick (every 0.5 s).
    private func checkAutoName(_ state: AppState) {
        let now = Date()
        if let n = naming {
            // The orchestrator saves an UNDO step labelled with the prompt only for a real dig (not a command).
            if let top = EditHistory.shared.stack.last?.label, Self.isLabel(top, of: n.prompt) {
                naming = nil
                if let name = Self.nameFromPrompt(n.prompt) {
                    applyName(name, state: state)
                    if let id = current?.id { titleWatch = (id, n.prompt, n.title, n.at) }
                }
            } else if now.timeIntervalSince(n.at) > 4 {
                naming = nil
            }
        }
        if let w = titleWatch {
            let key = w.prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if now.timeIntervalSince(w.at) > 30 || current?.id != w.projectID {
                titleWatch = nil
            } else if let sig = arrangementSignature, sig != w.title,
                      Orchestrator.current?.lastPromptKey == key,   // that dig's arrangement, not a FLIP IT's
                      let title = Orchestrator.current?.lastArrangement?.title,
                      let name = Self.nameFromTitle(title) {
                titleWatch = nil
                applyName(name, state: state)
            }
        }
    }

    /// Names the current project (forking the demo / creating the project if needed); never adds a second " 2".
    private func applyName(_ raw: String, state: AppState) {
        if let c = current, !c.id.hasPrefix("default-") {
            let name = uniqueName(raw, excluding: c.id)
            guard name != c.name || c.autoNamed != false else { return }
            var p = c
            p.name = name
            p.autoNamed = false
            write(p)
            current = p
            refresh()
        } else {
            save(state: state, name: uniqueName(raw), asNew: true)
        }
        DebugLog.event("project_autoname", ["name": current?.name ?? raw])
    }

    /// The orchestrator's UNDO label for a prompt (long prompts are cut to 26 characters + "…").
    private static func isLabel(_ label: String, of prompt: String) -> Bool {
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if label == t { return true }
        return t.count > 28 && label.hasSuffix("…") && t.hasPrefix(String(label.dropLast()))
    }

    private static let fillerWords: Set<String> = [
        "a", "an", "the", "with", "and", "some", "of", "for", "to", "in", "on", "at", "by", "from", "into", "over",
        "me", "my", "i", "us", "we", "you", "it", "its", "this", "that", "please", "pls", "just", "really", "very",
        "make", "give", "gimme", "get", "add", "put", "want", "need", "like", "type", "kind", "style", "vibe",
        "beat", "beats", "loop", "loops", "track", "song", "sample", "samples", "bar", "bars", "bpm", "plus",
        "something", "more", "less", "bit", "little", "lot", "up",
    ]
    private static let wordCase: [String: String] = [
        "uk": "UK", "ny": "NY", "la": "LA", "rnb": "R&B", "r&b": "R&B", "edm": "EDM", "dj": "DJ", "mpc": "MPC",
        "sp": "SP", "lofi": "Lofi", "lo-fi": "Lo-Fi", "hiphop": "Hip Hop", "j": "J",
    ]

    private static func titleWord(_ w: String) -> String {
        let l = w.lowercased()
        if let fixed = wordCase[l] { return fixed }
        guard let f = l.first, f.isLetter else { return l }   // "90s", "808s"
        return f.uppercased() + l.dropFirst()
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "&" || $0 == "-" || $0 == "'") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-'")) }
            .filter { !$0.isEmpty }
    }

    /// Words that start a new part of a prompt ("boom bap | with a piano sample").
    private static let joiners: Set<String> = ["with", "and", "plus", "over", "feat", "featuring", "ft", "&"]

    /// At most three words, whole parts only: "boom bap with a piano sample" → "Boom Bap Piano",
    /// "90s boom bap with a piano sample" → "90s Boom Bap", "trap beat with 808s and hi hat rolls" → "Trap 808s".
    static func nameFromPrompt(_ prompt: String) -> String? {
        let all = words(prompt.replacingOccurrences(of: ",", with: " with ").replacingOccurrences(of: "+", with: " with "))
            .filter { !$0.allSatisfy(\.isNumber) }
        var parts: [[String]] = [[]]
        for w in all {
            if joiners.contains(w) { parts.append([]) } else if !fillerWords.contains(w) { parts[parts.count - 1].append(w) }
        }
        var pick: [String] = []
        for p in parts where !p.isEmpty {
            if pick.isEmpty { pick = Array(p.prefix(3)) } else if pick.count + p.count <= 3 { pick += p } else { break }
        }
        if pick.isEmpty { pick = Array(all.filter { !joiners.contains($0) }.prefix(3)) }
        guard !pick.isEmpty else { return nil }
        return String(pick.map(titleWord).joined(separator: " ").prefix(28))
    }

    /// GPT's "NUJ DILLA POCKET" → "Nuj Dilla Pocket" (at most four words).
    static func nameFromTitle(_ title: String) -> String? {
        let w = words(title)
        guard !w.isEmpty else { return nil }
        return String(w.prefix(4).map(titleWord).joined(separator: " ").prefix(28))
    }

    private func write(_ p: Project) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try enc.encode(p).write(to: Self.url(p.id), options: .atomic) } catch {
            DebugLog.event("error", ["where": "project_save", "msg": "\(error)"])
        }
    }

    // MARK: Router  crate://project?cmd=new|save|open&name=…

    func handle(cmd: String, name: String?, state: AppState) async {
        switch cmd {
        case "new": await newProject(state: state)
        case "save", "saveas":
            save(state: state, name: name, asNew: cmd == "saveas" || (name != nil && name != current?.name))
        case "open":
            let all = list()
            let p = name.flatMap { n in all.first { $0.name.lowercased() == n.lowercased() || $0.id == n } } ?? all.first
            if let p { await load(p, into: state) }
        default: break
        }
    }
}
