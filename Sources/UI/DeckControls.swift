import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Direction 05 (COLOUR-CODED) deck palette

/// Deck tokens from `design/directions/05-colour.html` (kept local until Theme grows the Field palette).
/// Rule: a colour is a bank, never a state. State is monochrome: an inverted (black) key is ON.
/// Orange appears only for live state (REC armed, DIG digging, the fader's cap line, pressed pads).
enum Deck05 {
    static func hex(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255, opacity: 1)
    }

    static let alu = hex(0xE0E1DE)      // --alu   pale aluminium body
    static let key = hex(0xF7F7F5)      // --key   white key
    static let keyDown = hex(0xEAEAE6)  // --keyd
    static let seam = hex(0xC3C4C0)     // --seam  0.5 pt key ring
    static let ink = hex(0x131313)      // --ink
    static let ink2 = hex(0x6A6B67)     // --ink2  printed labels
    static let ink3 = hex(0xA2A39E)     // --ink3
    static let slot = hex(0xC6C7C3)     // fader slot
    static let grille = hex(0xBCBDB9)   // speaker-grille dots
    static let live = hex(0xFA5B1C)     // orange = live only

    static let bankA = hex(0xFA5B1C)    // drums
    static let bankB = hex(0x5B8DEF)    // chops
    static let bankC = hex(0xE0A92E)    // bass · keys
    static let bankD = hex(0xAFAFB3)    // free
    static func bank(_ b: Bank) -> Color { [bankA, bankB, bankC, bankD][b.rawValue] }

    static let radius: CGFloat = 4

    /// Inter at a fixed size (Dynamic Type never reflows the hardware). ≥ 700 uses the system face (no Inter Bold bundled).
    static func font(_ size: CGFloat, _ weight: Int = 600) -> Font {
        switch weight {
        case ..<350: return .custom("Inter-Light", fixedSize: size)
        case ..<450: return .custom("Inter-Regular", fixedSize: size)
        case ..<550: return .custom("Inter-Medium", fixedSize: size)
        case ..<650: return .custom("Inter-SemiBold", fixedSize: size)
        default: return .system(size: size, weight: weight >= 800 ? .heavy : .bold)
        }
    }
}

/// Printed small-caps label on the aluminium (`.lbl` in the mock: 600 6.5 px, tracking .14 em).
struct DeckLabel: View {
    let text: String
    var size: CGFloat = 6.5
    var weight = 600
    var tracking: CGFloat = 0.14
    var color: Color = Deck05.ink2

    init(_ text: String, size: CGFloat = 6.5, weight: Int = 600, tracking: CGFloat = 0.14, color: Color = Deck05.ink2) {
        self.text = text
        self.size = size
        self.weight = weight
        self.tracking = tracking
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(Deck05.font(size, weight))
            .tracking(size * tracking)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A key cap: white with a 0.5 pt seam ring, or inverted ink when ON.
struct KeyFace: View {
    var on = false
    var radius: CGFloat = Deck05.radius
    var fill: Color? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(fill ?? (on ? Deck05.ink : Deck05.key))
            .overlay(shape.stroke(fill ?? (on ? Deck05.ink : Deck05.seam), lineWidth: 0.5))
    }
}

/// Cool pale-aluminium body with a subtle grain (the mock's 6 % fractal-noise overlay).
struct DeckSurface: View {
    var body: some View {
        ZStack {
            Deck05.alu
            grainImage
                .resizable(resizingMode: .tile)
                .opacity(0.06)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 96×96 px tile of black noise (alpha ≈ 0…0.9, triangular), built once.
    #if os(iOS)
    private var grainImage: Image { Image(uiImage: Self.grain) }
    #else
    private var grainImage: Image { Image(nsImage: Self.grain) }
    #endif

    static let grain: CratePlatformImage = {
        let n = 96
        var px = [UInt8](repeating: 0, count: n * n * 4)
        var s: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in 0..<(n * n) {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            let a = (Double(s & 0xFF) + Double((s >> 8) & 0xFF)) / 2 * 0.9
            px[i * 4 + 3] = UInt8(a)
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return CratePlatformImage() }
        #if os(iOS)
        return UIImage(cgImage: cg, scale: 2, orientation: .up)
        #else
        return NSImage(cgImage: cg, size: NSSize(width: 48, height: 48))
        #endif
    }()
}

// MARK: - Keys

/// Text key (OCT −, OCT +, SCALE, PAD FX LATCH): white key, caps label; ON = inverted ink.
struct DeckButton: View {
    let label: String
    var on = false
    /// Kept for callers; in 05 toggles and modes share the same monochrome ON state.
    var toggle = false
    var accent = false
    var id: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                KeyFace(on: on)
                Text(label)
                    .font(Deck05.font(7.2, 600))
                    .tracking(7.2 * 0.12)
                    .foregroundStyle(on ? Deck05.key : (accent ? Deck05.live : Deck05.ink))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ChassisPressStyle())
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Flat press feedback: a quick darken, no scale, no shadow.
struct ChassisPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.linear(duration: 0.08), value: configuration.isPressed)
    }
}

