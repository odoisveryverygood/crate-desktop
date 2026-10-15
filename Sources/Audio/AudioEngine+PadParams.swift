import Foundation
import AVFoundation

// The pad editor's controls on the engine side: a params-only change re-renders one pad from its kept raw slice
// (no file decode, the rest of the bank untouched), then swaps it in atomically.

extension AudioEngine {

    /// Re-render `pad` with `sound.params`. False when the pad isn't holding that sound's slice (different file,
    /// edges or gain; or another load replaced it meanwhile): the caller reloads the bank instead.
    func rerender(_ pad: PadID, sound: PadSound) async -> Bool {
        guard let pa = audio(for: pad) else { return false }
        var same = pa.sound
        same.params = sound.params
        guard same == sound else { return false }
        let t0 = Clock.now()
        var was = pa.sound.params, now = sound.params
        was.favorite = false; now.favorite = false
        let out: PadAudio
        if was == now {   // ★ only: same audio
            out = PadAudio(sound: sound, raw: pa.raw, rendered: pa.buffer)
        } else {
            out = await withCheckedContinuation { cont in
                loadQueue.async { cont.resume(returning: PadAudio(sound: sound, raw: pa.raw)) }
            }
        }
        let ms = Int(((Clock.now() - t0) * 1000).rounded())
        let swapped: Bool = stateLock.withLock {
            guard shared.padAudio[pad] === pa else { return false }
            shared.padAudio[pad] = out
            return true
        }
        if DebugLog.enabled {
            var f = PadRender.stats(out.buffer)
            let raw = PadRender.stats(pa.raw)
            f["pad"] = pad.key
            f["ms"] = ms
            f["swapped"] = swapped
            f["params"] = sound.params.summary
            f["raw"] = ["frames": raw["frames"] ?? 0, "rms": raw["rms"] ?? 0, "head": raw["head"] ?? 0, "tail": raw["tail"] ?? 0]
            DebugLog.event("pad_render", f)
        }
        return swapped
    }

    /// Play a pad to hear an edit: like a tap, but never recorded or kept as a jam.
    func audition(_ pad: PadID) {
        let t = Clock.now()
        q.async { self.liveTrigger(pad, velocity: 110, semitones: 0, tapTime: t, record: false) }
    }

    /// Release time of whatever `pad` holds (seconds; 0 = the engine's default short fades).
    func releaseTime(_ pad: PadID) -> Double {
        audio(for: pad)?.sound.params.release ?? 0
    }
}
