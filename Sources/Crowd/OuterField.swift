import SwiftUI

/// Direction 05 CSS values, scoped to R4 so the parallel R1 Theme work can land independently.
/// Reuse the shared Theme for the live accent, timing and mono type.
enum OuterField {
    static let aluminium = Theme.hex(0xE0E1DE)
    static let key = Theme.hex(0xF7F7F5)
    static let keyDown = Theme.hex(0xEAEAE6)
    static let seam = Theme.hex(0xC3C4C0)
    static let ink = Theme.hex(0x131313)
    static let inkSecondary = Theme.hex(0x6A6B67)
    static let white = Theme.hex(0xF5F5F3)
    static let secondary = Theme.hex(0x8E8E8E)
    static let rule = Theme.hex(0x2A2A2A)

    static func type(_ size: CGFloat, weight: Int = 400) -> Font {
        let name: String
        switch weight {
        case 300: name = "Inter-Light"
        case 500: name = "Inter-Medium"
        case 600: name = "Inter-SemiBold"
        default: name = "Inter-Regular"
        }
        return .custom(name, fixedSize: size)
    }

    static func bank(_ bank: Bank) -> Color {
        [Theme.orange, Theme.hex(0x3A76EE), Theme.hex(0xD9A12A), Theme.hex(0x9D9E9A)][bank.rawValue]
    }
}

struct OuterLevelLine: View {
    let level: Double
    var color: Color = Theme.orange
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(OuterField.rule)
                Rectangle().fill(color)
                    .frame(width: geometry.size.width * (level.isFinite ? min(1, max(0, level)) : 0))
            }
        }
    }
}