/// The mode pictograms, ported from the mock's 12×12 SVG icons.
enum ModeGlyph {
    case sample, chop, keys, seq, padFX, levels, shift, mic

    init(_ mode: Mode) {
        switch mode {
        case .sample: self = .sample
        case .chop: self = .chop
        case .keys: self = .keys
        case .seq: self = .seq
        case .padFX: self = .padFX
        case .levels16: self = .levels
        }
    }
}

struct ModeGlyphView: View {
    let glyph: ModeGlyph
    var color: Color = Deck05.ink
    var size: CGFloat = 12

    var body: some View {
        Canvas { ctx, box in
            let s = size / 12
            ctx.translateBy(x: (box.width - size) / 2, y: (box.height - size) / 2)
            ctx.scaleBy(x: s, y: s)
            let line = StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
            let ink = GraphicsContext.Shading.color(color)
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
            func poly(_ pts: [(CGFloat, CGFloat)]) -> Path {
                var p = Path()
                p.addLines(pts.map { pt($0.0, $0.1) })
                p.closeSubpath()
                return p
            }
            switch glyph {
            case .sample:
                var p = Path()
                p.move(to: pt(0, 6))
                p.addCurve(to: pt(4, 6), control1: pt(1.5, 0.5), control2: pt(3, 0.5))
                p.addCurve(to: pt(8, 6), control1: pt(5, 11.5), control2: pt(6.5, 11.5))
                p.addCurve(to: pt(12, 6), control1: pt(9.5, 0.5), control2: pt(10.5, 1.5))
                ctx.stroke(p, with: ink, style: line)
            case .chop:
                var p = Path()
                p.addEllipse(in: CGRect(x: 3 - 1.9, y: 9.3 - 1.9, width: 3.8, height: 3.8))
                p.addEllipse(in: CGRect(x: 9 - 1.9, y: 9.3 - 1.9, width: 3.8, height: 3.8))
                p.move(to: pt(4.3, 7.9)); p.addLine(to: pt(10, 0.7))
                p.move(to: pt(7.7, 7.9)); p.addLine(to: pt(2, 0.7))
                ctx.stroke(p, with: ink, style: line)
            case .keys:
                var p = Path(CGRect(x: 0.5, y: 1.5, width: 11, height: 9))
                p.move(to: pt(4, 6.5)); p.addLine(to: pt(4, 10.5))
                p.move(to: pt(8, 6.5)); p.addLine(to: pt(8, 10.5))
                ctx.stroke(p, with: ink, style: line)
                ctx.fill(Path(CGRect(x: 2.9, y: 1.5, width: 2.2, height: 5)), with: ink)
                ctx.fill(Path(CGRect(x: 6.9, y: 1.5, width: 2.2, height: 5)), with: ink)
            case .seq:
                for (r, row) in ["X.X.", ".X..", "X..X"].enumerated() {
                    for (c, ch) in row.enumerated() {
                        let rad: CGFloat = ch == "X" ? 1.35 : 0.55
                        let x = 1.5 + CGFloat(c) * 3, y = 2 + CGFloat(r) * 4
                        ctx.fill(Path(ellipseIn: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2)), with: ink)
                    }
                }
            case .padFX:
                ctx.stroke(poly([(6, 0.5), (7.3, 4.3), (11.2, 3.2), (8.6, 6.1), (11.2, 9), (7.3, 7.9),
                                 (6, 11.6), (4.7, 7.9), (0.8, 9), (3.4, 6.1), (0.8, 3.2), (4.7, 4.3)]),
                           with: ink, style: line)
            case .levels:
                var p = Path()
                for (x, top) in [(1.5, 9.5), (4.5, 7.5), (7.5, 5.0), (10.5, 1.5)] as [(CGFloat, CGFloat)] {
                    p.move(to: pt(x, 11.5)); p.addLine(to: pt(x, top))
                }
                ctx.stroke(p, with: ink, style: StrokeStyle(lineWidth: 1.6))
            case .shift:
                ctx.stroke(poly([(6, 0.8), (11.2, 6.3), (8.3, 6.3), (8.3, 11.2), (3.7, 11.2), (3.7, 6.3), (0.8, 6.3)]),
                           with: ink, style: line)
            case .mic:
                ctx.stroke(Path(roundedRect: CGRect(x: 4, y: 0.8, width: 4, height: 6.6), cornerRadius: 2), with: ink, style: line)
                var p = Path()
                p.move(to: pt(2.3, 5.6))
                p.addQuadCurve(to: pt(9.7, 5.6), control: pt(6, 12.6))
                p.move(to: pt(6, 9.3)); p.addLine(to: pt(6, 11.3))
                ctx.stroke(p, with: ink, style: line)
            }
        }
        .frame(width: size + 3, height: size + 3)
        .accessibilityHidden(true)
    }
}

