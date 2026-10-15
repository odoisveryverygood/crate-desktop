import Foundation

/// One typed answer from Jev. `score` is normalized to 0...1 (raw score / (levels − 1)).
struct JevAnswer {
    var type: String
    var choice: String? = nil
    var confidence: Double? = nil
    var probabilities: [String: Double] = [:]
    var score: Double? = nil
    var rawScore: Double? = nil
    var noul: Double? = nil
    /// Probability of the winning choice (falls back to confidence).
    var choiceProb: Double { choice.flatMap { probabilities[$0] } ?? confidence ?? 0 }
}

typealias JevAnswers = [String: JevAnswer]

/// Race an async operation against a timeout; nil on timeout or error.
func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await op() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, seconds) * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// TypeSafe Jev System-1 client: POST https://api.typesafe.ai/v1/systemone (never jevapi.org / tokenra.io).
final class JevClient: @unchecked Sendable {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    private let session: URLSession
    private let questions: [String: Any]

    /// Off until the user allows AI requests to leave the device (PrivacyChoices), and when offline.
    var available: Bool { (AppConfig.hostedAIEnabled || AppConfig.appToken != nil || AppConfig.typesafeKey != nil) && !AppConfig.offline
        && PrivacyChoices.aiAllowed }

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.waitsForConnectivity = false
        cfg.urlCache = nil
        cfg.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: cfg)
        questions = JevClient.loadQuestions()
    }

    static func loadQuestions() -> [String: Any] {
        var urls: [URL] = []
        if let u = Bundle.main.url(forResource: "jev-questions", withExtension: "json") { urls.append(u) }
        if let u = Bundle.main.url(forResource: "jev-questions", withExtension: "json", subdirectory: "AI") { urls.append(u) }
        urls.append(AppConfig.libraryURL.deletingLastPathComponent().appendingPathComponent("ai/jev-questions.json"))
        for u in urls {
            if let d = try? Data(contentsOf: u), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], o["plan"] != nil {
                return o
            }
        }
        return ((try? JSONSerialization.jsonObject(with: Data(EmbeddedJevQuestions.json.utf8))) as? [String: Any]) ?? [:]
    }

    func questionSet(_ name: String) -> [String: Any] {
        ((questions[name] as? [String: Any])?["questions"] as? [String: Any]) ?? [:]
    }

    /// Opens the TLS connection early so the first DIG is fast.
    func warmUp() {
        guard available else { return }
        Task.detached { [self] in
            let q: [String: Any] = ["ok": ["type": "noul", "instructions": "This text is a greeting."]]
            if let r = await self.ask(state: "hello", questions: q, timeout: 4) {
                DebugLog.event("jev_warm", ["ms": r.ms])
            }
        }
    }

    /// Ask one of the question sets from jev-questions.json ("plan", "perform", "route").
    func ask(_ set: String, state: String, timeout: Double) async -> (answers: JevAnswers, ms: Int)? {
        let q = questionSet(set)
        guard !q.isEmpty else { return nil }
        return await ask(state: state, questions: q, timeout: timeout)
    }

    func ask(state: String, questions q: [String: Any], timeout: Double) async -> (answers: JevAnswers, ms: Int)? {
        #if os(macOS)
        if AppConfig.hostedAIEnabled && PrivacyChoices.aiAllowed && !AppConfig.offline {
            guard await MacHostedAI.shared.ensureSession() else { return nil }
        }
        #endif
        guard available else { return nil }
        var req: URLRequest
        if AppConfig.typesafeKey == nil, let token = AppConfig.appToken {                 // via our server, which holds the key
            req = URLRequest(url: AppConfig.aiBase.appendingPathComponent("jev"))
            req.setValue(token, forHTTPHeaderField: "x-crate-token")
        } else {                                             // Debug environment or the Mac user’s private Keychain credential
            req = URLRequest(url: Self.endpoint)
            req.setValue("Bearer \(AppConfig.typesafeKey ?? "")", forHTTPHeaderField: "Authorization")
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = max(1, timeout + 0.5)
        let body: [String: Any] = ["model": "jev-latest", "state": state, "questions": q]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = payload
        let t0 = Date()
        let urlSession = session
        let request = req
        let result: (Data, Int)? = await withTimeout(timeout) {
            let (d, r) = try await urlSession.data(for: request)
            return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        guard let (data, status) = result else {
            DebugLog.event("error", ["where": "jev", "msg": "timeout \(ms)ms"])
            return nil
        }
        #if os(macOS)
        if status == 401 && AppConfig.hostedAIEnabled { await MacHostedAI.shared.invalidate() }
        #endif
        guard status == 200, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let answers = obj["answers"] as? [String: Any] else {
            DebugLog.event("error", ["where": "jev", "msg": "HTTP \(status)"])
            return nil
        }
        return (parse(answers, questions: q), ms)
    }

    private func parse(_ answers: [String: Any], questions q: [String: Any]) -> JevAnswers {
        var out: JevAnswers = [:]
        for (id, v) in answers {
            guard let a = v as? [String: Any] else { continue }
            var ans = JevAnswer(type: a["type"] as? String ?? "")
            ans.choice = (a["choice"] as? String) ?? (a["choice"] as? NSNumber)?.stringValue
            ans.confidence = (a["confidence"] as? NSNumber)?.doubleValue
            if let p = a["probabilities"] as? [String: Any] {
                ans.probabilities = p.compactMapValues { ($0 as? NSNumber)?.doubleValue }
            }
            if let s = (a["score"] as? NSNumber)?.doubleValue {
                let def = q[id] as? [String: Any]
                let levels = (def?["criteria"] as? [Any])?.count ?? (a["legend"] as? [String: Any])?.count ?? 5
                ans.rawScore = s
                ans.score = max(0, min(1, s / Double(max(1, levels - 1))))
            }
            ans.noul = (a["noul"] as? NSNumber)?.doubleValue
            out[id] = ans
        }
        return out
    }
}

extension Plan {
    /// Jev upgrades the keyword plan where its choice probability is > 0.4 (explicit bars/bpm/flip stay).
    mutating func merge(_ a: JevAnswers, ms: Int) {
        source = "jev"
        jevMs = ms
        func pick(_ id: String) -> String? {
            guard let x = a[id], let c = x.choice, x.choiceProb > 0.4, c != "unspecified" else { return nil }
            return c
        }
        func note(_ id: String) { jevOverrides.append(id) }
        if ![.flip, .singleSound, .addLayer, .laneEdit].contains(scope), let s = pick("scope"), let sc = Scope(rawValue: s) {
            if sc != scope { note("scope") }
            scope = sc
        }
        // A known artist reference (ArtistReferences) keeps its curated styles; Jev maps the ones we don't list.
        let curated = reference != nil && drumStyle != nil
        if !curated, let s = pick("drum_style"), let st = Style(rawValue: s) { if st != drumStyle { note("drum_style") }; drumStyle = st }
        if !curated, let s = pick("sample_style"), let st = Style(rawValue: s) { if st != sampleStyle { note("sample_style") }; sampleStyle = st }
        if let s = pick("instrument"), s != "any" { if s != instrument { note("instrument") }; instrument = s }
        if let x = a["mood"], let c = x.choice, c != "unspecified", x.choiceProb > (mood != nil ? 0.4 : 0.6) { mood = c } // unprompted moods are noise
        if bars == nil, let s = pick("bars"), let n = Int(s) { bars = n; note("bars") }
        if let s = pick("tempo") { tempo = s }
        func score(_ id: String) -> Double? {
            guard let x = a[id], let s = x.score, (x.confidence ?? 1) > 0.25 else { return nil }
            return s
        }
        if let v = score("laidback") { laidback = v }
        if let v = score("vintage") { vintage = v }
        if let v = score("energy") { energy = v }
        if let v = score("brightness") { brightness = v }
        if let n = a["wants_bass"]?.noul { wantsBass = n }
        if drumStyle == nil { drumStyle = sampleStyle }
        if sampleStyle == nil { sampleStyle = drumStyle }
    }
}
