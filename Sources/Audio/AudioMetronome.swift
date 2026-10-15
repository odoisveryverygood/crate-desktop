import Foundation
import AVFoundation

// Metronome, count-in, start bar and quantized bar jumps for AudioEngine. The click player feeds mainMixerNode after
// the master tap, so clicks are heard but never printed into bounces, meters or the debug WAV. Clicks are scheduled
// by the sequencer clock (host time) like every other step, so they sit exactly on the grid the pads play to.

extension AudioEngine {

    // MARK: - Public API (any thread)

    var metronome: Bool {
        get { stateLock.withLock { shared.metronome } }
        set {
            stateLock.withLock { shared.metronome = newValue }
            q.async {
                self.metronomeQ = newValue
                // Off: drop clicks already queued (keep a running count-in, which always clicks).
                if !newValue && !(self.playingQ && self.nextStep < self.startStepQ) {
                    self.clickPlayer.stop()
                    try? self.clickPlayer.cratePlay()
                }
                DebugLog.event("metronome", ["on": newValue])
            }
        }
    }

    var startBar: Int {
        get { stateLock.withLock { shared.startBar } }
        set { stateLock.withLock { shared.startBar = max(0, newValue) } }
    }

    func play(countIn beats: Int) {
        stateLock.withLock { shared.playing = true }
        q.async { self.startTransport(countIn: beats) }
    }

    func jump(toBar bar: Int) {
        startBar = bar
        q.async { self.jumpOnQ(toBar: bar) }
    }

    // MARK: - Clicks (q)

    /// Step `s` is on a beat: click if it's in the count-in (always) or the metronome is on (accent on beat 1).
    /// Count-in beats also drive the UI's 4 · 3 · 2 · 1 (`onCountIn`, on main, at the click's time).
    func scheduleBeat(_ s: Int, now: Double) {
        let pre = s < startStepQ
        let t = max(stepTime(s), now + 0.003)
        if pre || metronomeQ, let clicks = clickBuffers {
            let accent = Self.floorDiv(s, 16) * 16 == s
            clickPlayer.scheduleBuffer(accent ? clicks.accent : clicks.normal, at: AVAudioTime(hostTime: Clock.hostTicks(t)),
                                       options: [], completionHandler: nil)
            DebugLog.event("click", ["step": s, "accent": accent, "pre": pre, "at": t,
                                     "lead_ms": Int(((t - now) * 1000).rounded())])
        }
        if pre {
            notifyCountIn((startStepQ - s + 3) / 4, at: t)
        } else if s == startStepQ, countInPending {
            countInPending = false
            notifyCountIn(0, at: t)
        }
    }

