import Foundation
import AVFoundation
import AudioToolbox

/// CRATE audio engine (BUILD.md §5).
///
/// Graph: 32 × (AVAudioPlayerNode → AVAudioUnitVarispeed) → one mixer per bank → sum mixer →
/// EQ (low-pass) → distortion → delay → reverb → Apple PeakLimiter → master bus (the tap: meters, bounces, debug WAV)
/// → mainMixerNode. The metronome / count-in click player feeds mainMixerNode directly, after the tap, so it is heard
/// but never printed into a bounce.
///
/// Threading: every AVAudioPlayerNode / voice / sequencer mutation happens on `q` (serial, userInteractive).
/// The public API never blocks the caller: mutations hop onto `q`, getters read lock-protected snapshots.
/// Nothing runs on the render thread except Apple's own nodes.
///
/// Usage (lead): `let engine = AudioEngine(); try engine.start()` at launch, then `loadBank` / `setPattern` / `play`.
final class AudioEngine: SamplerEngine, @unchecked Sendable {

    // MARK: Tunables

    /// Voices per bank (A drums, B chops, C bass/keys, D free) = 37. Bank C: mono bass + two 4-note chord stabs overlapping.
    static let voicesPerBank = [16, 6, 10, 5]
    static let lookahead = 0.100
    static let startDelay = 0.060
    /// Per-bank mixer gain (headroom into the FX chain + limiter).
    static let bankGain: Float = 0.8
    /// After the limiter: keeps output peaks below -0.3 dBFS.
    static let masterGain: Float = 0.94
    static let debugRecordSeconds = 120.0
    static let crushBeforeFilter = AppConfig.devEnv("CRATE_FX_ORDER") != "spec"

    // MARK: Graph (built once under graphLock)

    let engine = AVAudioEngine()
    let graphLock = NSLock()
    var engineFormat: AVAudioFormat?
    var graphBuilt = false
    var tapInstalled = false
    var configObserver: NSObjectProtocol?
    var timer: DispatchSourceTimer?

    // Created in init (immutable → safe to read from any thread); attached + connected in start().
    let pools: [[Voice]]               // indexed by Bank.rawValue
    let allVoices: [Voice]
    let bankMixers: [AVAudioMixerNode] // indexed by Bank.rawValue
    var roundRobin = [0, 0, 0, 0]      // q only
    let sumMixer = AVAudioMixerNode()
    /// Bands: 0 low-pass (PUNCH / LP / LOFI / BP), 1 high-pass (HP / BP), 2 low shelf + 3 high shelf (COLOR).
    let eq = AVAudioUnitEQ(numberOfBands: 4)
    let lowPass: AVAudioUnitEQFilterParameters
    let distortion = AVAudioUnitDistortion()
    let delayFX = AVAudioUnitDelay()
    let reverb = AVAudioUnitReverb()
    let limiter: AVAudioUnitEffect
    /// Everything the beat makes, summed at master gain. The master tap sits on its output.
    let masterBus = AVAudioMixerNode()
    /// Metronome + count-in clicks (into mainMixerNode, after the tap). Scheduled on `q` at host times.
    let clickPlayer = AVAudioPlayerNode()
    /// PAD FX character unit (LOFI / CRUSH / RING MOD / RADIO / GRANULAR), first in the chain; bypassed otherwise.
    let fxDist = AVAudioUnitDistortion()

    // MARK: Queues

    let q = DispatchQueue(label: "com.shuhan.crate.audio", qos: .userInteractive)
    let loadQueue = DispatchQueue(label: "com.shuhan.crate.audio.load", qos: .userInitiated, attributes: .concurrent)
    let wavQueue = DispatchQueue(label: "com.shuhan.crate.audio.wav", qos: .utility)

    // MARK: Shared snapshot state (stateLock) — readable from any thread

    struct Shared {
        var padAudio: [PadID: PadAudio] = [:]
        var pattern = Pattern.empty
        var bpm: Double = 90
        var swing: Double = 56
        var playing = false
        var recording = false
        /// Jam hits waiting for KEEP, and the host time of the newest.
        var jamCount = 0
        var jamAt: Double = 0
        var running = false
        var transportGen = 0
        var loadGen = [0, 0, 0, 0]
        var timeline = Timeline()
        var metronome = UserDefaults.standard.bool(forKey: SongPrefs.clickKey)
        var startBar = 0
        /// A SONG cue in flight: the bar it lands on, valid until just after its downbeat (before then the timeline
        /// still counts in the old pattern's numbering).
        var cue: (bar: Int, until: Double)? = nil
    }
    let stateLock = NSLock()
    var shared = Shared()

