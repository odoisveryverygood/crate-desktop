import Foundation
import AVFoundation
import AudioToolbox

// PAD FX (MPC Sample style): `setFX(type)` picks the effect, `setPunch(amount)` (hinge / FX knob) drives it.
// Every parameter change is ramped over ~20 ms on `fxQ` (no zipper noise); switching effects fades the old
// one to neutral, reconfigures (presets / delay time) while it is silent, then ramps the new one in.
// BEAT REPEAT and HALF SPEED live in the sequencer (`q`): step remapping and a varispeed multiplier.

extension AudioEngine {

    func setFX(_ type: FXType?) {
        var unmuteGen: Int? = nil
        fxLock.withLock {
            fxSelected = type
            if type != nil && breakdown { breakdown = false; muteGen += 1; unmuteGen = muteGen }
        }
        if let g = unmuteGen { rampBreakdown(muted: false, gen: g) }
        fxQ.async {
            let old = self.fxTypeQ
            guard old != type else { return }
            self.fxRampGen &+= 1   // cancel in-flight ramps of the old effect
            let from = self.fxApplied
            if from > 0.0005 {
                for i in 1...5 {
                    self.applyTyped(old, from * Double(5 - i) / 5)
                    usleep(4000)
                }
            } else {
                self.applyTyped(old, 0)
            }
            self.fxApplied = 0
            self.configure(for: type)
            self.fxTypeQ = type
            let target = self.fxLock.withLock { self.punchValue }
            self.rampFX(to: target)
            DebugLog.event("fx_engine", ["t": type?.rawValue ?? "punch", "from": old?.rawValue ?? "punch",
                                         "amt": (target * 1000).rounded() / 1000])
        }
    }

    /// fxQ only. Ramp the selected effect's amount to `target` in 5 steps; a newer ramp cancels this one
    /// and continues from wherever this one got to.
    func rampFX(to target: Double, over dur: Double = 0.02) {
        fxRampGen &+= 1
        let gen = fxRampGen
        let from = fxApplied
        let steps = 5
        for i in 1...steps {
            fxQ.asyncAfter(deadline: .now() + dur * Double(i) / Double(steps)) { [weak self] in
                guard let self = self, self.fxRampGen == gen else { return }
                let v = from + (target - from) * Double(i) / Double(steps)
                self.fxApplied = v
                self.applyTyped(self.fxTypeQ, v)
            }
        }
    }

    /// Delay time for the selected effect (DELAY 3/16, DUB 3/8, default chain 3/16).
    func fxDelayTime(for type: FXType?, sps: Double) -> TimeInterval {
        switch type {
        case .dub?: return min(2.0, 6 * sps)
        case .comb?: return 0.010
        default: return min(2.0, 3 * sps)
        }
    }

    /// fxQ only, while the outgoing effect is at zero: presets, delay time / tone, distortion bypass.
    func configure(for type: FXType?) {
        let preset: AVAudioUnitDistortionPreset?
        switch type {
        case .lofi?: preset = .drumsBitBrush
        case .crush?: preset = .multiDecimated4
        case .ringMod?: preset = .speechAlienChatter
        case .radio?: preset = .speechRadioTower
        case .granular?: preset = .drumsBufferBeats
        default: preset = nil
        }
        // Bypass while the preset loads (a preset sets its own wet mix for a render cycle otherwise).
        fxDist.bypass = true
        fxDist.wetDryMix = 0
        if let preset {
            fxDist.loadFactoryPreset(preset)
            fxDist.wetDryMix = 0
            if type == .ringMod {
                // A pure ring modulator: silence the other distortion stages, carrier swept by the amount.
                setDist(kDistortionParam_DelayMix, 0)
                setDist(kDistortionParam_DecimationMix, 0)
                setDist(kDistortionParam_PolynomialMix, 0)
                setDist(kDistortionParam_RingModMix, 100)
                setDist(kDistortionParam_RingModBalance, 50)
                setDist(kDistortionParam_SoftClipGain, -3)
            }
            fxDist.bypass = false
        }
        let bpm = stateLock.withLock { shared.bpm }
        delayFX.delayTime = fxDelayTime(for: type, sps: 60.0 / bpm / 4.0)
        delayFX.lowPassCutoff = type == .dub ? 2200 : 9000
        delayFX.feedback = 35
        eq.bands[1].frequency = 10
        eq.bands[2].gain = 0
        eq.bands[3].gain = 0
        lowPass.frequency = maxCutoff
    }

