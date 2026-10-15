import Foundation

// The SONG sheet's edits and the bar pager's step edit: typed / decimal tempo, the song KEY (a transpose that lives
// with the pattern), and toggling a step in one bar of the loop. Kept out of Sources/AI on purpose.

extension Orchestrator {
    /// A hand edit wins over a GPT rewrite still in flight (same as the AI's own edits do).
    private func handEdit() {
        digSerial += 1
        if gptTask != nil, state.aiStatus == .arranging { state.setStatus(.done, "your edit wins") }
        gptTask?.cancel()
        gptTask = nil
    }

    /// Toggles step `col` of bar `bar` only (the bar pager's view); the ALL view uses `toggleStep(_:col:bar:label:)`.
    func toggleStep(_ pads: [PadID], col: Int, onlyBar bar: Int, label: String) {
        leaveSong()
        var p = state.engine.pattern
        let bars = max(1, p.bars)
        let step = (bar % bars) * 16 + col
        let isOn = pads.contains { pad in
            (p.lanes[pad] ?? []).contains { $0.step == step } || (p.notes[pad] ?? []).contains { $0.step == step }
        }
        checkpoint("\(label) bar \(bar % bars + 1) step \(col + 1)")
        handEdit()
        if isOn {
            for pad in pads {
                p.lanes[pad] = p.lanes[pad].map { $0.filter { $0.step != step } }
                p.notes[pad] = p.notes[pad].map { $0.filter { $0.step != step } }
            }
        } else if let pad = pads.first {
            if let notes = p.notes[pad], !notes.isEmpty {
                // melodic lane: the pitch of the nearest note before it (else the first note)
                let ref = notes.last { $0.step <= step } ?? notes[0]
                p.notes[pad] = (notes + [NoteEvent(step: step, length: 1, midi: ref.midi, velocity: ref.velocity)])
                    .sorted { $0.step < $1.step }
            } else {
                let vel = (p.lanes[pad] ?? []).map(\.velocity).max() ?? 100
                p.lanes[pad, default: []].append(Hit(step: step, velocity: min(118, vel)))
                p.lanes[pad]?.sort { $0.step < $1.step }
            }
        }
        state.engine.setPattern(p, timing: .now)
        lastPattern = p
        DebugLog.event("seq_toggle", ["lane": label, "bar": bar % bars + 1, "step": col + 1, "on": !isOn, "only_bar": true])
    }

    /// Tempo to 0.1 BPM (typed values may have a decimal), clamped 50–200. Same undo rule as `setTempo`.
    func setTempoExact(_ bpm: Double, checkpoint cp: Bool) {
        guard bpm.isFinite else { return }
        let v = (min(200, max(50, bpm)) * 10).rounded() / 10
        guard abs(v - state.bpm) > 0.001 || abs(v - state.engine.bpm) > 0.001 else { return }
        if cp { checkpoint("tempo \(SongFormat.bpm(state.bpm)) BPM") }
        state.engine.bpm = v
        state.bpm = v
        DebugLog.event("tempo", ["bpm": v])
    }

    /// The song's KEY: the root moves the pitched pads (chops, loops, bass, keys on banks B–D) by the nearest
    /// semitone distance through the pattern's transpose; switching major / minor relabels to the relative key (the
    /// same notes, so nothing is re-pitched). With no key known yet, it just names the key (scale lock, the AI's bass).
    func setSongKey(pc: Int, minor: Bool, checkpoint cp: Bool = true) {
        var p = state.engine.pattern
        let target = SongKey.name(pc, minor: minor)
        guard var src = Music.parseKey(state.scaleKey) else {
            if cp { checkpoint("key —") }
            state.scaleKey = target
            DebugLog.event("song_key", ["key": target, "transpose": 0, "named": true])
            return
        }
        let before = SongKey.sounding(state.scaleKey, transpose: p.transpose)
        if let b = before, b.pc == pc, b.minor == minor { return }
        if cp { checkpoint("key \(before.map { SongKey.name($0.pc, minor: $0.minor) } ?? "—")") }
        if src.minor != minor {   // A minor ⇄ C major: same notes, relabel the material's key
            src = ((src.pc + (src.minor ? 3 : 9)) % 12, minor)
            state.scaleKey = SongKey.name(src.pc, minor: minor)
        }
        let shift = SongKey.nearest(pc - src.pc)
        if shift != p.transpose {
            handEdit()
            p.transpose = shift
            state.engine.setPattern(p, timing: .now)
            // SONG mode: `p` is the rendered song; the beat (and every later render) takes the new key too
            if state.song.songMode { lastPattern.transpose = shift } else { lastPattern = p }
        }
        DebugLog.event("song_key", ["key": target, "material": state.scaleKey ?? "", "transpose": shift])
    }
}
