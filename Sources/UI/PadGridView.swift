import SwiftUI
import UniformTypeIdentifiers

/// 4×4 pads in MPC order (pad 1 bottom-left, 13–16 top row) for the current bank.
/// Touch-down triggers (multi-touch). Velocity per the SONG sheet: BY HEIGHT (top 127, bottom 70; default),
/// WIDE (top 127, bottom 25: ghost notes) or FULL (127). With a by-height mode the pads carry three faint ticks on
/// their right edge, and a hit's flash fills the pad up to its velocity.
/// Pads flash orange ≤ 100 ms when hit live or when the sequencer plays them.
struct PadGridView: View {
    let state: AppState
    var gap: CGFloat = 5

    @State private var fingers: [ObjectIdentifier: Int] = [:]
    /// Where each finger went down (a take locks when its finger slides up).
    @State private var downAt: [ObjectIdentifier: CGPoint] = [:]
    /// Fingers holding an effect pad on the FX layer (punch-in), newest last.
    @State private var fxFingers: [ObjectIdentifier] = []
    @State private var liveHits: [Int: Date] = [:]
    /// Velocity of each pad's last live hit (for the flash).
    @State private var liveVel: [Int: Int] = [:]
    @AppStorage(SongPrefs.velocityKey) private var velocityMode = VelocityMode.full.rawValue
    @State private var dropHover = false
    @State private var importing = false
    /// Pull-to-talk: the one finger that may slide down into a voice pull (a second finger first = playing), its pad,
    /// and whether it's pulling.
    @State private var voiceFinger: (id: ObjectIdentifier, pad: Int, pulling: Bool)? = nil
    /// Pad swipes (plain pad layer only): the one finger that may flick its pad ↑ (remove) or ← → (another sound).
    /// Down is pull-to-talk (above). The axis is decided once the finger is past `PadSwipe.decide`.
    @State private var swipe: PadSwipe? = nil
    /// A committed swipe's animation (or a shake / bump), per pad.
    @State private var motion: [PadID: PadMotion] = [:]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let cw = max(1, (size.width - 3 * gap) / 4)
            let ch = max(1, (size.height - 3 * gap) / 4)
            let top = geo.frame(in: .global).minY
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { ctx in
                let frame = LiveFrame(state)
                let now = ctx.date
                let bank = state.bank
                let mode = state.mode
                let held = Set(fingers.values)
                ZStack(alignment: .topLeading) {
                    ForEach(0..<16, id: \.self) { i in
                        let row = 3 - i / 4
                        let col = i % 4
                        let pad = PadID(bank, i)
                        let pose = pose(pad, now: now, cw: cw)
                        cell(i, pad: pad, mode: mode, lit: isLit(i, pad: pad, mode: mode, held: held, frame: frame, now: now),
                             frame: frame, pose: pose)
                            .frame(width: cw, height: ch)
                            .scaleEffect(pose.cellScale)
                            .offset(pose.cellOffset)
                            .position(x: CGFloat(col) * (cw + gap) + cw / 2,
                                      y: CGFloat(row) * (ch + gap) + ch / 2)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
            .overlay(
                TouchSurface { phase, id, pt in
                    handle(phase, id, pt, cw: cw, ch: ch, top: top)
                }
            )
            .onChange(of: CrateUI.shared.fxLayer) { _, on in
                if !on, !fxFingers.isEmpty {
                    fxFingers.removeAll()
                    CrateUI.shared.punchOut(state)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.blue, lineWidth: 3)
                    .opacity(dropHover ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onDrop(of: [UTType.audio.identifier, UTType.fileURL.identifier], isTargeted: $dropHover) { providers, point in
                guard !importing else { return false }
                importing = true
                let col = min(3, max(0, Int((point.x + gap / 2) / (cw + gap))))
                let row = min(3, max(0, Int((point.y + gap / 2) / (ch + gap))))
                let pad = PadID(state.bank, (3 - row) * 4 + col)
                let accepted = AudioImport.receive(providers, at: pad) { result in
                    switch result {
                    case .success(let audio):
                        // A song becomes 16 chops on bank D; a short sound lands on the pad it was dropped on.
                        if audio.duration > 2 { Task { await AudioImport.chop16(audio, state: state); importing = false } }
                        else { Task { await AudioImport.loadOnPad(audio, state: state); importing = false } }
                    case .failure(let error):
                        importing = false
                        state.addLog("ERR", "Drop: \(error.localizedDescription)", tint: .red)
                    }
                }
                if !accepted { importing = false }
                return accepted
            }
        }
    }

    private func isLit(_ i: Int, pad: PadID, mode: Mode, held: Set<Int>, frame: LiveFrame, now: Date) -> Bool {
        if held.contains(i) || state.heldPads.contains(pad) { return true }
        if let t = liveHits[i], now.timeIntervalSince(t) < Theme.flash { return true }
        if mode == .levels16 { return false }
        if state.lastHitPad == pad, now.timeIntervalSince(state.lastHitTime) < Theme.flash { return true }
        return !state.isMuted(pad) && frame.sequencerFlash(pad)
    }

    @ViewBuilder
    private func cell(_ i: Int, pad: PadID, mode: Mode, lit: Bool, frame: LiveFrame, pose: PadPose) -> some View {
        let ui = CrateUI.shared
        if ui.fxLayer {
            // FX held (or latched): the pads are the effects; tap one to pick it.
            let fx = FXType.padLayout[i]
            FXPadCell(number: i + 1, label: fx?.label ?? "PUNCH", hint: fx?.hint ?? "LPF + SPACE",
                      selected: fx == state.fx && (fx != nil || state.punch > 0.04), held: lit)
                .modifier(PadAccessibility(id: "fx-pad-\(i + 1)", label: fx?.label ?? "PUNCH") { ui.pickFX(i, state) })
        } else if mode == .levels16 {
            let sel = state.selectedPad
            PadCell(number: i + 1,
                    name: "TUNE \(UIHelpers.signed(i - 7))",
                    placeholder: nil,
                    barColor: state.sound(sel) != nil ? Theme.bank(sel.bank) : nil,
                    lit: lit,
                    selected: i == 7,
                    shortcut: MusicalTyping.padKeys[i].uppercased(),
                    category: state.sound(mode == .levels16 ? state.selectedPad : pad)?.category,
                    bank: pad.bank,
                    spinning: isSounding(i, pad: pad, frame: frame))
                .modifier(PadAccessibility(id: "pad-\(pad.bank.letter)-\(pad.number)",
                                           label: "Tune \(i - 7)") { fire(i, velocity: 112) })
        } else {
            let name = UIHelpers.padName(state, pad)
            let recording = ui.recordingPad == pad
            let zones = velocityMode != VelocityMode.full.rawValue
            PadCell(number: i + 1,
                    name: name,
                    placeholder: pad.bank == .a ? UIHelpers.bankANames[i] : nil,
                    barColor: name != nil ? Theme.bank(pad.bank) : nil,
                    lit: lit && !recording,
                    selected: state.selectedPad == pad,
                    shortcut: MusicalTyping.padKeys[i].uppercased(),
                    category: state.sound(mode == .levels16 ? state.selectedPad : pad)?.category,
                    bank: pad.bank,
                    spinning: isSounding(i, pad: pad, frame: frame),
                    armed: ui.sampleArmed && ui.recordingPad == nil,
                    recording: recording,
                    recSeconds: recording ? ui.sampler?.seconds ?? 0 : 0,
                    zones: zones && name != nil,
                    level: zones && lit ? flashLevel(i, pad: pad, frame: frame) : nil,
                    params: state.sound(pad)?.params,
                    nameOffset: pose.nameOffset,
                    nameOpacity: pose.nameOpacity)
                .modifier(PadMarks(muted: state.isMuted(pad), muteLayer: ui.muteLayer,
                                   voice: VoiceDig.shared.mark(for: pad)))
                .modifier(PadAccessibility(id: "pad-\(pad.bank.letter)-\(pad.number)",
                                           label: name ?? "Pad \(pad.number)") { fire(i, velocity: 110) })
        }
    }

    /// 0…1: the velocity behind the current flash (the live hit's, else the sequencer's), for the fill height.
    private func flashLevel(_ i: Int, pad: PadID, frame: LiveFrame) -> Double {
        if let v = liveVel[i], fingers.values.contains(i) || liveHits[i].map({ Date().timeIntervalSince($0) < 0.25 }) == true {
            return Double(v) / 127
        }
        if let v = frame.sequencerFlashVelocity(pad) { return Double(v) / 127 }
        return 1
    }

    private func isSounding(_ i: Int, pad: PadID, frame: LiveFrame) -> Bool {
        let sound = state.sound(state.mode == .levels16 ? state.selectedPad : pad)
        let duration = max(Theme.flash, ((sound?.end ?? ((sound?.start ?? 0) + 0.4)) - (sound?.start ?? 0))
                                        / (sound?.params.stretch ?? 1))
        if fingers.values.contains(i) || state.heldPads.contains(pad) { return true }
        if let hit = liveHits[i], Date().timeIntervalSince(hit) < duration { return true }
        if state.lastHitPad == pad, Date().timeIntervalSince(state.lastHitTime) < duration { return true }
        guard frame.playing, !state.isMuted(pad) else { return false }
        if !frame.soundingNotes(pad).isEmpty { return true }
        return (frame.pattern.lanes[pad] ?? []).contains {
            let time = frame.hitTime($0, pad)
            return frame.pos >= time && frame.age(time) * frame.stepDur < duration
        }
    }

    /// `top` = the grid's y in the window (the pull threshold shrinks near the bottom edge).
    private func handle(_ phase: TouchPhaseUI, _ id: ObjectIdentifier, _ pt: CGPoint, cw: CGFloat, ch: CGFloat,
                        top: CGFloat) {
        switch phase {
        case .began:
            let col = min(3, max(0, Int((pt.x + gap / 2) / (cw + gap))))
            let row = min(3, max(0, Int((pt.y + gap / 2) / (ch + gap))))
            let i = (3 - row) * 4 + col
            let yIn = min(max(pt.y - CGFloat(row) * (ch + gap), 0), ch)
            let vel = (VelocityMode(rawValue: velocityMode) ?? .height).velocity(y: yIn, height: ch)
            let ui = CrateUI.shared
            fingers[id] = i
            downAt[id] = pt
            if voiceFinger?.pulling != true { voiceFinger = nil }   // a second finger = playing, not talking
            if let sw = swipe, sw.id != id { cancelSwipe(sw) }       // …and not swiping
            if let rec = ui.recordingPad, ui.recordLocked {
                ui.endTake(rec)   // a locked take: any pad stops it
                fingers[id] = nil
                return
            }
            if ui.fxLayer {
                liveHits[i] = Date()
                fxFingers.append(id)
                ui.punchIn(i, amount: punchAmount(yIn, ch), state)
            } else if ui.sampleArmed {
                ui.beginTake(PadID(state.bank, i))   // hold = record into this pad; lift = done
            } else if ui.muteLayer {
                liveHits[i] = Date()
                toggleMute(i)
            } else {
                let shifted = ui.shift
                fire(i, velocity: vel)
                if fingers.count == 1, VoiceDig.allowed(state) {
                    voiceFinger = (id, i, false)
                    if !shifted { swipe = PadSwipe(id: id, pad: PadID(state.bank, i), start: pt) }
                }
            }
        case .moved:
            if let sw = swipe, sw.id == id { swipeMoved(sw, pt, cw: cw, ch: ch) }
            // pull-to-talk: the finger that played the pad slides down (mostly down) = the voice panel follows it.
            // The pad already played on touch-down; a pull never plays it again.
            if let v = voiceFinger, v.id == id, let start = downAt[id] {
                let dx = pt.x - start.x, dy = pt.y - start.y
                if v.pulling {
                    VoiceDig.shared.pullMoved(dy)
                } else if dy > VoiceDig.pullStart, dy > abs(dx) * 1.4 {
                    let th = VoiceDig.threshold(touchY: top + start.y)
                    if VoiceDig.shared.pullBegan(.pad(PadID(state.bank, v.pad)), threshold: th, touch: id, state: state) {
                        voiceFinger?.pulling = true
                        VoiceDig.shared.pullMoved(dy)
                    } else {
                        voiceFinger = nil
                    }
                } else if hypot(dx, dy) > 30 {
                    voiceFinger = nil   // sliding sideways or up = playing, not pulling
                }
            }
            // recording: slide the finger up off the pad to lock the take (hands-free)
            if let i = fingers[id], let start = downAt[id], CrateUI.shared.recordingPad == PadID(state.bank, i),
               !CrateUI.shared.recordLocked, start.y - pt.y > 44 {
                CrateUI.shared.recordLocked = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                DebugLog.event("take_lock", ["pad": "\(state.bank.letter)\(i + 1)"])
            }
            // the newest finger on an effect pad sets the amount: slide up for more
            if fxFingers.last == id, let i = fingers[id] {
                let row = 3 - i / 4
                let yIn = min(max(pt.y - CGFloat(row) * (ch + gap), 0), ch)
                CrateUI.shared.punchMove(amount: punchAmount(yIn, ch), state)
            }
        case .ended:
            if let sw = swipe, sw.id == id { swipeEnded(sw, pt, cw: cw, ch: ch) }
            if let v = voiceFinger, v.id == id {
                voiceFinger = nil
                if v.pulling { VoiceDig.shared.pullEnded(state: state) }
            }
            if let i = fingers[id], CrateUI.shared.recordingPad == PadID(state.bank, i), !CrateUI.shared.recordLocked {
                CrateUI.shared.endTake(PadID(state.bank, i))
            }
            downAt[id] = nil
            if let k = fxFingers.firstIndex(of: id) {
                fxFingers.remove(at: k)
                if let other = fxFingers.last, let j = fingers[other], CrateUI.shared.fxLayer {
                    CrateUI.shared.punchIn(j, amount: state.punch, state)   // the finger still down takes over
                } else if fxFingers.isEmpty {
                    CrateUI.shared.punchOut(state)
                }
            }
            fingers[id] = nil
        }
    }

    // MARK: Pad swipes

    /// The swipe finger moved: decide the axis once (dominant axis ≥ 1.5×, else it's playing), then preview.
    private func swipeMoved(_ sw: PadSwipe, _ pt: CGPoint, cw: CGFloat, ch: CGFloat) {
        var sw = sw
        let dx = pt.x - sw.start.x, dy = pt.y - sw.start.y
        if sw.axis == nil {
            guard max(abs(dx), abs(dy)) > PadSwipe.decide else { return }
            if dy > 0, dy >= abs(dx) * PadSwipe.ratio {
                swipe = nil                     // down = pull-to-talk (the voice finger takes it)
                return
            } else if dy < 0, -dy >= abs(dx) * PadSwipe.ratio {
                sw.axis = .up
            } else if abs(dx) >= abs(dy) * PadSwipe.ratio {
                sw.axis = .horizontal
            } else {
                swipe = nil                     // diagonal = playing
                voiceFinger = nil
                return
            }
            voiceFinger = nil                   // an up / sideways flick never becomes a pull
        }
        // wandered off (more than ~1.5 pads away): it's playing, not a swipe
        if abs(dx) > cw * PadSwipe.reach || abs(dy) > ch * PadSwipe.reach {
            cancelSwipe(sw)
            return
        }
        sw.delta = CGSize(width: dx, height: dy)
        let armed = sw.commits
        if armed != sw.armed {
            sw.armed = armed
            if armed { UISelectionFeedbackGenerator().selectionChanged() }
        }
        swipe = sw
    }

    /// Lifted: past the threshold = commit (remove / swap), else spring back.
    private func swipeEnded(_ sw: PadSwipe, _ pt: CGPoint, cw: CGFloat, ch: CGFloat) {
        swipe = nil
        guard let axis = sw.axis else { return }
        var sw = sw
        let dx = pt.x - sw.start.x, dy = pt.y - sw.start.y
        if abs(dx) <= cw * PadSwipe.reach, abs(dy) <= ch * PadSwipe.reach { sw.delta = CGSize(width: dx, height: dy) }
        let from = sw.preview.nameOffset
        guard sw.commits else {
            motion[sw.pad] = PadMotion(kind: .settle, start: Date(), from: from)
            return
        }
        let pad = sw.pad
        let orch = Orchestrator.current
        switch axis {
        case .up:
            guard state.sound(pad) != nil, let orch else {
                motion[pad] = PadMotion(kind: .bump, start: Date(), from: from)
                UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
                return
            }
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            motion[pad] = PadMotion(kind: .remove, start: Date(), from: from)
            Task { @MainActor in
                await orch.removePad(pad)
                motion[pad]?.inAt = Date()
            }
        case .horizontal:
            let step = sw.delta.width > 0 ? 1 : -1
            guard let orch, orch.canSwipeSwap(pad) else {
                motion[pad] = PadMotion(kind: .shake, start: Date(), from: from)
                UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
                if state.sound(pad) != nil { state.addLog("KIT", "\(pad.key) · nothing to swap", tint: .grey) }
                DebugLog.event("pad_swipe", ["pad": pad.key, "kind": "noswap"])
                return
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            motion[pad] = PadMotion(kind: .swap(dir: CGFloat(step)), start: Date(), from: from)
            Task { @MainActor in
                await orch.swipeSwap(pad, step: step)
                motion[pad]?.inAt = Date()
            }
        }
    }

    /// A second finger, or the finger wandered off: no swipe; the preview springs back.
    private func cancelSwipe(_ sw: PadSwipe) {
        swipe = nil
        if sw.axis != nil { motion[sw.pad] = PadMotion(kind: .settle, start: Date(), from: sw.preview.nameOffset) }
    }

    /// The pad's swipe pose right now: the live drag preview, else a running animation.
    private func pose(_ pad: PadID, now: Date, cw: CGFloat) -> PadPose {
        if let sw = swipe, sw.pad == pad, sw.axis != nil { return sw.preview }
        guard let m = motion[pad] else { return PadPose() }
        return m.pose(now: now, width: cw)
    }

    /// MUTE layer: a tap mutes / unmutes the pad. Stopped, an unmute auditions it quietly so you know what came back.
    private func toggleMute(_ i: Int) {
        let pad = PadID(state.bank, i)
        state.toggleMute(pad)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if !state.isMuted(pad), !state.engine.isPlaying { state.hit(pad, velocity: 60) }
    }

    /// Punch-in depth from where the finger is on its pad: bottom edge 25 %, top edge 100 %.
    private func punchAmount(_ yIn: CGFloat, _ ch: CGFloat) -> Double {
        Double(min(1, max(0.25, 0.25 + 0.75 * (1 - yIn / max(1, ch)))))
    }

    private func fire(_ i: Int, velocity: Int) {
        let pad = PadID(state.bank, i)
        liveHits[i] = Date()
        liveVel[i] = velocity
        if CrateUI.shared.shift {
            state.selectedPad = pad
            CrateUI.shared.shift = false
            return
        }
        if state.mode == .levels16 {
            state.hit(state.selectedPad, velocity: 112, semitones: Double(i - 7))
        } else {
            state.hit(pad, velocity: min(127, max(1, velocity)))
            if state.selectedPad != pad { state.selectedPad = pad }
        }
    }
}

private struct PadAccessibility: ViewModifier {
    let id: String
    let label: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(id)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

/// Direction 05 pad with optional direction 07 vinyl; orange is reserved for live hits.
struct PadCell: View {
    let number: Int
    let name: String?
    let placeholder: String?
    let barColor: Color?
    let lit: Bool
    var selected = false
    var nameSize: CGFloat = 10
    var shortcut: String = ""
    var category: Category? = nil
    var bank: Bank = .a
    var spinning = false
    /// SAMPLE armed: every pad blinks (hold one to record into it).
    var armed = false
    /// This pad is recording the mic right now.
    var recording = false
    var recSeconds: Double = 0
    /// Velocity by height is on: three faint ticks on the right edge show the soft ↔ hard zones.
    var zones = false
    /// The flash's velocity (0…1): an orange wash fills the pad from the bottom up to it.
    var level: Double? = nil
    /// The pad editor's controls: a small ◀ when reversed, a dot when the sound was otherwise changed, ★ = favorite.
    var params: PadParams? = nil
    /// Pad swipes: the name slides / fades inside the pad (clipped by it).
    var nameOffset: CGSize = .zero
    var nameOpacity: Double = 1
    @AppStorage(PadStyle.storageKey) private var padStyle = "plain"

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(recording ? Theme.orange.opacity(0.14) : (lit ? PadFinish.pressed : PadFinish.key))
            if lit, !recording, let level {
                GeometryReader { g in
                    Rectangle().fill(Theme.orange.opacity(0.16))
                        .frame(height: g.size.height * CGFloat(min(1, max(0.08, level))))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            if zones {
                GeometryReader { g in
                    ForEach(1..<4, id: \.self) { k in
                        Rectangle().fill(PadFinish.muted.opacity(0.32))
                            .frame(width: k == 2 ? 7 : 4, height: 1)
                            .position(x: g.size.width - (k == 2 ? 5.5 : 4), y: g.size.height * CGFloat(k) / 4)
                    }
                }
                .allowsHitTesting(false)
            }
            if lit || recording {
                Rectangle().fill(Theme.orange).frame(height: 3)
                    .opacity(recording ? 1 : 0.35 + 0.65 * (level ?? 1))
            }
            if recording {
                Text(String(format: "● %.1f s", recSeconds))
                    .font(Deck05.font(7.5, 700))
                    .foregroundStyle(Theme.orange)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 7).padding(.top, 7)
            }
            if padStyle == "records" {
                RecordPad(category: category, bank: bank, active: spinning || lit)
                    .padding(.horizontal, 18).padding(.top, 19).padding(.bottom, 23)
                Text("CR-\(100 + number)")
                    .font(Theme.mono(6)).foregroundStyle(PadFinish.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(6)
            }
            Text("\(number)")
                .font(Deck05.font(6.5, 500))
                .foregroundStyle(PadFinish.muted.opacity(0.45))
                .padding(.leading, 7)
                .padding(.top, 7)
            if let p = params, !p.isDefault, !recording {
                PadEditMarks(params: p, tint: barColor ?? PadFinish.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 7)
                    .padding(.top, padStyle == "records" ? 17 : 6)
                    .offset(nameOffset)
                    .opacity(nameOpacity)
            }
            // Keyboard legends are intentionally not drawn (keyboard control still works); `shortcut` kept for API.
            Text(name ?? placeholder ?? "")
                .font(Deck05.font(nameSize, 500))
                .tracking(nameSize * 0.03)
                .foregroundStyle(name == nil ? PadFinish.muted.opacity(0.7) : PadFinish.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(7)
                .offset(nameOffset)
                .opacity(nameOpacity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4.5))
        .overlay(
            RoundedRectangle(cornerRadius: 4.5)
                .strokeBorder(recording ? Theme.orange : (selected && !lit ? PadFinish.muted : PadFinish.seam), lineWidth: 1)
        )
        .overlay {
            if armed {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    RoundedRectangle(cornerRadius: 4.5)
                        .strokeBorder(Theme.orange, lineWidth: 1.5)
                        .opacity(Int(ctx.date.timeIntervalSinceReferenceDate / 0.5) % 2 == 0 ? 0.9 : 0.15)
                }
                .allowsHitTesting(false)
            }
        }
    }
}