/// Mode key: white rounded-square pictogram key (black with a white glyph when active) + small caps label,
/// beside the key (landscape column) or under it (portrait / KEYS rows).
struct ModeKey: View {
    let glyph: ModeGlyph
    let label: String
    var on = false
    var key: CGFloat = 26
    var labelBelow = false
    /// A blinking orange dot on the key (SAMPLE armed: live state).
    var live = false
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if labelBelow {
                    VStack(spacing: 5) {
                        face
                        DeckLabel(label, size: 7.2, tracking: 0.1, color: on ? Deck05.ink : Deck05.ink2)
                    }
                } else {
                    HStack(spacing: 9) {
                        face
                        DeckLabel(label, size: 7.5, tracking: 0.1, color: on ? Deck05.ink : Deck05.ink2)
                        Spacer(minLength: 0)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ChassisPressStyle())
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var face: some View {
        ZStack {
            KeyFace(on: on)
            ModeGlyphView(glyph: glyph, color: on ? Deck05.key : Deck05.ink, size: (key * 12 / 26).rounded())
            if live {
                TimelineView(.periodic(from: .now, by: 0.4)) { ctx in
                    Circle().fill(Deck05.live)
                        .frame(width: 5, height: 5)
                        .opacity(Int(ctx.date.timeIntervalSinceReferenceDate / 0.4) % 2 == 0 ? 1 : 0.15)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(3)
            }
        }
        .frame(width: key, height: key)
    }
}

/// FX key: hold it and the pads become the effects (tap one to pick it); a quick tap latches them for one pick.
struct FXHoldKey: View {
    var key: CGFloat = 26
    var labelBelow = false
    @State private var pressing = false

    var body: some View {
        let ui = CrateUI.shared
        let on = ui.fxLayer
        Group {
            if labelBelow {
                VStack(spacing: 5) {
                    face(on)
                    DeckLabel("FX", size: 7.2, tracking: 0.1, color: on ? Deck05.ink : Deck05.ink2)
                }
            } else {
                HStack(spacing: 9) {
                    face(on)
                    DeckLabel("FX", size: 7.5, tracking: 0.1, color: on ? Deck05.ink : Deck05.ink2)
                    Spacer(minLength: 0)
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing else { return }
                    pressing = true
                    ui.fxDown()
                }
                .onEnded { _ in
                    pressing = false
                    ui.fxUp()
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("mode-fx")
        .accessibilityLabel("FX")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityAction { ui.fxLatched.toggle() }
    }

    private func face(_ on: Bool) -> some View {
        ZStack {
            KeyFace(on: on)
            ModeGlyphView(glyph: .padFX, color: on ? Deck05.key : Deck05.ink, size: (key * 12 / 26).rounded())
        }
        .frame(width: key, height: key)
        .brightness(pressing ? -0.08 : 0)
    }
}

// MARK: - Banks

/// BANK A–D: round knob-style keys, each with its bank's colour dot; the selected one inverted black.
/// Tap = that bank (MUTE layer: mute / unmute the whole bank). Drag down = talk to the bank (pull-to-talk).
struct BankGrid: View {
    let state: AppState
    var key: CGFloat = 21
    var spacing: CGFloat = 6

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Bank.allCases, id: \.self) { b in
                BankButton(bank: b, selected: state.bank == b, key: key, mute: state.bankMute(b),
                           voice: VoiceDig.shared.mark(bank: b), action: {
                    let ui = CrateUI.shared
                    if ui.muteLayer {
                        state.toggleMute(bank: b)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } else {
                        ui.selectBank(b, state)
                    }
                }, pullBegan: { y in
                    guard VoiceDig.allowed(state) else { return false }
                    CrateUI.shared.selectBank(b, state)
                    return VoiceDig.shared.pullBegan(.bank(b), threshold: VoiceDig.threshold(touchY: y), state: state)
                }, pullMoved: { dy in
                    VoiceDig.shared.pullMoved(dy)
                }, pullEnded: {
                    VoiceDig.shared.pullEnded(state: state)
                })
            }
        }
    }
}

struct BankButton: View {
    let bank: Bank
    let selected: Bool
    var key: CGFloat = 21
    /// MUTE: some pads muted = a hollow dot; the whole bank = hollow dot + strike.
    var mute: BankMute = .none
    /// Pull-to-talk progress on this key (nil = none, ≥ 1 = listening).
    var voice: Double? = nil
    var action: () -> Void
    /// The finger slid down (y = where it went down, in the window); true = it's a voice pull now, and the release
    /// calls `pullEnded` instead of `action`.
    var pullBegan: (CGFloat) -> Bool = { _ in false }
    var pullMoved: (CGFloat) -> Void = { _ in }
    var pullEnded: () -> Void = {}

    @State private var pressing = false
    @State private var pulling = false
    /// Resets when the gesture ends or is cancelled (a system alert), so a cancelled pull still lets go.
    @GestureState private var touching = false

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle().fill(selected ? Deck05.ink : Deck05.key)
                Circle().stroke(selected ? Deck05.ink : Deck05.seam, lineWidth: 0.5)
                let d = key * 6 / 21
                if voice != nil {
                    // being pulled down to talk: a down chevron in place of the dot, the ring around the key fills
                    Image(systemName: "chevron.down")
                        .font(.system(size: key * 0.36, weight: .bold))
                        .foregroundStyle(Deck05.bank(bank))
                        .offset(y: key * 0.03)
                } else if mute == .none {
                    Circle().fill(Deck05.bank(bank)).frame(width: d, height: d)
                } else {
                    Circle().stroke(Deck05.bank(bank), lineWidth: 1.4).frame(width: d + 1, height: d + 1)
                }
                if mute == .all {
                    Path { p in
                        p.move(to: CGPoint(x: key * 0.24, y: key * 0.76))
                        p.addLine(to: CGPoint(x: key * 0.76, y: key * 0.24))
                    }
                    .stroke(selected ? Deck05.key : Deck05.ink, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                }
                if let p = voice, p < 1 {
                    Circle().trim(from: 0, to: p)
                        .stroke(Deck05.live, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(-4)
                } else if voice != nil {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                        let k = 0.5 + 0.5 * sin(ctx.date.timeIntervalSinceReferenceDate * 2 * .pi * 1.6)
                        Circle().stroke(Deck05.live, lineWidth: 2 + 1.5 * k)
                            .padding(-3 - 2 * k)
                            .opacity(0.55 + 0.45 * k)
                    }
                }
            }
            .frame(width: key, height: key)
            .brightness(pressing ? -0.08 : 0)
            Text(bank.letter)
                .font(Deck05.font(8.5, 600))
                .foregroundStyle(selected ? Deck05.ink : Deck05.ink2)
        }
        .contentShape(Rectangle().inset(by: -3))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .updating($touching) { _, t, _ in t = true }
                .onChanged { v in
                    if !pressing { pressing = true }
                    let dx = v.translation.width, dy = v.translation.height
                    // drag down (mostly down) = pull-to-talk; a quick tap still switches banks
                    if !pulling, dy > VoiceDig.pullStart, dy > abs(dx) * 1.4 { pulling = pullBegan(v.startLocation.y) }
                    if pulling { pullMoved(dy) }
                }
                .onEnded { v in
                    let wasPulling = pulling
                    pressing = false
                    pulling = false
                    if wasPulling { pullEnded() }
                    else if hypot(v.translation.width, v.translation.height) < 30 { action() }
                }
        )
        .onChange(of: touching) { _, t in
            guard !t, pressing else { return }
            // cancelled without an end (a system alert took the touch)
            pressing = false
            if pulling { pulling = false; pullEnded() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("bank-\(bank.letter)")
        .accessibilityLabel("Bank \(bank.letter)" + (mute == .all ? ", muted" : mute == .some ? ", some pads muted" : ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction { action() }
    }
}

// MARK: - Fader

/// Vertical fader with a printed scale (dB for LEVEL), a slim slot and a white cap with an orange line.
/// `fill` adds an orange live column under the cap (PUNCH).
struct FaderView: View {
    var value: Double
    var fill = false
    var id = "level-fader"
    var marks: [String] = []   // LEVEL: no printed scale, just the track + cap
    var onChange: (Double) -> Void
    var onEnd: ((Double) -> Void)? = nil

    static let dbMarks = ["0", "", "−6", "", "−12", "", "−24", "", "−∞"]
    static let percentMarks = ["100", "", "75", "", "50", "", "25", "", "0"]

    var body: some View {
        GeometryReader { g in
            let capH: CGFloat = 16
            let top = capH / 2
            let travel = max(1, g.size.height - capH)
            let v = min(1, max(0, value))
            let capY = top + (1 - v) * travel
            // mock: labels end at x 26, ticks end at 43, cap 36 wide from x 44 (slot centre 62)
            let scaleW: CGFloat = marks.isEmpty ? 0 : 44
            let capW = min(36, max(22, g.size.width - scaleW - 4))
            let cx = scaleW + capW / 2
            ZStack(alignment: .topLeading) {
                ForEach(0..<marks.count, id: \.self) { i in
                    let y = top + CGFloat(i) * travel / CGFloat(max(1, marks.count - 1))
                    let major = !marks[i].isEmpty
                    if major {
                        Text(marks[i])
                            .font(Deck05.font(6, 500))
                            .monospacedDigit()
                            .foregroundStyle(Deck05.ink2)
                            .fixedSize()
                            .frame(width: 24, alignment: .trailing)
                            .position(x: 14, y: y)
                    }
                    Rectangle().fill(major ? Deck05.ink : Deck05.ink2)
                        .frame(width: major ? 12 : 8, height: 0.5)
                        .position(x: 43 - (major ? 6 : 4), y: y)
                }
                RoundedRectangle(cornerRadius: 1).fill(Deck05.slot)
                    .frame(width: marks.isEmpty ? 2 : 3, height: travel + 2)
                    .position(x: cx, y: top + (travel + 2) / 2)
                if fill {
                    let h = max(0, top + travel + 2 - capY)
                    Rectangle().fill(Deck05.live)
                        .frame(width: 3, height: h)
                        .position(x: cx, y: capY + h / 2)
                }
                ZStack {
                    KeyFace(radius: 3)
                    Rectangle().fill(Deck05.live).frame(height: 1.5).padding(.horizontal, 6)
                }
                .frame(width: capW, height: capH)
                .position(x: cx, y: capY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { d in
                        onChange(Double(min(1, max(0, 1 - (d.location.y - top) / travel))))
                    }
                    .onEnded { d in
                        onEnd?(Double(min(1, max(0, 1 - (d.location.y - top) / travel))))
                    }
            )
        }
        .accessibilityElement()
        .accessibilityIdentifier(id)
        .accessibilityValue("\(Int((min(1, max(0, value))) * 100)) percent")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: onChange(min(1, value + 0.1))
            case .decrement: onChange(max(0, value - 0.1))
            @unknown default: break
            }
        }
    }
}

// MARK: - Transport

/// REC and PLAY / PAUSE rounded-square keys with printed captions. The play key turns black and shows ❚❚ while
/// anything runs (playback, a count-in, a hands-free take); tapping it then stops, and the next ▶ starts at bar 1.
/// The REC dot turns orange while recording. Polls the engine so it stays right if playback starts elsewhere.
struct TransportRow: View {
    let state: AppState
    /// Key size (the mock's 30 pt).
    var height: CGFloat = 30
    var captions = true

    /// Gap between the two keys' hit areas (each is at least 44 pt wide, so the drawn gap is bigger).
    static func gap(_ height: CGFloat) -> CGFloat { height >= 44 ? (height * 0.3).rounded() : 4 }
    /// Width of the row for a key size (two keys and the gap).
    static func width(_ height: CGFloat) -> CGFloat { max(44, height) * 2 + gap(height) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let ui = CrateUI.shared
            let running = ui.transportRunning(state)
            let s = height / 30
            HStack(alignment: .top, spacing: 0) {
                let counting = ui.countIn != nil
                let blink = counting && Int(Date().timeIntervalSinceReferenceDate / 0.2) % 2 == 0
                transportKey(id: "rec", caption: "REC", label: "Record", lit: state.isRecording || counting, inverted: false) {
                    Circle().fill(state.isRecording || blink ? Deck05.live : Deck05.ink)
                        .frame(width: 9 * s, height: 9 * s)
                } action: {
                    ui.recPressed(state)
                }
                // a wider slot (portrait column, landscape rail) spreads the two keys to its edges
                Spacer(minLength: Self.gap(height))
                transportKey(id: "play", caption: running ? "PAUSE" : "PLAY", label: running ? "Pause" : "Play",
                             lit: running, inverted: running) {
                    if running {
                        HStack(spacing: 2.6 * s) {
                            Rectangle().frame(width: 2.6 * s, height: 9 * s)
                            Rectangle().frame(width: 2.6 * s, height: 9 * s)
                        }
                        .foregroundStyle(Deck05.key)
                    } else {
                        PlayShape().fill(Deck05.ink)
                            .frame(width: 8 * s, height: 9 * s)
                            .offset(x: 0.5 * s)
                    }
                } action: {
                    ui.playPausePressed(state)
                }
            }
        }
    }

    private func transportKey<G: View>(id: String, caption: String, label: String, lit: Bool, inverted: Bool,
                                       @ViewBuilder glyph: () -> G,
                                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    KeyFace(on: inverted)
                    glyph()
                }
                .frame(width: height, height: height)
                if captions {
                    // fixed width: PLAY ↔ PAUSE never shifts the row
                    DeckLabel(caption, size: 7.2, color: lit ? Deck05.ink : Deck05.ink2)
                        .frame(width: height)
                }
            }
            .frame(minWidth: 44, minHeight: 44)   // hit area ≥ 44 pt on the small phone keys
            .contentShape(Rectangle())
        }
        .buttonStyle(ChassisPressStyle())
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
        .accessibilityAddTraits(lit ? .isSelected : [])
    }
}