    // MARK: Sequencer state (q only)

    var playingQ = false
    var anchorStep = 0
    var anchorTime: Double = 0
    var sps: Double = 60.0 / 90.0 / 4.0
    var swingQ: Double = 56
    var nextStep = 0
    var schedBar = 0
    var active = CompiledPattern(.empty)
    var pending: CompiledPattern?
    var fills: [Int: FillDef] = [:]
    var skipOnce = Set<SkipKey>()
    /// Pads played over the loop while REC is off: the last loop's worth, for KEEP (q only).
    var jam: [JamHit] = []
    var timelineQ = Timeline()
    /// Count-in: steps before this one only click (the loop starts here). Also where the transport started.
    var startStepQ = 0
    /// A quantized bar jump waiting for the scheduler: at absolute step `at` the timeline continues from `to`.
    var pendingJump: (at: Int, to: Int)?
    /// A SONG cue (`setPattern(_:fromBar:)`) is waiting at `pendingJump` with its pattern in `pending`: a `.now` swap
    /// before then updates the cued pattern instead of starting it early at the wrong place.
    var cueWaiting = false
    var metronomeQ = UserDefaults.standard.bool(forKey: SongPrefs.clickKey)
    /// Click sounds in the engine format (accent, normal), built when the graph is.
    var clickBuffers: (accent: AVAudioPCMBuffer, normal: AVAudioPCMBuffer)?
    /// Seconds from a host-time schedule to the sound reaching the ear (output latency + one IO buffer).
    /// Live hits are compared against what was *heard*. Refreshed at start / restart (route changes).
    var hearLatencyQ: Double = 0
    /// A count-in is running and its downbeat hasn't been announced (onCountIn(0)) yet.
    var countInPending = false
    /// MUTE: pads the sequencer skips (q only; set with setMuted).
    var mutedQ = Set<PadID>()
    var lastRestartAttempt: Double = 0
    var lastRestartDone: Double = 0

    // MARK: FX state (fxLock)

    let fxLock = NSLock()
    var punchValue: Double = 0
    var breakdown = false
    var muteGen = 0
    var lastPunchLog: Double = 0
    /// PAD FX selection as seen by setPunch (breakdown only applies to the default chain).
    var fxSelected: FXType?

    // MARK: PAD FX engine state (fxQ only, except the q-owned sequencer bits)

    let fxQ = DispatchQueue(label: "com.shuhan.crate.audio.fx", qos: .userInteractive)
    var fxTypeQ: FXType?
    var fxApplied: Double = 0
    var fxRampGen = 0
    /// BEAT REPEAT (q): slice length in steps (0 = off), first remapped step, captured hit step, ratchet.
    var repeatLen = 0
    var repeatFrom = 0
    var repeatHit = 0
    var repeatRatchet = 1
    /// HALF SPEED (q): varispeed multiplier for newly started voices.
    var rateMulQ: Float = 1

    // MARK: Metering (levelLock)

    let levelLock = NSLock()
    var levelBlocks: [Float] = []
    var levelArrival: Double = 0
    var levelBlockDur: Double = 0.01
    var levelSmoothed: Float = 0
    var wavWriter: WavWriter?

    // Optional consumer of the EXISTING master tap (WP13). No second tap is installed.
    private let captureLock = NSLock()
    private var masterCapture: (UUID, (TapBuffer, AVAudioTime) -> Void)?
    func attachMasterCapture(_ handler: @escaping (TapBuffer, AVAudioTime) -> Void) -> UUID? {
        captureLock.withLock {
            guard masterCapture == nil else { return nil }
            let id = UUID()
            masterCapture = (id, handler)
            return id
        }
    }
    func detachMasterCapture(_ id: UUID) {
        captureLock.withLock { if masterCapture?.0 == id { masterCapture = nil } }
    }


    /// Called on main at each bar start with the absolute bar index.
    var onBar: ((Int) -> Void)?
    /// Called on main at each count-in click (beats left, 4…1), then 0 on the downbeat.
    var onCountIn: ((Int) -> Void)?