    private func notifyCountIn(_ left: Int, at t: Double) {
        let gen = stateLock.withLock { shared.transportGen }
        let delay = max(0, t - Clock.now())
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.stateLock.withLock({ self.shared.transportGen }) == gen else { return }
            self.onCountIn?(left)
        }
    }

    /// A 30 ms decaying sine (2 kHz accent, 1.3 kHz otherwise), the count-in's click, in the engine format.
    static func makeClicks(_ fmt: AVAudioFormat) -> (accent: AVAudioPCMBuffer, normal: AVAudioPCMBuffer)? {
        func click(_ f: Double, _ amp: Double) -> AVAudioPCMBuffer? {
            let sr = fmt.sampleRate
            let n = AVAudioFrameCount(sr * 0.03)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n), let ch = buf.floatChannelData else { return nil }
            buf.frameLength = n
            for i in 0..<Int(n) {
                let t = Double(i) / sr
                let v = Float(sin(2 * .pi * f * t) * exp(-t * 140) * amp)
                for c in 0..<Int(fmt.channelCount) { ch[c][i] = v }
            }
            return buf
        }
        guard let a = click(2000, 0.55), let b = click(1300, 0.38) else { return nil }
        return (a, b)
    }

    /// Output latency + one IO buffer: how long after its host-time schedule a sound is heard. 0 in silent mode.
    static func measureHearLatency() -> Double {
        #if os(iOS)
        guard !AppConfig.silentAudio else { return 0 }
        let s = AVAudioSession.sharedInstance()
        let v = s.outputLatency + s.ioBufferDuration
        return v.isFinite ? max(0, min(0.5, v)) : 0
        #else
        return 0
        #endif
    }

    // MARK: - Bar jumps (q)

    /// Playing: the next beat boundary that isn't scheduled yet becomes `bar`'s downbeat. Counting in: the take starts
    /// at `bar` instead. Stopped: nothing to do (`startBar` already says where PLAY starts).
    func jumpOnQ(toBar bar: Int) {
        guard playingQ else { return }
        if cueWaiting, let p = pending {   // a SONG cue is waiting: cue its pattern from this bar instead
            cueOnQ(p.pattern, bar: bar)
            return
        }
        let total = max(1, active.pattern.bars) * 16
        let target = (max(0, bar) * 16) % total
        if nextStep < startStepQ {   // still counting in: slide the whole count-in onto the new bar
            let delta = target - startStepQ
            startStepQ += delta
            nextStep += delta
            anchorStep += delta
            timelineQ.anchorStep = anchorStep
            timelineQ.floorStep = startStepQ
            timelineQ.hasPrev = false
            schedBar = Self.floorDiv(startStepQ, 16)
            publishTimeline()
            DebugLog.event("bar_jump", ["bar": bar + 1, "countIn": true])
            return
        }
        let at = (nextStep + 3) / 4 * 4
        let to = at + (((target - at) % total) + total) % total
        pendingJump = (at, to)
        DebugLog.event("bar_jump", ["bar": bar + 1, "at": at, "to": to, "time": stepTime(at),
                                    "in_ms": Int(((stepTime(at) - Clock.now()) * 1000).rounded())])
    }

    /// Called by tick() when the scheduler reaches the jump's beat: the timeline continues from `to` at that time.
    func applyJump(_ j: (at: Int, to: Int)) {
        pendingJump = nil
        cueWaiting = false
        let t = stepTime(j.at)
        reanchor(step: j.to, time: t, keepPrev: true)
        nextStep = j.to
        let total = max(1, active.pattern.bars) * 16
        DebugLog.event("bar_jump_applied", ["at": j.at, "to": j.to, "bar": ((j.to % total) + total) % total / 16 + 1,
                                            "time": t, "beat_aligned": j.at % 4 == 0])
    }

    // MARK: - Debug: deterministic record timing

    /// `crate://rechit?dt=-0.04`: a hit whose touch lands `dt` seconds from the moment the next loop start is HEARD
    /// (the count-in's downbeat, or the next pass's step 1 while playing), run through the same quantizer as a real
    /// hit. Recording: it's written into the pattern (not sounded). Not recording: dry run, logged only.
    func simulateRecHit(_ pad: PadID, dt: Double, velocity: Int = 110) {
        q.async {
            guard self.playingQ else {
                DebugLog.event("rechit_sim", ["error": "not playing"])
                return
            }
            let total = max(1, self.active.pattern.bars) * 16
            let loopStep: Int
            if self.nextStep < self.startStepQ || self.timelineQ.rawPosition(at: Clock.now()) < Double(self.startStepQ) {
                loopStep = self.startStepQ
            } else {
                let pos = self.timelineQ.rawPosition(at: Clock.now())
                loopStep = (Int(pos) / total + 1) * total
            }
            let heard = self.stepTime(loopStep) + self.hearLatencyQ
            let touch = heard + dt
            let res = self.quantizedStep(tapTime: touch)
            let recording = self.stateLock.withLock { self.shared.recording }
            var fields: [String: Any] = ["dt_ms": Int((dt * 1000).rounded()), "loopAbs": loopStep,
                                         "hear_ms": (self.hearLatencyQ * 10000).rounded() / 10,
                                         "pos": ((self.timelineQ.rawPosition(at: touch - self.hearLatencyQ)) * 1000).rounded() / 1000,
                                         "recording": recording]
            if let res {
                fields["abs"] = res.step
                fields["step"] = ((res.step % total) + total) % total
            } else {
                fields["step"] = "dropped"
            }
            DebugLog.event("rechit_sim", fields)
            if recording, let pa = self.audio(for: pad) {
                self.recordLive(pad, velocity: velocity, semitones: 0, tapTime: touch, audio: pa, sounded: false)
            }
        }
    }
}