/// ✦ DIG: the wide black key; orange only while digging (live).
struct DigButton: View {
    let state: AppState
    var height: CGFloat = 44

    var body: some View {
        Button {
            CrateUI.shared.digPressed(state)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(state.isDigging ? Deck05.live : Deck05.ink)
                HStack(spacing: 7) {
                    SparkShape().fill(Deck05.key).frame(width: 10, height: 10)
                    Text("DIG")
                        .font(Deck05.font(8.5, 700))
                        .tracking(8.5 * 0.2)
                        .foregroundStyle(Deck05.key)
                }
                if state.isDigging {
                    DotSpinner(color: .white, dot: 2)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 8)
                }
            }
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChassisPressStyle())
        .accessibilityIdentifier("dig-button")
        .accessibilityLabel("Dig")
    }
}

/// Dot-matrix 3-dot spinner (each dot is a 3×3 matrix; one lights at a time).
struct DotSpinner: View {
    var color: Color = Theme.orange
    var dot: CGFloat = 2.5

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { ctx in
            let k = Int(ctx.date.timeIntervalSinceReferenceDate / 0.12) % 3
            HStack(spacing: dot * 2) {
                ForEach(0..<3, id: \.self) { i in
                    matrix(lit: i == k)
                }
            }
        }
        .accessibilityIdentifier("digging")
        .accessibilityLabel("Digging")
    }

    private func matrix(lit: Bool) -> some View {
        VStack(spacing: dot * 0.6) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: dot * 0.6) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(lit ? color : color.opacity(0.22)).frame(width: dot, height: dot)
                    }
                }
            }
        }
    }
}

// MARK: - Brand

/// "CRATE" wordmark over "CR-16 · AI SAMPLER" (or on one line when `inline`).
struct BrandMark: View {
    var inline = false

    var body: some View {
        if inline {
            HStack(alignment: .firstTextBaseline, spacing: 10) { word; sub }
                .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 5) { word; sub }
                .accessibilityElement(children: .combine)
        }
    }

    private var word: some View {
        Text("CRATE").font(Deck05.font(11, 800)).tracking(11 * 0.2).foregroundStyle(Deck05.ink).fixedSize()
    }

    private var sub: some View {
        DeckLabel("CR-16 · AI sampler", size: 6, weight: 500, tracking: 0.14)
    }
}

/// The printed speaker grille: 9 × 4 dots.
struct GrilleDots: View {
    var cols = 9
    var rows = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 4.2) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: 4.2) {
                    ForEach(0..<cols, id: \.self) { _ in
                        Circle().fill(Deck05.grille).frame(width: 2.4, height: 2.4)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}
