import SwiftUI

/// CRATE / CR-16 design tokens (Teenage Engineering look). Flat, no shadows, radius 4–6, animations ≤ 100 ms linear.
enum Theme {
    static func hex(_ v: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB,
              red: Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255,
              opacity: alpha)
    }

    // Chassis (deck)
    static let chassis = hex(0xC9C9CB)
    static let button = hex(0xE4E4E6)
    static let buttonBorder = hex(0x9D9DA2)
    static let silk = hex(0x16161D)
    static let pad = hex(0x2F2F36)
    static let padPressed = hex(0x3A3A42)
    static let padEdge = hex(0x484850)
    static let padLabel = hex(0xAFAFB3)
    static let whiteKey = hex(0xEDEDEF)
    static let whiteKeyOff = hex(0xD3D3D7)
    static let blackKeyOff = hex(0x24242A)

    // Display (lid)
    static let display = Color.black
    static let text = hex(0xF6F4F4)
    static let mid = hex(0x797982)
    static let dim = hex(0x484850)
    static let rule = hex(0x2F2F36)
    static let dotOff = hex(0x1C1C24)
    static let ghost = hex(0x5A5A64)

    // Accents
    static let orange = hex(0xFA5B1C)
    static let blue = hex(0x5B8DEF)
    static let ochre = hex(0xE0A92E)
    static let grey = hex(0xAFAFB3)
    static let red = hex(0xE5484D)

    // MARK: Direction 05 · COLOUR-CODED (exact values from design/directions/05-colour.html `:root`)
    // Rule: a colour is a bank, never a state. State is monochrome (an inverted key is ON); orange also marks live.

    // Lid · black OLED
    /// --oled
    static let oled = Color.black
    /// --w: lid ink (white type, hit dots, cursor, AI PERFORM chip fill)
    static let lidInk = hex(0xF5F5F3)
    /// --g1: lid secondary (caps labels, subtitles, timing values)
    static let lidGrey1 = hex(0x8E8E8E)
    /// --g2: lid tertiary (ruler numbers, separators)
    static let lidGrey2 = hex(0x5E5E5E)
    /// --g3: tracks (level bars, unlit loop segments)
    static let lidGrey3 = hex(0x2A2A2A)
    /// Played loop segment.
    static let lidDone = hex(0x6A6A6A)
    /// Rest dot in the step grid.
    static let lidRest = hex(0x3A3A3A)
    /// Ghost-note ring in the step grid.
    static let lidGhost = hex(0x9A9A9A)
    /// Rule above the prompt.
    static let lidRule = hex(0x262626)
    /// Timing-strip keys (JEV / KIT / SAMPLE / GPT).
    static let lidTimingKey = hex(0xC8C8C8)
    /// Prompt placeholder.
    static let lidPlaceholder = hex(0x5C5C5C)
    /// Outlined chip stroke / text.
    static let chipStroke = hex(0x4A4A4A)
    static let chipText = hex(0xD6D6D6)
    /// The fold gap between lid and deck.
    static let hingeGap = hex(0x0A0A0A)

    // Deck · pale aluminium, white keys, black ink
    /// --alu: deck background
    static let alu = hex(0xE0E1DE)
    /// --key: white keys and pads
    static let keyWhite = hex(0xF7F7F5)
    static let padWhite = keyWhite
    /// --keyd: pressed / playing pad fill
    static let keyDown = hex(0xEAEAE6)
    /// --seam: key outline
    static let seam = hex(0xC3C4C0)
    /// --ink: silk-screen ink, inverted (ON) keys
    static let ink = hex(0x131313)
    /// --ink2: secondary silk (captions, fader scale)
    static let ink2 = hex(0x6A6B67)
    /// --ink3: tertiary silk (pad numbers)
    static let ink3 = hex(0xA2A39E)
    static let faderSlot = hex(0xC6C7C3)
    static let grilleDot = hex(0xBCBDB9)

    // Banks: --A orange (drums) · --B blue (chops) · --C ochre (bass/keys) · --D grey (free)
    static let bankA = hex(0xFA5B1C)
    static let bankB = hex(0x3A76EE)
    static let bankC = hex(0xD9A12A)
    static let bankD = hex(0x9D9E9A)
    /// Live state (recording, punch, playing edge). Same orange as bank A.
    static let live = bankA

    static let radius: CGFloat = 4
    static let padRadius: CGFloat = 6
    /// Pad / key flash length (seconds).
    static let flash: Double = 0.1
    static let quick = Animation.linear(duration: 0.08)

    /// The bank's 05 colour (lane tabs, playhead, key dots, pressed-pad edge).
    static func bank(_ b: Bank) -> Color { [bankA, bankB, bankC, bankD][b.rawValue] }
    /// The bank's role, as printed in the lid's BANKS legend.
    static func bankName(_ b: Bank) -> String { ["DRUMS", "CHOPS", "BASS · KEYS", "FREE"][b.rawValue] }

    static func tint(_ t: Tint) -> Color {
        switch t {
        case .orange: return orange
        case .blue: return blue
        case .ochre: return ochre
        case .grey: return grey
        case .red: return red
        }
    }

    // Fonts (PostScript names; fixed size so Dynamic Type never reflows the hardware).
    static func doto(_ size: CGFloat) -> Font { .custom("Doto-Black", fixedSize: size) }
    static func label(_ size: CGFloat) -> Font { .custom("SpaceMono-Bold", fixedSize: size) }
    static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular", fixedSize: size)
    }

    /// Inter (bundled static TTFs) at CSS weight 300 / 400 / 500 / 600; other weights snap to the nearest.
    static func inter(_ size: CGFloat, _ weight: Int = 400) -> Font {
        let name: String
        switch weight {
        case ..<350: name = "Inter-Light"
        case ..<450: name = "Inter-Regular"
        case ..<550: name = "Inter-Medium"
        default: name = "Inter-SemiBold"
        }
        return .custom(name, fixedSize: size)
    }
    /// Thin hero numerals (05: `font: 300 58px Inter`).
    static func interLight(_ size: CGFloat) -> Font { inter(size, 300) }
    static func interRegular(_ size: CGFloat) -> Font { inter(size, 400) }
    static func interMedium(_ size: CGFloat) -> Font { inter(size, 500) }
    static func interSemibold(_ size: CGFloat) -> Font { inter(size, 600) }
}