    private func setDist(_ id: AudioUnitParameterID, _ v: Float) {
        AudioUnitSetParameter(fxDist.audioUnit, id, kAudioUnitScope_Global, 0, v, 0)
    }

    /// fxQ only. Set `type`'s parameters for amount p (p = 0 is neutral for every effect).
    func applyTyped(_ type: FXType?, _ p0: Double) {
        let p = min(1, max(0, p0))
        guard let type else { applyFX(p); return }
        let maxC = Double(maxCutoff)
        switch type {
        case .lpFilter:
            lowPass.frequency = Float(min(maxC, 20000 * pow(150.0 / 20000.0, pow(p, 0.8))))
        case .hpFilter:
            eq.bands[1].frequency = Float(10 * pow(600.0, pow(p, 0.9)))          // 10 Hz → 6 kHz
        case .bpFilter:
            eq.bands[1].frequency = Float(10 * pow(80.0, p))                      // HP 10 → 800 Hz
            lowPass.frequency = Float(min(maxC, 20000 * pow(1500.0 / 20000.0, p))) // LP 20k → 1.5k
        case .lofi:
            fxDist.wetDryMix = Float(70 * p)
            lowPass.frequency = Float(min(maxC, 20000 * pow(2800.0 / 20000.0, p)))
        case .crush:
            fxDist.wetDryMix = Float(90 * p)
        case .ringMod:
            let f = 80 * pow(1500.0 / 80.0, p)
            setDist(kDistortionParam_RingModFreq1, Float(f))
            setDist(kDistortionParam_RingModFreq2, Float(f * 1.5))
            fxDist.wetDryMix = Float(95 * pow(p, 0.7))
        case .radio, .granular:
            fxDist.wetDryMix = Float(100 * p)
        case .delay:
            delayFX.wetDryMix = Float(50 * p)
            delayFX.feedback = Float(15 + 50 * p)
        case .dub:
            delayFX.wetDryMix = Float(55 * p)
            delayFX.feedback = Float(30 + 55 * p)
            reverb.wetDryMix = Float(25 * p)
        case .comb:
            delayFX.delayTime = 0.010 * pow(0.15, p)                      // 10 → 1.5 ms
            delayFX.feedback = Float(50 + 32 * p)
            delayFX.wetDryMix = Float(55 * p)
        case .reverb:
            reverb.wetDryMix = Float(75 * p)
        case .color:
            eq.bands[2].gain = Float(-10 * p)
            eq.bands[3].gain = Float(8 * p)
        case .beatRepeat:
            q.async { self.setRepeat(p) }
        case .halfSpeed:
            let m = Float(((1 - 0.5 * p) * 50).rounded() / 50)                    // quantized: voices share rates
            q.async { self.rateMulQ = m }
        }
    }

    // MARK: - BEAT REPEAT (q)

    /// amount < 0.08 off · < 0.5 repeat the current 1/8 · ≥ 0.5 1/16 · ≥ 0.85 1/32 (ratchet ×2).
    func setRepeat(_ p: Double) {
        let len = p < 0.08 ? 0 : (p < 0.5 ? 2 : 1)
        let rat = p >= 0.85 ? 2 : 1
        if len == 0 {
            if repeatLen != 0 { repeatLen = 0; DebugLog.event("beat_repeat", ["on": false, "from": nextStep]) }
            return
        }
        let was = repeatLen
        if was == 0 { captureRepeat(from: nextStep) } else if len != was { repeatFrom = nextStep }
        repeatLen = len
        repeatRatchet = rat
        if was != len { DebugLog.event("beat_repeat", ["on": true, "len": len, "ratchet": rat, "from": repeatFrom, "hit": repeatHit]) }
    }

    /// Steps before `s0` are already scheduled; from `s0` on the sequencer repeats the most recent step that had hits
    /// (searching back 4 steps, then forward) — so the roll is never an empty 16th, and it always lands on the grid.
    func captureRepeat(from s0: Int) {
        repeatFrom = s0
        var hit = s0
        if let s = (1...4).map({ s0 - $0 }).first(where: { !naturalEvents(at: $0).isEmpty }) {
            hit = s
        } else if let s = (0...3).map({ s0 + $0 }).first(where: { !naturalEvents(at: $0).isEmpty }) {
            hit = s
        }
        repeatHit = hit
    }
}
