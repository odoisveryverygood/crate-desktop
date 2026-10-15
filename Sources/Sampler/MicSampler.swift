import Foundation
import Observation
import AVFoundation

/// Own once beside AppState; UI and recorder lifecycle are serialized on the main actor.
@MainActor
@Observable
final class MicSampler: NSObject, AVAudioRecorderDelegate {
    private(set) var isRecording = false
    private(set) var isPreparing = false
    private(set) var isProcessing = false
    private(set) var level: Double = 0
    private(set) var seconds: Double = 0
    private(set) var errorMessage: String?
    private(set) var lastRecordingURL: URL?
    var chopType: SampleChopType = .threshold

    @ObservationIgnored private let state: AppState
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sessionChanged = false
    /// Hold-a-pad take: the lift places it, even after the 120 s cap has stopped the recorder.
    @ObservationIgnored private var intoPad = false

    init(state: AppState) {
        self.state = state
        super.init()
        #if os(iOS)
        let inactive: Notification.Name
        if #available(iOS 27.0, *) {
            inactive = AVAudioSession.didBecomeInactiveNotification
        } else {
            inactive = AVAudioSession.interruptionNotification   // iOS 26
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: inactive, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording || self.isPreparing else { return }
                self.cancelRecording()
                self.fail("Recording was interrupted. Hold the pad to try again.")
            }
        }
        #endif
    }

    deinit {
        recorder?.stop()
        #if os(iOS)
        if sessionChanged {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        #endif
        meterTask?.cancel()
        permissionTask?.cancel()
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    func startRecording(intoPad: Bool = false) {
        guard !isPreparing, !isRecording, !isProcessing else { return }
        self.intoPad = intoPad
        errorMessage = nil
        seconds = 0
        level = 0
        generation += 1
        let request = generation
        isPreparing = true
        permissionTask = Task { [weak self] in
            let allowed = await CrateMicrophone.requestPermission()
            guard let self, !Task.isCancelled, self.generation == request else { return }
            self.isPreparing = false
            guard allowed else {
                self.errorMessage = "Microphone access is off. Turn it on for CRATE in Settings."
                VoiceDig.shared.show(VoiceDig.micOff, settings: true)   // tap the line → Settings
                return
            }
            self.beginTake()
        }
    }

    private func beginTake() {
        do {
            let directory = CrateStorage.documents.appendingPathComponent("samples", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = Int64(Date().timeIntervalSince1970 * 1000)
            let url = directory.appendingPathComponent("rec-\(stamp)-\(UUID().uuidString.prefix(8)).wav")
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            // Restore even if setActive or recorder preparation fails after category changes.
            sessionChanged = true
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
            try session.setActive(true)
            #endif
            let take = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ])
            take.delegate = self
            take.isMeteringEnabled = true
            recorder = take
            guard take.prepareToRecord(), take.record(forDuration: 120) else {
                throw SampleChopError.unreadableAudio
            }
            lastRecordingURL = url
            isRecording = true
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(33))
                    guard !Task.isCancelled, let self, self.isRecording, let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    let db = Double(recorder.averagePower(forChannel: 0))
                    self.level = db.isFinite ? min(1, max(0, pow(10, db / 20))) : 0
                    self.seconds = max(self.seconds, recorder.currentTime)
                }
            }
        } catch {
            recorder?.stop()
            recorder = nil
            restorePlayback()
            fail("Couldn't start microphone recording: \(error.localizedDescription)")
        }
    }

    func stopRecording(chop: SampleChopType) async {
        // Invalidate an outstanding permission request so release can never start a late take.
        generation += 1
        permissionTask?.cancel()
        permissionTask = nil
        isPreparing = false
        guard isRecording, let take = recorder else { return }
        isRecording = false
        isProcessing = true
        meterTask?.cancel()
        meterTask = nil
        seconds = max(seconds, take.currentTime)
        take.stop()
        recorder = nil
        level = 0
        restorePlayback()
        defer { isProcessing = false }
        do {
            let url = take.url
            let analysis = try await Task.detached(priority: .userInitiated) {
                try SampleChopper.analyze(url: url, chop: chop)
            }.value
            DebugLog.event("sample_rec", ["sec": analysis.duration])
            var sounds: [Int: PadSound] = [:]
            for (index, slice) in analysis.slices.enumerated() {
                sounds[index] = PadSound(id: "\(url.lastPathComponent)-\(index)",
                    name: String(format: "REC %02d", index + 1), category: .chop,
                    fileURL: url, start: slice.start, end: slice.end, rootNote: 60,
                    source: "MIC")
            }
            try await state.engine.loadBank(.d, sounds: sounds)
            guard SampleBankCommit.publish(sounds, to: state) else {
                fail("The engine couldn't load all chops, or a newer bank D load replaced them. The recorded WAV is saved; no successful chop is reported.")
                return
            }
            seconds = analysis.duration
            state.addLog("SAMPLE", String(format: "%d chops · %.1f s", sounds.count, analysis.duration), tint: .grey)
            DebugLog.event("sample_chop", ["slices": sounds.count])
        } catch {
            fail("Couldn't chop the take: \(error.localizedDescription)")
        }
    }

    @ObservationIgnored private var takeNumber = 0

    enum TakeResult { case placed, tooShort, failed }

    /// Anything shorter is a tap, not a take: nothing is replaced and SAMPLE stays armed.
    static let minTake = 0.2

    /// SAMPLE + hold a pad: the take goes onto that one pad, silence trimmed, as one UNDO step. Nothing else changes.
    func stopRecording(intoPad pad: PadID) async -> TakeResult {
        generation += 1
        permissionTask?.cancel()
        permissionTask = nil
        isPreparing = false
        guard isRecording, let take = recorder else {
            if errorMessage != nil { return .failed }   // the mic never started; fail() already said why
            state.addLog("SAMPLE", "too short · hold the pad while you record", tint: .grey)
            return .tooShort
        }
        isRecording = false
        meterTask?.cancel()
        meterTask = nil
        seconds = max(seconds, take.currentTime)
        take.stop()
        recorder = nil
        level = 0
        restorePlayback()
        guard seconds >= Self.minTake else {
            try? FileManager.default.removeItem(at: take.url)
            state.addLog("SAMPLE", "too short · hold the pad while you record", tint: .grey)
            return .tooShort
        }
        return await placeTake(take.url, on: pad) ? .placed : .failed
    }

    /// Trims a recorded WAV and puts it on `pad`. Also `crate://take?pad=A3&path=…`, which tests this on a simulator
    /// without a working microphone.
    func placeTake(_ url: URL, on pad: PadID) async -> Bool {
        isProcessing = true
        defer { isProcessing = false }
        do {
            let cut = try await Task.detached(priority: .userInitiated) { try SampleChopper.trim(url: url) }.value
            takeNumber += 1
            let sound = PadSound(id: "take-\(url.lastPathComponent)", name: "TAKE \(takeNumber)", category: .chop,
                                 fileURL: url, start: cut.start, end: cut.end < cut.duration - 0.0005 ? cut.end : nil,
                                 rootNote: 60, source: "MIC")
            Orchestrator.current?.checkpoint("take on \(pad.bank.letter)\(pad.number)")
            var bank: [Int: PadSound] = [:]
            for i in 0..<16 { if let s = state.sound(PadID(pad.bank, i)) { bank[i] = s } }
            bank[pad.index] = sound
            try await state.engine.loadBank(pad.bank, sounds: bank)
            guard state.engine.sound(for: pad)?.id == sound.id else { throw SampleChopError.unreadableAudio }
            for (i, s) in bank { state.sounds[PadID(pad.bank, i)] = s }
            state.bank = pad.bank
            state.selectedPad = pad
            state.hit(pad)
            seconds = cut.duration
            state.addLog("SAMPLE", String(format: "TAKE %d on %@%d · %.1f s · silence trimmed", takeNumber,
                                          pad.bank.letter, pad.number, cut.end - cut.start), tint: .grey)
            DebugLog.event("sample_take", ["pad": "\(pad.bank.letter)\(pad.number)", "sec": cut.duration,
                                           "start": cut.start, "end": cut.end])
            return true
        } catch {
            fail("Couldn't use the take: \(error.localizedDescription)")
            return false
        }
    }

    /// Asks for the microphone up front (when SAMPLE is armed), so the prompt never interrupts a held pad.
    static func requestPermission() async -> Bool { await CrateMicrophone.requestPermission() }

    /// Used on gesture cancellation, view disappearance and interruption; retains the WAV on disk.
    func cancelRecording() {
        generation += 1
        permissionTask?.cancel()
        permissionTask = nil
        isPreparing = false
        isRecording = false
        meterTask?.cancel()
        meterTask = nil
        let take = recorder
        recorder = nil
        take?.stop()
        level = 0
        restorePlayback()
    }

    private func restorePlayback() {
        #if os(iOS)
        guard sessionChanged else { return }
        do {
            // Do not deactivate the session: the performance engine remains running.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            sessionChanged = false
        } catch {
            fail("Couldn't restore playback routing: \(error.localizedDescription)")
        }
        #endif
    }

    private func fail(_ message: String) {
        errorMessage = message
        state.addLog("ERR", message, tint: .red)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let current = self.recorder, ObjectIdentifier(current) == id, self.isRecording else { return }
            if flag { if !self.intoPad { await self.stopRecording(chop: self.chopType) } }
            else { self.cancelRecording(); self.fail("Recording stopped unexpectedly. Please try another take.") }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let current = self.recorder, ObjectIdentifier(current) == id else { return }
            self.cancelRecording()
            self.fail("Couldn't save microphone audio. Check available storage and try again.")
        }
    }
}
