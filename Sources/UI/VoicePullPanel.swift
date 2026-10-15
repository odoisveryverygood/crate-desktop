import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Pull-to-talk panel (`VoiceDig`): rises from the bottom of the screen with the drag on a pad or BANK key.
/// No mic icon: a thin line at the bottom builds with the pull (thicker, brighter, starting to move); past the
/// threshold it wakes (haptic + bloom) into the live waveform of the mic, with the words big above it and the target
/// tag. Let go = it collapses into "A3 ← words" and drops away. While it's up, a tap anywhere (or a swipe down)
/// closes it, unless the pull's own finger is still down.
struct VoicePullPanel: View {
    let state: AppState

    /// Extra panel below the screen edge, so the rubber band never shows a gap.
    private static let bleed: CGFloat = 48

    var body: some View {
        let v = VoiceDig.shared
        GeometryReader { g in
            let ins = DeviceInfo.windowEdgeInsets
            let side = max(ins.leading, ins.trailing)
            let width = max(0, min(g.size.width - 2 * side, 560))
            let compact = v.face == .sent
            let content = compact ? 66 : Self.fullHeight(g.size)
            let h = content + ins.bottom
            let reveal = Self.reveal(v)
            ZStack(alignment: .bottom) {
                if v.phase != .idle {
                    // tap (or swipe) anywhere = close; ignored while the pull's finger is still down
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded { _ in VoiceDig.shared.tapOutside() })
                        .accessibilityElement()
                        .accessibilityLabel("Close voice")
                        .accessibilityIdentifier("voice-dismiss")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { VoiceDig.shared.tapOutside() }
                }
                // The sheet grows from the bottom edge with the pull and its content is pinned to the bottom, so the
                // line (lowest) shows from the first points of the drag; the words above come into view as it opens.
                let shape = UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                VoicePanelContent(state: state, height: content)
                    .frame(width: width, height: h + Self.bleed, alignment: .top)
                    .frame(width: width, height: max(0, h * reveal) + Self.bleed, alignment: .bottom)
                    .background(Color(white: 0.055))
                    .mask { shape }
                    .overlay { shape.strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5) }
                    .background {
                        shape.fill(Color.black)
                            .shadow(color: .black.opacity(reveal > 0.01 ? 0.3 : 0), radius: 14, y: -2)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { _ in VoiceDig.shared.tapOutside() })
                    .offset(y: Self.bleed)
                    .opacity(reveal > 0.001 ? 1 : 0)
                    .animation(v.pulling ? .interactiveSpring(response: 0.12, dampingFraction: 0.9)
                                         : .spring(response: 0.4, dampingFraction: 0.82), value: reveal)
                    .animation(.spring(response: 0.36, dampingFraction: 0.86), value: compact)
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(v.phase != .idle)
        .accessibilityHidden(v.phase == .idle)
        .onChange(of: state.isDigging) { was, now in
            if was, !now { VoiceDig.shared.digFinished() }
        }
    }

    /// The open panel's height above the home indicator.
    static func fullHeight(_ size: CGSize) -> CGFloat {
        min(204, max(170, size.height * 0.22))
    }

    /// 0 = hidden, 1 = open. Eased so the first points of the pull already show the line, and rubber-banded past
    /// the threshold.
    static func reveal(_ v: VoiceDig) -> Double {
        switch v.phase {
        case .idle: return 0
        case .pulling, .listening, .cancelling:
            let p = v.progress
            return p <= 1 ? 1 - pow(1 - p, 1.6) : 1 + 0.08 * (1 - exp(-(p - 1) * 2.4))
        default: return 1
        }
    }
}

/// What the panel shows for each phase.
private struct VoicePanelContent: View {
    let state: AppState
    let height: CGFloat

    var body: some View {
        let v = VoiceDig.shared
        Group {
            if v.face == .sent { sentRow(v) } else { full(v) }
        }
        .frame(height: height, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("voice-panel")
    }

    // MARK: Open

    private func full(_ v: VoiceDig) -> some View {
        let p = min(1, v.progress)
        let awake = v.face == .listening || v.face == .finishing
        return VStack(spacing: 0) {
            Capsule().fill(Color.white.opacity(0.14)).frame(width: 34, height: 4).padding(.top, 8)
            Group {
                if let t = v.target {
                    VoiceTag(target: t, arrow: true)
                        .opacity(awake ? 1 : v.face == .cancelling ? 0.4 : 0.25 + 0.5 * p)
                        .scaleEffect(awake ? 1 : 0.92 + 0.08 * p)
                }
            }
            .frame(height: 18).padding(.top, 12)
            words(v, p: p)
                .frame(height: height < 190 ? 52 : 62)
                .padding(.horizontal, 24).padding(.top, 6)
            Spacer(minLength: 0)
            Text(v.face == .cancelling ? "LET GO TO CANCEL" : v.face == .listening ? "LET GO TO SEND" : " ")
                .font(Theme.inter(8, 600)).tracking(1.2)
                .foregroundStyle(Theme.lidGrey2)
                .frame(height: 12)
            VoiceWave()
                .frame(height: 50)
                .padding(.horizontal, 18)
                .padding(.bottom, 2)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.18), value: v.face)
    }

