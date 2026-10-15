import Foundation

/// AI PERFORM: at the start of bar n, Jev (`perform` questions) decides the fill for bar n+1.
/// Offline → a rule-based phrase performer (fills at the end of 4/8-bar phrases).
extension Orchestrator {
    func setPerform(_ on: Bool) {
        state.performOn = on
        let engine = state.engine
        if on {
            if !performHooked {
                performPrevOnBar = engine.onBar
                performHooked = true
            }
            let prev = performPrevOnBar
            engine.onBar = { [weak self] bar in
                prev?(bar)
                guard let strong = self else { return }
                Task { @MainActor in strong.performBar(bar) }
            }
            barsSinceFill = 8
            state.addLog("PERFORM", jev.available ? "ON · AI plays along every bar" : "ON · plays along every bar", tint: .orange)
        } else {
            if performHooked {
                engine.onBar = performPrevOnBar
                performHooked = false
            }
            state.lastPerform = ""
            state.addLog("PERFORM", "OFF", tint: .grey)
        }
    }

    func performBar(_ bar: Int) {
        guard state.performOn, !performBusy else { return }
        let next = bar + 1
        let phrase = 8
        let barInPhrase = next % phrase + 1
        barsSinceFill += 1
        guard jev.available else {
            let rotation = ["snare_roll", "hat_stutter", "kick_double", "crash_next", "dropout", "halftime"]
            var fill = "none"
            if barInPhrase == phrase { fill = rotation[perfRotation % rotation.count]; perfRotation += 1 }
            else if barInPhrase == 4 { fill = "ghost_notes" }
            else if barInPhrase == 1, lastFill != "crash_next", barsSinceFill <= 1 { fill = "none" }
            queuePerform(fill: fill, energy: nil, atBar: next, ms: nil)
            return
        }
        performBusy = true
        let style = session.map { library.styleInfo($0.drumStyle).label } ?? state.styleLabel
        let parts = [lastPattern.lanes.keys.contains { $0.bank == .a } ? "drums" : nil,
                     lastPattern.lanes.keys.contains { $0.bank == .b } ? "sample chops" : nil,
                     lastPattern.notes.isEmpty ? nil : "bass"].compactMap { $0 }.joined(separator: ", ")
        let text = "Style: \(style). BPM \(Int(state.bpm)). Bar \(barInPhrase) of \(phrase). Energy \(String(format: "%.2f", perfEnergy)). "
            + "Last fill \(barsSinceFill) bars ago (\(lastFill)). Active parts: \(parts.isEmpty ? "drums" : parts). Performer mode: tasteful."
        Task { [weak self] in
            guard let self else { return }
            let r = await self.jev.ask("perform", state: text, timeout: 2.0)
            self.performBusy = false
            guard self.state.performOn else { return }
            let a = r?.answers
            self.queuePerform(fill: a?["fill"]?.choice ?? "none", energy: a?["energy"]?.score, atBar: next, ms: r?.ms)
        }
    }

    func queuePerform(fill id: String, energy: Double?, atBar bar: Int, ms: Int?) {
        var ops: [FillOp] = []
        var name = ""
        if id != "none", let f = library.grooves.fill(id: id) {
            ops += f.ops
            name = f.name
        }
        if let e = energy {
            perfEnergy = e
            if e < 0.3 {
                ops.append(FillOp(op: "clear", lanes: ["perc", "perc2", "shaker"], fromStep: 0))
                name = name.isEmpty ? "LOW" : name + " · LOW"
            }
        }
        DebugLog.event("perform", ["bar": bar, "fill": id, "energy": energy ?? -1, "ms": ms ?? -1])
        guard !ops.isEmpty else { return }
        state.engine.queueFill(FillDef(id: id, name: name, ops: ops), atBar: bar)
        state.lastPerform = name
        if id != "none" { lastFill = id; barsSinceFill = 0 }
        state.addLog("PERFORM", "▸ \(name)", ms: ms, tint: .orange)
    }
}
