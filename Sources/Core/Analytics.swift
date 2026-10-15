import Foundation
import Observation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Product analytics, RUM-style: every tap (TapTracker resolves the element under the finger), how long each
/// screen / sheet stays up (ScreenTracker), frustration signals (rage / dead taps, quick dismisses, AI retries, undo
/// bursts, errors seen), every AI prompt with what it changed, whether it was reverted (and how fast), and 👍 / 👎.
/// Events queue to a file and go in batches to our server (site/api/events.js → private Vercel Blob).
/// No third-party SDK, no ad identifiers, no text field contents except prompts.
final class Analytics: @unchecked Sendable {
    static let shared = Analytics()

    let session = UUID().uuidString.prefix(8).lowercased()
    let install: String
    private let q = DispatchQueue(label: "com.shuhan.crate.analytics", qos: .utility)
    private var buffer: [[String: Any]] = []
    private var screen: (name: String, since: Date)?
    private var flushing = false
    private let started = Date()
    private let fileURL: URL
    private static let maxQueued = 5_000
    /// This session's roll-up for `crate://analytics` (taps per element, screen time, frustration counts). On `q`.
    private var agg = Rollup()
    private var recentPrompts: [(norm: String, text: String, at: Date)] = []
    /// When something last happened (any event but taps and bookkeeping): a tap with no effect after it is dead.
    private var lastEffect = Date.distantPast
    private static let passive: Set<String> = ["tap", "dead_tap", "rage_tap", "pad_activity", "ax_cost", "screen",
                                               "quick_dismiss"]

    func hadEffect(since: Date) -> Bool { q.sync { lastEffect >= since } }

    private init() {
        let d = UserDefaults.standard
        if let i = d.string(forKey: "crateInstallID") { install = i } else {
            install = UUID().uuidString.lowercased()
            d.set(install, forKey: "crateInstallID")
        }
        #if os(macOS)
        let support = CrateStorage.documents
        #else
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        let dir = support.appendingPathComponent("analytics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("queue.jsonl")
    }

    /// Call once at launch: session start, periodic flush, flush on background.
    func start() {
        track("session_start", ["device": CrateLifecycle.deviceName, "os": ProcessInfo.processInfo.operatingSystemVersionString])
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.flush() }
        NotificationCenter.default.addObserver(forName: CrateLifecycle.saveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.endScreen()
            self.track("session_background", ["sec": Int(Date().timeIntervalSince(self.started))])
            self.flush()
        }
        NotificationCenter.default.addObserver(forName: CrateLifecycle.activeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.track("session_foreground")
        }
    }

    func track(_ name: String, _ props: [String: Any] = [:]) {
        // "Share usage analytics" off (projects sheet): nothing is kept or sent.
        guard PrivacyChoices.analyticsAllowed else { return }
        var e = Self.redacted(name, props)
        e["e"] = name
        e["t"] = ISO8601DateFormatter.crate.string(from: Date())
        e["s"] = String(session)
        e["i"] = install
        e["v"] = Self.build
        let now = Date()
        q.async {
            if !Self.passive.contains(name) { self.lastEffect = now }
            self.buffer.append(e)
            self.append(e)
            self.agg.add(e)
            if name == "prompt", let text = props["text"] as? String { self.checkRetry(text) }
        }
        DebugLog.event("analytics", props.merging(["name": name]) { a, _ in a })
    }

    /// Without AI consent the user's own words (prompts, spoken requests, imported file names) never leave the device,
    /// so they're dropped from analytics too; the event itself (that a prompt happened, what it changed) stays.
    private static func redacted(_ name: String, _ props: [String: Any]) -> [String: Any] {
        guard !PrivacyChoices.aiAllowed else { return props }
        var p = props
        for k in ["text", "prev", "prompt"] where p[k] != nil { p[k] = "-" }
        if name == "import_song" { p["name"] = nil }
        if let r = p["reason"] as? String, r.hasPrefix("said:") { p["reason"] = "said" }
        return p
    }

