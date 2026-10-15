import SwiftUI

/// Direction 05 tokens scoped to R3 so the theme owner can integrate independently.
enum PadFinish {
    static let key = Theme.hex(0xF7F7F5)
    static let pressed = Theme.hex(0xEAEAE6)
    static let seam = Theme.hex(0xC3C4C0)
    static let ink = Theme.hex(0x131313)
    static let muted = Theme.hex(0x6A6B67)
    static func label(_ size: CGFloat) -> Font { .custom("Inter-SemiBold", fixedSize: size) }
}

enum PadStyle: String { case plain, records
    static let storageKey = "cratePadStyle"
    static func set(_ value: String) {
        guard let style = PadStyle(rawValue: value) else { return }
        UserDefaults.standard.set(style.rawValue, forKey: storageKey)
    }
}

/// Attach only to SHIFT; leaves its normal short-press action intact.
struct PadStyleSwitch: ViewModifier {
    @AppStorage(PadStyle.storageKey) private var style = "plain"
    @State private var toast = false
    func body(content: Content) -> some View {
        content
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in
                style = style == "records" ? "plain" : "records"
                CrateUI.shared.shift = false
                toast = true
            })
            .accessibilityAction(named: "Change pad style") {
                style = style == "records" ? "plain" : "records"
                toast = true
            }
            .overlay(alignment: .topLeading) {
                if toast {
                    Text("PADS · \(style.uppercased())")
                        .font(PadFinish.label(10)).foregroundStyle(.white)
                        .padding(8).background(.black, in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize().offset(y: -32).allowsHitTesting(false)
                        .task(id: style) {
                            try? await Task.sleep(for: .seconds(1.8))
                            guard !Task.isCancelled else { return }
                            toast = false
                        }
                }
            }
    }
}

/// Vector vinyl, 33 rpm with a 350 ms coast after the estimated voice ends.
/// Playback is inferred from the shared pattern/trigger state; no audio-thread work.
struct RecordPad: View {
    let category: Category?
    let bank: Bank
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle = 0.0
    @State private var speed = 0.0
    @State private var lastTick: Date?

    private var label: Color {
        switch category {
        case .kick: return Theme.hex(0xC99A3E)
        case .snare, .clap: return Theme.hex(0x7A2E27)
        case .hat, .openhat, .cymbal: return Theme.hex(0xECE4D3)
        case .perc, .shaker, .rim: return Theme.hex(0x5F6A48)
        case .eight08, .bass: return Theme.hex(0x203A5E)
        case .vocal: return Theme.hex(0xD2A08E)
        case .chop, .loop: return Theme.bank(bank)
        default: return Theme.hex(0xA5B3AD)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || (!active && speed == 0))) { tick in
            Canvas { context, size in
                let diameter = min(size.width, size.height)
                context.translateBy(x: size.width / 2, y: size.height / 2)
                context.rotate(by: .degrees(reduceMotion ? 0 : angle))
                func circle(_ fraction: Double) -> Path {
                    let r = diameter * fraction / 2
                    return Path(ellipseIn: CGRect(x: -r, y: -r, width: 2*r, height: 2*r))
                }
                context.fill(circle(1), with: .color(Theme.hex(0x141312)))
                for fraction in [0.83, 0.73, 0.65] {
                    context.stroke(circle(fraction), with: .color(Theme.hex(0x35322E)), lineWidth: 0.6)
                }
                context.fill(circle(0.42), with: .color(label))
                // Off-centre printed stripe makes the rotation visible.
                let stripe = CGRect(x: -diameter * 0.12, y: -diameter * 0.12, width: diameter * 0.24, height: diameter * 0.035)
                context.fill(Path(stripe), with: .color(.black.opacity(0.5)))
                context.fill(circle(0.055), with: .color(PadFinish.key))
                if active {
                    context.stroke(circle(0.74), with: .color(Theme.orange), lineWidth: 1.2)
                    let r = diameter * 0.026
                    context.fill(Path(ellipseIn: CGRect(x: diameter * 0.26-r, y: -diameter * 0.26-r, width: 2*r, height: 2*r)), with: .color(Theme.orange))
                }
            }
            .onChange(of: tick.date) { _, now in
                let dt = min(0.05, max(0, now.timeIntervalSince(lastTick ?? now)))
                lastTick = now
                speed = active ? 198 : max(0, speed - 198 / 0.35 * dt)
                angle = (angle + speed * dt).truncatingRemainder(dividingBy: 360)
            }
        }
        .onChange(of: active) { _, _ in lastTick = nil }
        .accessibilityHidden(true)
    }
}