    @ViewBuilder
    private func words(_ v: VoiceDig, p: Double) -> some View {
        switch v.face {
        case .pulling:
            faint(v.target.map(Self.ask) ?? "", size: 17)
                .opacity(max(0, (p - 0.7) / 0.3))   // only once the sheet has risen past it
        case .listening, .finishing, .cancelling:
            if v.transcript.isEmpty {
                faint(v.face == .cancelling ? "nothing sent" : "listening…", size: 20)
            } else {
                Text(v.transcript + (v.face == .finishing ? "…" : ""))
                    .font(Theme.inter(28, 600)).tracking(-0.3)
                    .foregroundStyle(Theme.lidInk.opacity(v.face == .cancelling ? 0.3 : 1))
                    .multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.55).truncationMode(.head)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("voice-transcript")
            }
        default:
            Color.clear
        }
    }

    /// "say a sound for A3" / "say what bank B should play".
    private static func ask(_ t: VoiceDig.Target) -> String {
        switch t {
        case .pad(let p): return "say a sound for \(p.key)"
        case .bank(let b): return "say what bank \(b.letter) should play"
        }
    }

    // MARK: Sent (collapsed)

    private func sentRow(_ v: VoiceDig) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.live).frame(width: 7, height: 7)
            if let t = v.sent?.target ?? v.target { VoiceTag(target: t, arrow: true) }
            Text("“\(v.sent?.text ?? v.transcript)”")
                .font(Theme.inter(15, 600)).foregroundStyle(Theme.lidInk)
                .lineLimit(1).truncationMode(.tail)
                .accessibilityIdentifier("voice-panel-sent")
            Spacer(minLength: 6)
            if state.isDigging { DotSpinner(color: Theme.live, dot: 2.5) }
        }
        .padding(.horizontal, 22)
        .frame(maxHeight: .infinity)
    }

    // MARK: Bits

    private func faint(_ s: String, size: CGFloat, color: Color = Theme.lidGrey2) -> some View {
        Text(s).font(Theme.inter(size, 500)).foregroundStyle(color)
            .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The "about to listen" line. Pulling: a thin dim line in the middle that grows wider, thicker, brighter and starts
/// to undulate with the pull, warming from white to orange. Crossing the threshold: a quick bloom. Listening: the
/// mic level drives a live three-layer waveform. Cancelling: it greys and settles. Finishing: it pulls into the
/// centre. One Canvas, a few strokes per frame.
struct VoiceWave: View {
    @State private var smooth = Smoother()

    final class Smoother { var level = 0.0; var amp = 0.0; var last = Date() }

    var body: some View {
        // paused while the panel is closed: nothing draws when it isn't up
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: VoiceDig.shared.phase == .idle)) { ctx in
            Canvas { gc, size in
                draw(&gc, size, now: ctx.date)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ gc: inout GraphicsContext, _ size: CGSize, now: Date) {
        let v = VoiceDig.shared
        let t = now.timeIntervalSinceReferenceDate
        let face = v.face
        let p = min(1, max(0, v.progress))
        let dt = min(0.05, now.timeIntervalSince(smooth.last))
        smooth.last = now

        // target shape for this phase
        var amp: Double, thick: Double, span: Double, speed: Double, alpha: Double, warm: Double
        switch face {
        case .pulling:
            amp = 0.5 + 9 * p * p
            thick = 1 + 1.4 * p
            span = 0.22 + 0.78 * p
            speed = 1.2 + 3.2 * p
            alpha = 0.2 + 0.7 * p
            warm = pow(p, 1.4)
        case .listening:
            let raw = v.level
            smooth.level += (raw - smooth.level) * (raw > smooth.level ? 0.4 : 0.12)
            amp = 4 + 22 * smooth.level
            thick = 2.2
            span = 1
            speed = 5
            alpha = 1
            warm = 1
        case .cancelling:
            amp = 1.5
            thick = 1.4
            span = 0.7
            speed = 1.5
            alpha = 0.45
            warm = 0
        case .finishing, .sent:
            amp = 1
            thick = 2
            span = 0.12
            speed = 3
            alpha = 0.9
            warm = 1
        default:
            amp = 0; thick = 1; span = 0.2; speed = 1; alpha = 0; warm = 0
        }
        // ease the amplitude so phase changes glide instead of jumping
        smooth.amp += (amp - smooth.amp) * min(1, dt * 14)
        amp = smooth.amp

        let w = Double(size.width), mid = Double(size.height) / 2
        let width = w * span
        let x0 = (w - width) / 2
        let n = 64
        var path = Path()
        for i in 0...n {
            let x = Double(i) / Double(n)
            let env = pow(sin(.pi * x), 1.5)
            let y = 0.6 * sin(2 * .pi * 1.5 * x - speed * t)
                + 0.28 * sin(2 * .pi * 3.2 * x + 1.3 * speed * t)
                + 0.12 * sin(2 * .pi * 5.7 * x - 0.7 * speed * t)
            let pt = CGPoint(x: x0 + width * x, y: mid + amp * env * y)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        let orange = Theme.live
        let cool = face == .cancelling ? Theme.lidGrey1 : Color.white

        // bloom: a quick bright, wide flash when the mic wakes
        var bloom = 0.0
        if let woke = v.wokeAt, face == .listening || face == .finishing {
            let k = now.timeIntervalSince(woke)
            if k < 0.6 { bloom = pow(1 - k / 0.6, 2) }
        }
        // soft glow (two wide strokes, no blur)
        let glow = (face == .listening ? 0.16 : 0.1 * warm) + 0.35 * bloom
        if glow > 0.01 {
            gc.stroke(path, with: .color(orange.opacity(glow * 0.5)),
                      style: StrokeStyle(lineWidth: thick + 14 + 18 * bloom, lineCap: .round, lineJoin: .round))
            gc.stroke(path, with: .color(orange.opacity(glow)),
                      style: StrokeStyle(lineWidth: thick + 5 + 6 * bloom, lineCap: .round, lineJoin: .round))
        }
        // a second, thinner layer out of phase while listening: reads as a voice, not a sine
        if face == .listening {
            var echo = Path()
            for i in 0...n {
                let x = Double(i) / Double(n)
                let env = pow(sin(.pi * x), 2)
                let y = sin(2 * .pi * 2.3 * x + 1.7 * speed * t) * 0.7 + sin(2 * .pi * 4.1 * x - speed * t) * 0.3
                let pt = CGPoint(x: x0 + width * x, y: mid - amp * 0.65 * env * y)
                if i == 0 { echo.move(to: pt) } else { echo.addLine(to: pt) }
            }
            gc.stroke(echo, with: .color(orange.opacity(0.4)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
        if warm < 1 {
            gc.stroke(path, with: .color(cool.opacity(alpha * (1 - warm))),
                      style: StrokeStyle(lineWidth: thick, lineCap: .round, lineJoin: .round))
        }
        if warm > 0 {
            gc.stroke(path, with: .color((bloom > 0 ? Color.white : orange).opacity(bloom * 0.6)),
                      style: StrokeStyle(lineWidth: thick + 1, lineCap: .round, lineJoin: .round))
            gc.stroke(path, with: .color(orange.opacity(alpha * warm)),
                      style: StrokeStyle(lineWidth: thick, lineCap: .round, lineJoin: .round))
        }
    }
}

/// "A3 ←" in the target's bank colour.
struct VoiceTag: View {
    let target: VoiceDig.Target
    var arrow = false

    var body: some View {
        let color = target.pad.map { Theme.bank($0.bank) } ?? target.bank.map { Theme.bank($0) } ?? Theme.live
        Text(target.label + (arrow ? " ←" : ""))
            .font(Theme.inter(9, 700)).tracking(0.5)
            .foregroundStyle(Color.black)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 3.5).fill(color))
            .fixedSize()
    }
}

/// On a pad / BANK key while it's being pulled: a small ring with a down chevron; the ring fills with the pull.
struct VoicePullMark: View {
    /// Pull progress; ≥ 1 = listening.
    let progress: Double
    var size: CGFloat = 18
    var ink: Color = PadFinish.ink

    var body: some View {
        let live = progress >= 1
        ZStack {
            Circle().fill(live ? Theme.live : PadFinish.key)
            Circle().stroke(ink.opacity(0.14), lineWidth: 1.5)
            Circle().trim(from: 0, to: min(1, progress))
                .stroke(Theme.live, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "chevron.down")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(live ? Color.black : ink)
                .offset(y: size * 0.03)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