    /// Analytics switched off: drop everything queued (memory + disk).
    func clearQueue() {
        q.async {
            self.buffer.removeAll()
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }

    /// A semantic action seen in code (bank switch, sound swap, song cell…). Logged as `action`: `tap` events are the
    /// physical taps TapTracker resolves (`id` = the element's accessibility identifier), so the two never double count.
    func tap(_ id: String, _ ctx: [String: Any] = [:]) { track("action", ctx.merging(["id": id]) { a, _ in a }) }

    /// A sheet / panel says it's up (`setScreen("ai_log")` on appear) or gone (`setScreen("main")` on disappear).
    /// The main screen itself comes from AnalyticsObserver; sheets are a stack in ScreenTracker, so a nested sheet
    /// restores the one under it. Prefer `.analyticsScreen("name")` on new panels.
    func setScreen(_ name: String) {
        Task { @MainActor in
            if name == "main" || name.isEmpty { ScreenTracker.shared.pop(token: "legacy") }
            else { ScreenTracker.shared.push(name, token: "legacy") }
        }
    }

    /// ScreenTracker: the screen in front of the user is now `name`; logs how long the previous one stayed up.
    func recordScreen(_ name: String) {
        q.async {
            if self.screen?.name == name { return }
            self.endScreenLocked()
            self.screen = (name, Date())
        }
    }

    func endScreen() { q.async { self.endScreenLocked() } }

    private func endScreenLocked() {
        guard let s = screen else { return }
        let ms = Int(Date().timeIntervalSince(s.since) * 1000)
        screen = nil
        if ms < 300 || !PrivacyChoices.analyticsAllowed { return }
        var e: [String: Any] = ["e": "screen", "name": s.name, "ms": ms]
        e["t"] = ISO8601DateFormatter.crate.string(from: Date())
        e["s"] = String(session); e["i"] = install; e["v"] = Self.build
        buffer.append(e)
        append(e)
        agg.add(e)
        DebugLog.event("analytics", ["name": "screen", "screen": s.name, "ms": ms])
    }

    // MARK: frustration: AI retry

    /// The same or a very similar prompt again within 60 s: the first try didn't do what was meant.
    private func checkRetry(_ text: String) {
        let now = Date()
        let norm = Self.normalize(text)
        recentPrompts.removeAll { now.timeIntervalSince($0.at) > 60 }
        if !norm.isEmpty, let prev = recentPrompts.last(where: { Self.similarity($0.norm, norm) >= 0.75 }) {
            let sim = Self.similarity(prev.norm, norm)
            track("ai_retry", ["text": text, "prev": prev.text, "sec": (now.timeIntervalSince(prev.at) * 10).rounded() / 10,
                               "sim": (sim * 100).rounded() / 100])
        }
        recentPrompts.append((norm, text, now))
    }

    /// Lowercase words only: "Add a SAX line!" → "add a sax line".
    static func normalize(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// 0…1: the better of word overlap (ignoring filler words) and edit distance.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let filler: Set<Substring> = ["a", "an", "the", "some", "please", "pls", "it"]
        let wa = Set(a.split(separator: " ")).subtracting(filler), wb = Set(b.split(separator: " ")).subtracting(filler)
        let jac = wa.union(wb).isEmpty ? 0 : Double(wa.intersection(wb).count) / Double(wa.union(wb).count)
        let x = Array(a.prefix(120)), y = Array(b.prefix(120))
        guard !x.isEmpty, !y.isEmpty else { return jac }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var diag = row[0]
            row[0] = i
            for j in 1...y.count {
                let up = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, diag + (x[i - 1] == y[j - 1] ? 0 : 1))
                diag = up
            }
        }
        let lev = 1 - Double(row[y.count]) / Double(max(x.count, y.count))
        return max(jac, lev)
    }

    // MARK: local report

    /// This session so far: top elements by taps, screen time, frustration counts (`crate://analytics`).
    func summary() -> [String: Any] {
        q.sync {
            var s = agg.report()
            if let cur = screen { s["current"] = [cur.name, Int(Date().timeIntervalSince(cur.since) * 1000)] as [Any] }
            s["session"] = String(session)
            s["sec"] = Int(Date().timeIntervalSince(started))
            return s
        }
    }

    // MARK: queue + upload

    private func append(_ e: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: e), var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let h = try? FileHandle(forWritingTo: fileURL) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: fileURL)
        }
    }

    func flush() {
        q.async {
            guard !self.flushing, PrivacyChoices.analyticsAllowed, let token = AppConfig.appToken, !AppConfig.offline else { return }
            guard let text = try? String(contentsOf: self.fileURL, encoding: .utf8), !text.isEmpty else { return }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            if lines.count > Self.maxQueued { lines = lines.suffix(Self.maxQueued) }
            let batch = lines.prefix(500)
            let body = batch.joined(separator: "\n")
            var req = URLRequest(url: AppConfig.aiBase.deletingLastPathComponent().appendingPathComponent("events"))
            req.httpMethod = "POST"
            req.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
            req.setValue(token, forHTTPHeaderField: "x-crate-token")
            req.httpBody = Data(body.utf8)
            req.timeoutInterval = 15
            self.flushing = true
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                self.q.async {
                    self.flushing = false
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
                    // Drop what was sent; anything appended meanwhile stays queued.
                    let now = (try? String(contentsOf: self.fileURL, encoding: .utf8)) ?? ""
                    let all = now.split(separator: "\n", omittingEmptySubsequences: true)
                    let rest = all.count > batch.count ? all.dropFirst(batch.count).joined(separator: "\n") + "\n" : ""
                    try? Data(rest.utf8).write(to: self.fileURL)
                    self.buffer.removeAll()
                }
            }.resume()
        }
    }

    /// Recent events (newest last) for the in-app feedback log and debugging.
    func recent(_ n: Int = 200) -> [[String: Any]] { q.sync { Array(buffer.suffix(n)) } }

    static let build: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v)(\(b))"
    }()
}

