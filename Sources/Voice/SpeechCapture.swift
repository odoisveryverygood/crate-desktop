import AVFoundation
import Foundation
import Speech

/// On-device speech for hold-to-talk. iOS 26 SpeechAnalyzer + SpeechTranscriber (streaming, volatile results),
/// falling back to SFSpeechRecognizer (on-device when the device supports it). The microphone runs only while a
/// pad / bank is held: its own small AVAudioEngine (input only), so the performance engine is never touched.
@MainActor
final class SpeechService {
    static let shared = SpeechService()

    /// Seeded as contextual strings so the recognizer prefers producer words over sound-alikes.
    static let musicWords = [
        "snare", "kick", "hats", "hi-hat", "open hat", "clap", "rim", "rimshot", "shaker", "tambourine", "conga",
        "bongo", "808", "sub", "bass", "boom bap", "Dilla", "J Dilla", "Nujabes", "Madlib", "lofi", "lo-fi",
        "trap", "drill", "house", "jazz hop", "R&B", "Rhodes", "Wurlitzer", "piano", "keys", "synth", "pad",
        "strings", "horns", "flute", "guitar", "vocal", "choir", "chop", "chops", "sample", "vinyl", "dusty",
        "crunchy", "rusty", "punchy", "crispy", "warm", "bank", "MPC", "SP-404", "swing", "reverb", "tape",
    ]

    enum Backend: String { case analyzer, legacy, unavailable }

    /// Which recognizer the next hold uses (decided by `prepare()`).
    private(set) var backend: Backend = SpeechTranscriber.isAvailable ? .analyzer : .legacy
    /// Mic level 0…1 while capturing (for the pad line meter).
    private(set) var level: Double = 0

    private var locale = Locale(identifier: "en-US")
    /// The analyzer's audio format (16 kHz mono unless the model asks for something else).
    private var analyzerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1,
                                               interleaved: true)!
    /// A transcriber + analyzer already prepared for the next hold (each analyzer serves one utterance).
    private var ready: AnalyzerRun?
    private var preparing: Task<Void, Never>?
    private var run: (any SpeechRun)?
    private let mic = MicStream()
    private let session = SpeechSession()
    /// Session switches and mic start / stop run here, in order, never on main.
    private let audioQ = DispatchQueue(label: "crate.speech.audio", qos: .userInitiated)

    // MARK: Prepare (launch)

    /// Picks the locale, installs the on-device model if needed and prepares the first analyzer, so the first hold
    /// starts transcribing at once. Safe to call more than once.
    func prepare() {
        guard preparing == nil, ready == nil else { return }
        preparing = Task { @MainActor in
            defer { preparing = nil }
            guard SpeechTranscriber.isAvailable else {
                backend = .legacy
                DebugLog.event("speech_prepare", ["backend": "legacy", "why": "transcriber unavailable"])
                return
            }
            let t0 = Date()
            locale = await Self.pickLocale()
            do {
                let next = AnalyzerRun(locale: locale)
                if let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [next.transcriber]) {
                    analyzerFormat = best
                }
                try await next.install()
                try await next.prepare(format: analyzerFormat)
                ready = next
                backend = .analyzer
                DebugLog.event("speech_prepare", ["backend": "analyzer", "locale": locale.identifier,
                                                  "sr": analyzerFormat.sampleRate,
                                                  "ms": Int(Date().timeIntervalSince(t0) * 1000)])
            } catch {
                backend = .legacy
                DebugLog.event("speech_prepare", ["backend": "legacy", "error": "\(error)"])
            }
        }
    }

    /// The first English locale the user reads (prompts and the AI are English), else the device locale.
    private static func pickLocale() async -> Locale {
        let preferred = Locale.preferredLanguages.map(Locale.init(identifier:))
        let english = preferred.first { $0.language.languageCode?.identifier == "en" }
        for candidate in [english, Locale.current, Locale(identifier: "en-US")].compactMap({ $0 }) {
            if let l = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) { return l }
        }
        return Locale(identifier: "en-US")
    }

    // MARK: Capture

    enum StartError: Error { case micDenied, micUndetermined, noInput, recognizerUnavailable, speechDenied, speechUndetermined }

    /// Starts the recognizer now and the mic right after, OFF the main thread: switching the session to
    /// play-and-record and starting an input engine takes 100-500 ms on a phone, and doing it on main froze the
    /// pull-to-talk panel mid-drag (it then jumped open at the threshold). `onText` gets the running transcript
    /// (volatile included); `onFail` is called if the mic cannot start after all.
    func start(onText: @escaping @MainActor (String) -> Void,
               onFail: @escaping @MainActor (StartError) -> Void = { _ in }) throws {
        cancel()
        switch CrateMicrophone.permission {
        case .granted: break
        case .denied: throw StartError.micDenied
        default:
            Task { _ = await CrateMicrophone.requestPermission() }
            throw StartError.micUndetermined
        }
        let r: any SpeechRun
        var format: AVAudioFormat?
        if backend == .analyzer {
            let a = ready ?? AnalyzerRun(locale: locale)
            let wasReady = ready != nil
            ready = nil
            format = analyzerFormat
            if !wasReady {
                let fmt = analyzerFormat
                a.preparing = Task { try await a.install(); try await a.prepare(format: fmt) }
            }
            r = a
        } else {
            switch SFSpeechRecognizer.authorizationStatus() {
            case .denied, .restricted: throw StartError.speechDenied
            case .notDetermined:
                SFSpeechRecognizer.requestAuthorization { _ in }
                throw StartError.speechUndetermined
            default: break
            }
            guard let l = LegacyRun(locale: locale) else { throw StartError.recognizerUnavailable }
            r = l
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        }
        run = r
        r.begin(onText: onText)
        let mic = self.mic, session = self.session, backendName = backend.rawValue
        let t0 = Date()
        audioQ.async { [weak r] in
            var failure: StartError?
            do {
                try session.enter()
                do {
                    try mic.start(format: format) { [weak r] buffer, rms in
                        r?.append(buffer)
                        Task { @MainActor in SpeechService.shared.level = rms }
                    }
                } catch {
                    session.restore()
                    failure = .noInput
                }
            } catch {
                failure = .noInput
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            Task { @MainActor in
                guard let r, SpeechService.shared.run === r else { return }
                if let failure {
                    DebugLog.event("speech_error", ["where": "mic_start", "ms": ms])
                    SpeechService.shared.cancel()
                    onFail(failure)
                } else {
                    DebugLog.event("speech_start", ["backend": backendName, "ms": ms])
                }
            }
        }
    }

    /// Stops the mic and returns the final transcript, or the latest volatile one if the final takes longer than
    /// `timeout` seconds. Then prepares the next analyzer in the background.
    func finish(timeout: Double = 0.3) async -> String {
        guard let r = run else { return "" }
        run = nil
        stopMic()
        let t0 = Date()
        let text = await r.finish(timeout: timeout)
        DebugLog.event("speech_finish", ["chars": text.count, "ms": Int(Date().timeIntervalSince(t0) * 1000)])
        if backend == .analyzer { prepare() }
        return text
    }

    func cancel() {
        guard let r = run else { return }
        run = nil
        stopMic()
        r.cancel()
    }

    /// Mic off and the session back to playback, on the audio queue (after any start still in flight).
    private func stopMic() {
        level = 0
        let mic = self.mic, session = self.session
        audioQ.async {
            mic.stop()
            session.restore()
        }
    }
}