extension Text {
    /// Uppercase tracked Space Mono label (TE silk-screen style).
    func crateLabel(_ size: CGFloat, tracking: CGFloat = 0.16) -> Text {
        font(Theme.label(size)).tracking(size * tracking)
    }

    /// 05 `.lbl` caps label: Inter 600, tracked .14em (pass uppercase text).
    func fieldLabel(_ size: CGFloat = 6.5, tracking: CGFloat = 0.14, weight: Int = 600) -> Text {
        font(Theme.inter(size, weight)).tracking(size * tracking)
    }
}

/// Silk-screened label on the chassis / display.
struct SilkLabel: View {
    let text: String
    var size: CGFloat = 8.5
    var color: Color = Theme.silk
    var tracking: CGFloat = 0.16

    init(_ text: String, size: CGFloat = 8.5, color: Color = Theme.silk, tracking: CGFloat = 0.16) {
        self.text = text
        self.size = size
        self.color = color
        self.tracking = tracking
    }

    var body: some View {
        Text(text.uppercased())
            .crateLabel(size, tracking: tracking)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// The ✦ glyph (no bundled font has it), drawn as a 4-point star.
struct SparkShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        let o = min(r.width, r.height) / 2
        let i = o * 0.28
        for k in 0..<8 {
            let a = Double(k) * .pi / 4 - .pi / 2
            let rad = k.isMultiple(of: 2) ? o : i
            let pt = CGPoint(x: c.x + CGFloat(cos(a)) * rad, y: c.y + CGFloat(sin(a)) * rad)
            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// Play triangle (U+25B6 can render as an emoji on iOS, so it's drawn).
struct PlayShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