/// Session counters behind `Analytics.summary()`.
private struct Rollup {
    static let frustration: Set<String> = ["rage_tap", "dead_tap", "quick_dismiss", "ai_retry", "ai_reverted",
                                           "undo_burst", "error_seen"]
    var taps: [String: Int] = [:]
    var holds: [String: Int] = [:]
    var drags: [String: Int] = [:]
    var pads: [String: Int] = [:]
    var screenMs: [String: Int] = [:]
    var visits: [String: Int] = [:]
    var frustration: [String: Int] = [:]
    var rage: [String: Int] = [:]
    var dead: [String: Int] = [:]
    var actions = 0

    mutating func add(_ e: [String: Any]) {
        guard let name = e["e"] as? String else { return }
        switch name {
        case "tap":
            let id = e["id"] as? String ?? "?"
            if e["drag"] != nil { drags[id, default: 0] += 1; break }
            taps[id, default: 0] += 1
            if e["hold_ms"] != nil { holds[id, default: 0] += 1 }
        case "pad_activity":
            for (k, v) in e["counts"] as? [String: Int] ?? [:] { pads[k, default: 0] += v }
        case "screen":
            let n = e["name"] as? String ?? "?"
            screenMs[n, default: 0] += e["ms"] as? Int ?? 0
            visits[n, default: 0] += 1
        case "action": actions += 1
        default: break
        }
        if Self.frustration.contains(name) {
            frustration[name, default: 0] += 1
            let at = e["id"] as? String ?? e["region"] as? String ?? "?"
            if name == "rage_tap" { rage[at, default: 0] += 1 }
            if name == "dead_tap" { dead[at, default: 0] += 1 }
        }
    }

    func report() -> [String: Any] {
        func top(_ d: [String: Int], _ n: Int) -> [[Any]] {
            d.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(n).map { [$0.key, $0.value] }
        }
        return ["taps_total": taps.values.reduce(0, +), "top_taps": top(taps, 30), "holds": top(holds, 10),
                "drags": top(drags, 10), "pads": top(pads, 16), "screen_ms": top(screenMs, 40), "visits": top(visits, 40),
                "frustration": frustration, "rage_by_element": top(rage, 10), "dead_by_region": top(dead, 10),
                "actions": actions]
    }
}