/// The session switch for speech (same as the SAMPLE recorder): play-and-record, speaker output, mixing while
/// listening; restored after. Used only on `SpeechService.audioQ`.
final class SpeechSession: @unchecked Sendable {
    #if os(iOS)
    private var saved: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

    func enter() throws {
        let s = AVAudioSession.sharedInstance()
        if saved == nil { saved = (s.category, s.mode, s.categoryOptions) }
        if s.category != .playAndRecord {
            try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothA2DP])
        }
        try s.setActive(true)
    }

    func restore() {
        guard let saved else { return }
        self.saved = nil
        do { try AVAudioSession.sharedInstance().setCategory(saved.0, mode: saved.1, options: saved.2) } catch {
            let e = "\(error)"
            Task { @MainActor in DebugLog.event("audio_error", ["where": "speech_restore", "error": e]) }
        }
    }
    #else
    func enter() throws {}
    func restore() {}
    #endif
}

// MARK: - Runs

/// One utterance on one recognizer.
@MainActor
protocol SpeechRun: AnyObject {
    func begin(onText: @escaping @MainActor (String) -> Void)
    /// Called on the mic's tap thread.
    nonisolated func append(_ buffer: AVAudioPCMBuffer)
    func finish(timeout: Double) async -> String
    func cancel()
}

/// iOS 26 SpeechAnalyzer + SpeechTranscriber with volatile (live) results.
@MainActor
final class AnalyzerRun: SpeechRun {
    let transcriber: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    private let stream: AsyncStream<AnalyzerInput>
    private nonisolated let input: AsyncStream<AnalyzerInput>.Continuation
    /// Set when the hold started before this analyzer was prepared (audio queues in the stream meanwhile).
    var preparing: Task<Void, Error>?
    private var resultsTask: Task<Void, Never>?
    private var finalText = ""
    private var volatileText = ""
    private var done = false

    init(locale: Locale) {
        transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                        attributeOptions: [])
        analyzer = SpeechAnalyzer(modules: [transcriber],
                                  options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
    }