    init() {
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                             componentSubType: kAudioUnitSubType_PeakLimiter,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        limiter = AVAudioUnitEffect(audioComponentDescription: desc)
        lowPass = eq.bands[0]
        let pools = Bank.allCases.map { bank in (0..<Self.voicesPerBank[bank.rawValue]).map { Voice(bank: bank, slot: $0) } }
        self.pools = pools
        allVoices = pools.flatMap { $0 }
        bankMixers = Bank.allCases.map { _ in AVAudioMixerNode() }
    }

    deinit {
        timer?.cancel()
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Start / graph

    /// Configures the session, builds the graph (once), starts the engine, all 32 players, the tap and the sequencer clock.
    /// Idempotent; safe to call again after an interruption.
    func start() throws {
        graphLock.lock()
        defer { graphLock.unlock() }
        let fmt = formatLocked()
        if !graphBuilt {
            try buildGraphLocked(fmt)
            graphBuilt = true
        }
        let wasRunning = engine.isRunning
        if !wasRunning {
            engine.prepare()
            try engine.start()
            if isRunning { q.async { self.restartOnQ(reason: "start") } }   // restart after a stop: reset voices
        }
        for v in allVoices where !v.player.isPlaying {
            do { try v.player.cratePlay() } catch { DebugLog.event("audio_error", ["where": "player_play", "error": "\(error)"]) }
        }
        if !clickPlayer.isPlaying { try? clickPlayer.cratePlay() }
        let lat = Self.measureHearLatency()
        q.async { self.hearLatencyQ = lat }
        installTapLocked()
        startTimerLocked()
        observeConfigChangesLocked()
        stateLock.withLock { shared.running = true }
        if !wasRunning {
            DebugLog.event("engine_start", ["sr": fmt.sampleRate, "voices": allVoices.count, "silent": AppConfig.silentAudio,
                                            "hw_sr": AppConfig.silentAudio ? 0 : engine.outputNode.outputFormat(forBus: 0).sampleRate,
                                            "hear_ms": (lat * 10000).rounded() / 10])
        }
    }

    /// Engine format: standard float stereo at the hardware output rate (never assume 44.1k).
    func ensureFormat() -> AVAudioFormat {
        graphLock.lock()
        defer { graphLock.unlock() }
        return formatLocked()
    }

    private func formatLocked() -> AVAudioFormat {
        if let f = engineFormat { return f }
        if AppConfig.silentAudio {
            let f = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            do { try engine.enableManualRenderingMode(.offline, format: f, maximumFrameCount: 4096) } catch {
                DebugLog.event("audio_error", ["where": "silent_mode", "error": "\(error)"])
            }
            engineFormat = f
            return f
        }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do { try session.setCategory(.playback, mode: .default, options: []) } catch {
            DebugLog.event("audio_error", ["where": "session_category", "error": "\(error)"])
        }
        do { try session.setPreferredIOBufferDuration(0.005) } catch {
            DebugLog.event("audio_error", ["where": "session_buffer", "error": "\(error)"])
        }
        do { try session.setActive(true) } catch {
            DebugLog.event("audio_error", ["where": "session_active", "error": "\(error)"])
        }
        #endif
        // Hardware output rate first: before start() the main mixer may still report its 44.1k default.
        var sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if !(sr > 0) { sr = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate }
        if !(sr > 0) { sr = 48000 }
        let f = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        engineFormat = f
        return f
    }

    private func buildGraphLocked(_ fmt: AVAudioFormat) throws {
        let main = engine.mainMixerNode
        engine.attach(sumMixer)
        for bank in Bank.allCases {
            let mixer = bankMixers[bank.rawValue]
            engine.attach(mixer)
            for v in pools[bank.rawValue] {
                engine.attach(v.player)
                engine.attach(v.varispeed)
                try engine.crateConnect(v.player, to: v.varispeed, format: fmt)
                try engine.crateConnect(v.varispeed, to: mixer, fromBus: 0, toBus: AVAudioNodeBus(v.slot), format: fmt)
            }
            mixer.outputVolume = Self.bankGain
            try engine.crateConnect(mixer, to: sumMixer, fromBus: 0, toBus: AVAudioNodeBus(bank.rawValue), format: fmt)
        }
        for node in [fxDist, eq, distortion, delayFX, reverb, limiter] as [AVAudioNode] { engine.attach(node) }
        try engine.crateConnect(sumMixer, to: fxDist, format: fmt)
        // Crush before the low-pass: the decimator's aliasing re-adds highs, so after the filter it
        // cancelled the "filter closing" (measured: centroid stayed ~1.3 kHz at a 400 Hz cutoff).
        if Self.crushBeforeFilter {
            try engine.crateConnect(fxDist, to: distortion, format: fmt)
            try engine.crateConnect(distortion, to: eq, format: fmt)
            try engine.crateConnect(eq, to: delayFX, format: fmt)
        } else {
            try engine.crateConnect(fxDist, to: eq, format: fmt)
            try engine.crateConnect(eq, to: distortion, format: fmt)
            try engine.crateConnect(distortion, to: delayFX, format: fmt)
        }
        try engine.crateConnect(delayFX, to: reverb, format: fmt)
        try engine.crateConnect(reverb, to: limiter, format: fmt)
        engine.attach(masterBus)
        try engine.crateConnect(limiter, to: masterBus, format: fmt)
        try engine.crateConnect(masterBus, to: main, format: fmt)
        masterBus.outputVolume = Self.masterGain
        main.outputVolume = 1
        engine.attach(clickPlayer)
        try engine.crateConnect(clickPlayer, to: main, format: fmt)
        clickBuffers = Self.makeClicks(fmt)
        configureFX(sampleRate: fmt.sampleRate)
    }

    private func configureFX(sampleRate: Double) {
        let lp = lowPass
        lp.filterType = .lowPass
        lp.frequency = maxCutoff
        lp.bandwidth = 0.5
        lp.gain = 0
        lp.bypass = false
        // HP stays engaged at 10 Hz (inaudible) so HP / BP FILTER can sweep it without bypass clicks.
        let hp = eq.bands[1]
        hp.filterType = .highPass
        hp.frequency = 10
        hp.bypass = false
        let ls = eq.bands[2]
        ls.filterType = .lowShelf
        ls.frequency = 250
        ls.gain = 0
        ls.bypass = false
        let hs = eq.bands[3]
        hs.filterType = .highShelf
        hs.frequency = 3500
        hs.gain = 0
        hs.bypass = false
        fxDist.loadFactoryPreset(.multiDecimated4)
        fxDist.wetDryMix = 0
        fxDist.bypass = true
        eq.globalGain = 0
        distortion.loadFactoryPreset(.multiDecimated2)
        distortion.wetDryMix = 0
        delayFX.delayTime = min(2, 3 * sps)
        delayFX.feedback = 35
        delayFX.lowPassCutoff = 9000
        delayFX.wetDryMix = 0
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 0
    }

    var maxCutoff: Float {
        let sr = engineFormat?.sampleRate ?? 48000
        return Float(min(20000, 0.45 * sr))
    }

    private func startTimerLocked() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: q)
        t.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func observeConfigChangesLocked() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            self.q.async { self.handleConfigChange() }
        }
    }

    /// The engine stops itself on a configuration change (route / sample-rate change).
    func handleConfigChange() { _ = restartOnQ(reason: "config_change") }

    /// q only. (Re)start a stopped engine and reset every voice (their schedules died with the engine),
    /// then re-anchor the sequencer. Also used after interruptions: tick() and live triggers self-heal.
    @discardableResult
    func restartOnQ(reason: String) -> Bool {
        let now = Clock.now()
        lastRestartAttempt = now
        graphLock.lock()
        var ok = engine.isRunning
        if ok && now - lastRestartDone < 1.0 { graphLock.unlock(); return true }   // already healed (tick beat the notification)
        if !ok && graphBuilt {
            #if os(iOS)
            if !AppConfig.silentAudio { try? AVAudioSession.sharedInstance().setActive(true) }
            #endif
            engine.prepare()
            do { try engine.start(); ok = true } catch {
                DebugLog.event("audio_error", ["where": "restart", "reason": reason, "error": "\(error)"])
            }
        }
        graphLock.unlock()
        guard ok else { return false }
        for v in allVoices {
            v.token &+= 1
            v.player.stop()
            try? v.player.cratePlay()
            v.busyUntil = 0; v.pad = nil; v.live = false; v.fading = false
        }
        clickPlayer.stop()
        try? clickPlayer.cratePlay()
        hearLatencyQ = Self.measureHearLatency()
        if playingQ { reanchor(step: nextStep, time: Clock.now() + Self.startDelay, keepPrev: false) }
        lastRestartDone = Clock.now()
        DebugLog.event("engine_restart", ["reason": reason,
                                          "hw_sr": AppConfig.silentAudio ? 0 : engine.outputNode.outputFormat(forBus: 0).sampleRate])
        return true
    }

    var isRunning: Bool { stateLock.withLock { shared.running } }

    // MARK: - Banks

    /// Decodes on a background queue (never the caller's thread), then swaps the whole bank in atomically.
    /// Files that fail to load are skipped + logged (`load_error`); it never throws for bad files.
    /// Overlapping loads of the same bank: the most recent request wins (an older one finishing later is dropped).
    func loadBank(_ bank: Bank, sounds: [Int: PadSound]) async throws {
        let t0 = Clock.now()
        let gen: Int = stateLock.withLock { shared.loadGen[bank.rawValue] += 1; return shared.loadGen[bank.rawValue] }
        let loaded: [Int: PadAudio] = await withCheckedContinuation { cont in
            loadQueue.async {
                let fmt = self.ensureFormat()
                cont.resume(returning: Loader.load(sounds, format: fmt))
            }
        }
        let current: Bool = stateLock.withLock {
            guard shared.loadGen[bank.rawValue] == gen else { return false }
            shared.padAudio = shared.padAudio.filter { $0.key.bank != bank }
            for (i, pa) in loaded { shared.padAudio[PadID(bank, i)] = pa }
            return true
        }
        DebugLog.event("load_bank", ["bank": bank.letter, "count": loaded.count, "requested": sounds.count,
                                     "ms": Int(((Clock.now() - t0) * 1000).rounded()), "superseded": !current])
    }

    func sound(for pad: PadID) -> PadSound? { stateLock.withLock { shared.padAudio[pad]?.sound } }

    func audio(for pad: PadID) -> PadAudio? { stateLock.withLock { shared.padAudio[pad] } }

    // MARK: - Live

    func trigger(_ pad: PadID, velocity: Int, semitones: Double) {
        // The finger's own timestamp when this came from a touch (it lands ~10–30 ms before this call).
        let now = Clock.now()
        let t = TouchClock.recent(now: now) ?? now
        q.async { self.liveTrigger(pad, velocity: velocity, semitones: semitones, tapTime: t, record: true) }
    }

    func release(_ pad: PadID) {
        q.async { self.liveRelease(pad) }
    }

    // MARK: - Pattern / transport

    /// Returns the most recently set pattern (the pending one if a `.nextBar` swap hasn't happened yet),
    /// including overdubbed hits. Cheap: lock + copy.
    var pattern: Pattern { stateLock.withLock { shared.pattern } }

    func setPattern(_ p: Pattern, timing: ApplyTiming) {
        stateLock.withLock { shared.pattern = p }
        q.async { self.applyPattern(p, timing: timing) }
    }

    func play() {
        stateLock.withLock { shared.playing = true }
        q.async { self.startTransport() }
    }

    func stop() {
        stateLock.withLock {
            shared.playing = false
            shared.timeline.playing = false
            shared.transportGen += 1
        }
        q.async { self.stopTransport() }
    }

    var isPlaying: Bool { stateLock.withLock { shared.playing } }

    var bpm: Double {
        get { stateLock.withLock { shared.bpm } }
        set {
            guard newValue.isFinite else { return }
            let v = min(300, max(30, newValue))
            stateLock.withLock { shared.bpm = v }
            q.async { self.applyBpm(v) }
        }
    }

    /// MPC swing percent (50 = straight). The engine's swing is authoritative; `Pattern.swing` is not applied.
    var swing: Double {
        get { stateLock.withLock { shared.swing } }
        set {
            guard newValue.isFinite else { return }
            let v = min(75, max(50, newValue))
            stateLock.withLock { shared.swing = v }
            q.async { self.swingQ = v }
        }
    }

    func position() -> Double {
        let tl = stateLock.withLock { shared.timeline }
        return tl.position(at: Clock.now())
    }

    /// Applied to bank-A lanes when `bar` is scheduled. If scheduling already entered that bar
    /// (queued < ~150 ms before it), the fill still applies to the bar's remaining steps.
    func queueFill(_ fill: FillDef, atBar bar: Int) {
        q.async {
            self.fills[bar] = fill
            if self.playingQ && bar <= self.schedBar {
                DebugLog.event("fill", ["bar": bar, "id": fill.id, "late": true])
            }
        }
    }

    func setRecording(_ on: Bool) {
        stateLock.withLock { shared.recording = on }
    }

    // MARK: - Hinge FX

    func setPunch(_ amount: Double) {
        let p = amount.isFinite ? min(1, max(0, amount)) : 0
        let now = Clock.now()
        var muteChange: Bool? = nil
        var log = false
        fxLock.lock()
        punchValue = p
        let typed = fxSelected != nil
        if !typed && !breakdown && p > 0.92 { breakdown = true; muteChange = true; muteGen += 1 }
        else if breakdown && (p < 0.88 || typed) { breakdown = false; muteChange = false; muteGen += 1 }
        let gen = muteGen
        if now - lastPunchLog >= 0.1 || muteChange != nil { lastPunchLog = now; log = true }
        fxLock.unlock()

        fxQ.async { self.rampFX(to: p) }
        if let m = muteChange { rampBreakdown(muted: m, gen: gen) }
        if log {
            var f: [String: Any] = ["p": (p * 1000).rounded() / 1000]
            if let m = muteChange { f["breakdown"] = m }
            DebugLog.event("punch", f)
        }
    }

    func drop() {
        fxLock.withLock {
            punchValue = 0
            breakdown = false
            muteGen += 1
        }
        fxQ.async { self.rampFX(to: 0, over: 0.01) }
        eq.globalGain = 0
        bankMixers[Bank.a.rawValue].outputVolume = Self.bankGain
        bankMixers[Bank.c.rawValue].outputVolume = Self.bankGain
        let t = Clock.now()
        q.async {
            self.liveTrigger(BankA.pad(forLane: "cymbal") ?? PadID(.a, 11), velocity: 118, semitones: 0, tapTime: t, record: false)
            self.liveTrigger(BankA.pad(forLane: "kick") ?? PadID(.a, 0), velocity: 124, semitones: 0, tapTime: t, record: false)
        }
        DebugLog.event("drop")
    }

    /// cutoff = 20k·(180/20k)^(p^0.85); crush wet 30·p²; delay wet 22·p; reverb wet 38·p.
    func applyFX(_ p: Double) {
        let cutoff = 20000 * pow(180.0 / 20000.0, pow(p, 0.85))
        lowPass.frequency = min(maxCutoff, Float(cutoff))
        distortion.wetDryMix = Float(30 * p * p)
        delayFX.wetDryMix = Float(22 * p)
        reverb.wetDryMix = Float(38 * p)
    }

    /// Breakdown: banks A + C fade out over ~20 ms (bank B chops ring through the FX) with a little makeup
    /// gain so the filtered chops stay audible; reverse on exit.
    func rampBreakdown(muted: Bool, gen: Int) {
        let targets = [bankMixers[Bank.a.rawValue], bankMixers[Bank.c.rawValue]]
        let from = targets[0].outputVolume
        let to: Float = muted ? 0 : Self.bankGain
        let gainFrom = eq.globalGain
        let gainTo: Float = muted ? Self.breakdownMakeupDB : 0
        let steps = 5
        for i in 1...steps {
            q.asyncAfter(deadline: .now() + 0.004 * Double(i)) { [weak self] in
                guard let self = self, self.fxLock.withLock({ self.muteGen }) == gen else { return }
                let k = Float(i) / Float(steps)
                let v = from + (to - from) * k
                for m in targets { m.outputVolume = v }
                self.eq.globalGain = gainFrom + (gainTo - gainFrom) * k
            }
        }
    }

    static let breakdownMakeupDB: Float = 9

    // MARK: - Metering / display

    /// Master level for meters, 0...1: RMS of the master output mapped from -48...0 dBFS, smoothed
    /// (fast attack, slower release). The ~100 ms tap blocks are replayed in 10 ms slices so it moves smoothly.
    func level() -> Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        var raw: Float = 0
        let age = Clock.now() - levelArrival
        if !levelBlocks.isEmpty && age < 0.3 {   // stale (engine stopped) → 0
            let idx = Int(age / levelBlockDur)
            raw = levelBlocks[max(0, min(levelBlocks.count - 1, idx))]
        }
        let db = 20 * log10(max(Double(raw), 1e-6))
        let target = Float(max(0, min(1, (db + 48) / 48)))
        let k: Float = target > levelSmoothed ? 0.6 : 0.12
        levelSmoothed += (target - levelSmoothed) * k
        return levelSmoothed
    }

    func waveform(_ pad: PadID, points: Int) -> [Float] {
        guard points > 0 else { return [] }
        guard let pa = audio(for: pad) else { return [Float](repeating: 0, count: points) }
        return pa.waveform(points: points)
    }

    private func installTapLocked() {
        guard !tapInstalled else { return }
        let main = masterBus   // before the click player joins: bounces and meters never hear the metronome
        let outFmt = main.outputFormat(forBus: 0)
        if AppConfig.debugRecord, wavWriter == nil {
            let url: URL
            if let p = AppConfig.devEnv("CRATE_DEBUG_WAV") {
                url = URL(fileURLWithPath: p)
            } else {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSTemporaryDirectory())
                url = docs.appendingPathComponent("crate-debug.wav")
            }
            wavWriter = WavWriter(url: url, sampleRate: outFmt.sampleRate, maxSeconds: Self.debugRecordSeconds)
            DebugLog.event("debug_record", ["path": url.path, "sr": outFmt.sampleRate, "ok": wavWriter != nil])
        }
        do {
            try main.crateInstallTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, time in
                self?.handleTap(buf)
                let capture = self?.captureLock.withLock { self?.masterCapture?.1 }
                capture?(buf, time)
            }
            tapInstalled = true
        } catch {
            DebugLog.event("audio_error", ["where": "tap", "error": "\(error)"])
        }
    }

    /// Tap thread (not the render thread): RMS per 10 ms block for level(), optional debug WAV.
    private func handleTap(_ buf: TapBuffer) {
        let n = buf.frameLength
        let fmt = buf.format
        guard n > 0, fmt.commonFormat == .pcmFormatFloat32 else { return }
        let sr = fmt.sampleRate
        let ch = Int(fmt.channelCount)
        let blockLen = max(64, Int(sr * 0.010))
        let writer = wavWriter
        let wantPCM = (writer != nil && !(writer?.isFull ?? true))
        var pcm = [Int16](repeating: 0, count: wantPCM ? n * 2 : 0)
        var blocks: [Float] = []
        blocks.reserveCapacity(n / blockLen + 1)
        buf.withUnsafeAudioBufferList { ablPtr in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: ablPtr))
            guard abl.count > 0, let d0 = abl[0].mData else { return }
            let left: UnsafePointer<Float>
            let right: UnsafePointer<Float>
            let stride: Int
            if fmt.isInterleaved {
                let p = UnsafePointer(d0.assumingMemoryBound(to: Float.self))
                left = p; right = ch > 1 ? p + 1 : p; stride = max(1, ch)
            } else {
                left = UnsafePointer(d0.assumingMemoryBound(to: Float.self))
                if abl.count > 1, let d1 = abl[1].mData { right = UnsafePointer(d1.assumingMemoryBound(to: Float.self)) } else { right = left }
                stride = 1
            }
            var sum: Float = 0
            var count = 0
            for i in 0..<n {
                let l = left[i * stride], r = right[i * stride]
                sum += l * l + r * r
                count += 1
                if count == blockLen {
                    blocks.append((sum / Float(2 * count)).squareRoot())
                    sum = 0; count = 0
                }
                if wantPCM {
                    pcm[2 * i] = Int16(max(-1, min(1, l)) * 32767)
                    pcm[2 * i + 1] = Int16(max(-1, min(1, r)) * 32767)
                }
            }
            if count > blockLen / 2 { blocks.append((sum / Float(2 * count)).squareRoot()) }
        }
        let arrival = Clock.now()
        levelLock.withLock {
            levelBlocks = blocks
            levelArrival = arrival
            levelBlockDur = Double(blockLen) / sr
        }
        if wantPCM {
            wavQueue.async {
                writer?.append(pcm)
            }
        }
    }
}