extension ISO8601DateFormatter {
    static let crate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// One AI change the user can rate: what was asked, what it touched, what it left alone.
struct AIChange: Identifiable, Equatable {
    let id: String
    var prompt: String
    var scope: String
    var at: Date
    var changed: [String]
    var kept: [String]
    var note: String
    var rating = 0          // +1 👍, −1 👎
    var reason: String? = nil
    var reverted = false
    var gpt = false

    var summary: String {
        if changed.isEmpty { return note.isEmpty ? "No change" : note }
        if changed.first == "new beat" { return "New beat · " + changed.dropFirst().prefix(5).joined(separator: ", ") }
        // "Added sax line · Changed hats · kept kick, snare…"
        let added = changed.filter { $0.hasPrefix("added ") }.map { String($0.dropFirst(6)) }
        let removed = changed.filter { $0.hasPrefix("removed ") }.map { String($0.dropFirst(8)) }
        let loaded = changed.filter { $0.contains(" ← ") }
        if !loaded.isEmpty, loaded.count == changed.count { return loaded.prefix(2).joined(separator: " · ") }
        let edited = changed.filter { !$0.hasPrefix("added ") && !$0.hasPrefix("removed ") && !$0.contains(" ← ") }
        var parts: [String] = []
        if !added.isEmpty { parts.append("Added " + added.prefix(3).joined(separator: ", ")) }
        if !edited.isEmpty { parts.append("Changed " + edited.prefix(3).joined(separator: ", ") + (edited.count > 3 ? "…" : "")) }
        if !removed.isEmpty { parts.append("Removed " + removed.prefix(3).joined(separator: ", ")) }
        let c = parts.joined(separator: " · ")
        if kept.isEmpty { return c }
        return c + " · kept " + kept.prefix(3).joined(separator: ", ") + (kept.count > 3 ? "…" : "")
    }
}

/// The session's AI changes, newest last: the result line shows the latest with 👍 / 👎, the log sheet shows them all.
@MainActor @Observable
final class AIChangeLog {
    static let shared = AIChangeLog()
    private(set) var items: [AIChange] = []
    var latest: AIChange? { items.last }

    func record(_ c: AIChange) {
        if let i = items.firstIndex(where: { $0.id == c.id }) { items[i] = c } else { items.append(c) }
        if items.count > 100 { items.removeFirst(items.count - 100) }
    }

    func update(_ id: String, _ f: (inout AIChange) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        f(&items[i])
    }

    func rate(_ id: String, _ value: Int, reason: String? = nil) {
        update(id) { c in
            c.rating = value
            if let r = reason { c.reason = r }
        }
        guard let c = items.first(where: { $0.id == id }) else { return }
        Analytics.shared.track("ai_rating", ["change": id, "rating": value, "reason": reason ?? "", "prompt": c.prompt,
                                             "scope": c.scope, "changed": c.changed, "summary": c.summary])
        Analytics.shared.flush()
    }

    private var undoTimes: [Date] = []

    /// UNDO pressed: if it undid the latest AI change, that change counts as reverted (and how fast).
    /// Three undos within 10 s = `undo_burst` (something went wrong and the user is digging back out).
    func noteUndo(label: String) {
        let now = Date()
        undoTimes = undoTimes.filter { now.timeIntervalSince($0) < 10 } + [now]
        if undoTimes.count >= 3 {
            Analytics.shared.track("undo_burst", ["n": undoTimes.count,
                                                  "sec": (now.timeIntervalSince(undoTimes[0]) * 10).rounded() / 10,
                                                  "screen": ScreenTracker.shared.current])
            undoTimes.removeAll()
        }
        guard let c = latest, !c.reverted else {
            Analytics.shared.track("undo", ["label": label])
            return
        }
        let sec = Date().timeIntervalSince(c.at)
        update(c.id) { $0.reverted = true }
        Analytics.shared.track("ai_reverted", ["change": c.id, "sec": (sec * 10).rounded() / 10, "prompt": c.prompt,
                                               "scope": c.scope, "label": label])
    }
}