    /// Downloads the on-device model the first time (a system asset shared with other apps).
    func install() async throws {
        if await AssetInventory.status(forModules: [transcriber]) == .installed { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    func prepare(format: AVAudioFormat) async throws {
        let context = AnalysisContext()
        context.contextualStrings[.general] = SpeechService.musicWords
        try? await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: format)
    }

    private var current: String {
        (finalText + " " + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func begin(onText: @escaping @MainActor (String) -> Void) {
        let transcriber = transcriber
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await r in transcriber.results {
                    guard let self else { return }
                    let t = String(r.text.characters)
                    if r.isFinal { self.finalText += t; self.volatileText = "" } else { self.volatileText = t }
                    onText(self.current)
                }
            } catch {
                DebugLog.event("speech_error", ["where": "results", "error": "\(error)"])
            }
            self?.done = true
        }
        let analyzer = analyzer, stream = stream, prep = preparing
        Task {
            do {
                try await prep?.value
                try await analyzer.start(inputSequence: stream)
            } catch {
                DebugLog.event("speech_error", ["where": "analyzer_start", "error": "\(error)"])
                await MainActor.run { [weak self] in self?.done = true }
            }
        }
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        input.yield(AnalyzerInput(buffer: buffer))
    }

    func finish(timeout: Double) async -> String {
        input.finish()
        let analyzer = analyzer
        Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        let deadline = Date().addingTimeInterval(timeout)
        while !done, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        if !done { Task { await analyzer.cancelAndFinishNow() } }
        DebugLog.event("speech_final", ["final": done, "text": current])
        return current
    }

    func cancel() {
        input.finish()
        resultsTask?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}

/// Fallback: SFSpeechRecognizer, on-device when supported, partial results on.
@MainActor
final class LegacyRun: SpeechRun {
    private let recognizer: SFSpeechRecognizer
    private nonisolated(unsafe) let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var done = false

    init?(locale: Locale) {
        // On-device only: speech never goes to a server (that's what the usage string promises).
        guard let r = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), r.isAvailable,
              r.supportsOnDeviceRecognition else { return nil }
        recognizer = r
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = SpeechService.musicWords
        request.taskHint = .dictation
    }

    func begin(onText: @escaping @MainActor (String) -> Void) {
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self else { return }
                if let text { self.latest = text; onText(text) }
                if final || error != nil { self.done = true }
            }
        }
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }

    func finish(timeout: Double) async -> String {
        request.endAudio()
        let deadline = Date().addingTimeInterval(timeout)
        while !done, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        if !done { task?.cancel() }
        return latest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        request.endAudio()
        task?.cancel()
    }
}

// MARK: - Microphone

/// Input-only AVAudioEngine (a fresh one per hold, so a route change never leaves a stale format), converting the
/// mic to the recognizer's format on the tap thread.
final class MicStream: @unchecked Sendable {
    private var engine: AVAudioEngine?

    func start(format target: AVAudioFormat?, onBuffer: @escaping (AVAudioPCMBuffer, Double) -> Void) throws {
        stop()
        let e = AVAudioEngine()
        let node = e.inputNode
        let inFmt = node.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else { throw SpeechService.StartError.noInput }
        let outFmt = target ?? inFmt
        let converter = outFmt == inFmt ? nil : AVAudioConverter(from: inFmt, to: outFmt)
        try node.crateInstallTap(onBus: 0, bufferSize: 1024, format: inFmt) { tap, _ in
            guard let pcm = Self.copy(tap) else { return }
            let rms = Self.rms(pcm)
            if let converter {
                guard let out = Self.convert(pcm, with: converter, to: outFmt) else { return }
                onBuffer(out, rms)
            } else {
                onBuffer(pcm, rms)
            }
        }
        e.prepare()
        try e.start()
        engine = e
    }

    func stop() {
        guard let e = engine else { return }
        engine = nil
        e.inputNode.removeTap(onBus: 0)
        e.stop()
    }

    private static func copy(_ tap: TapBuffer) -> AVAudioPCMBuffer? {
        guard tap.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: tap.format, frameCapacity: AVAudioFrameCount(tap.frameLength))
        else { return nil }
        out.frameLength = AVAudioFrameCount(tap.frameLength)
        tap.withUnsafeAudioBufferList { src in
            let s = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: src))
            let d = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
            for i in 0..<min(s.count, d.count) {
                guard let from = s[i].mData, let to = d[i].mData else { continue }
                memcpy(to, from, Int(min(s[i].mDataByteSize, d[i].mDataByteSize)))
            }
        }
        return out
    }

    private static func convert(_ pcm: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / pcm.format.sampleRate
        let cap = AVAudioFrameCount(Double(pcm.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return pcm
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    /// 0…1 meter value (−50…0 dBFS) from the first channel.
    private static func rms(_ pcm: AVAudioPCMBuffer) -> Double {
        guard let d = pcm.floatChannelData?[0], pcm.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(pcm.frameLength) { sum += d[i] * d[i] }
        let r = (sum / Float(pcm.frameLength)).squareRoot()
        let db = 20 * log10(max(Double(r), 1e-5))
        return min(1, max(0, (db + 50) / 50))
    }
}
