import SwiftUI

/// `›` prompt line (the Duo's outer screen): a JetBrains Mono TextField bound to the shared draft, with a dim
/// placeholder; it's empty again after you submit. ✦ DIG focuses it via CrateUI.focusRequest.
struct PromptLine: View {
    let state: AppState
    var fontSize: CGFloat = 11
    var placeholder = "Describe a beat or a change…"

    @Bindable private var ui = CrateUI.shared
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Text("›")
                .font(Theme.mono(fontSize + 2, bold: true))
                .foregroundStyle(Theme.orange)
            ZStack(alignment: .leading) {
                if ui.draft.isEmpty {
                    Text(placeholder)
                        .font(Theme.mono(fontSize))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextField("", text: $ui.draft)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(fontSize))
                    .foregroundStyle(Theme.text)
                    .tint(Theme.orange)
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .onKeyPress(.escape) { focused = false; state.promptFocused = false; return .handled }
                    .crateNoAutocorrect()
                    .accessibilityIdentifier("prompt-field")
                    .accessibilityLabel("Prompt")
                    .accessibilityHint(placeholder)
            }
            if state.isDigging {
                DotSpinner(color: Theme.orange, dot: 2)
            }
        }
        .background {
            // TextField consumes raw presses; register Escape with the hosting controller
            // so it also works while UIKit's text editor is first responder.
            Button { focused = false; state.promptFocused = false } label: { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .accessibilityHidden(true)
        }
        .frame(minHeight: fontSize + 8)
        .onChange(of: ui.focusRequest) { _, _ in focused = true }
        .onChange(of: ui.blurRequest) { _, _ in focused = false }
        .onChange(of: focused) { _, f in ui.promptFocused = f; state.promptFocused = f }
        .onChange(of: state.promptFocused) { _, f in focused = f }
        .onDisappear { if focused { state.promptFocused = false; ui.promptFocused = false } }
    }

    private func submit() {
        let t = ui.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        focused = false
        ui.draft = ""
        guard !t.isEmpty else { return }
        state.dig(t)
    }
}

extension View {
    /// Pads/keys near the screen edges shouldn't wait on the system edge-gesture gate.
    @ViewBuilder
    func crateDeferEdgeGestures() -> some View {
        #if os(iOS)
        self.defersSystemGestures(on: .all)
        #else
        self
        #endif
    }

    @ViewBuilder
    func crateNoAutocorrect() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}

/// Canned prompts + FLIP IT + AI PERFORM.
struct ActionChips: View {
    let state: AppState
    var size: CGFloat = 8.5
    /// Optional subset of chip ids (the outer display shows fewer).
    var only: [String]? = nil

    struct Item: Identifiable {
        let id: String
        let label: String
        let prompt: String?
    }

    static let items: [Item] = [
        Item(id: "chip-undo", label: "↶ UNDO", prompt: nil),
        Item(id: "chip-redo", label: "↷ REDO", prompt: nil),
        Item(id: "chip-dilla-nujabes", label: "DILLA × NUJABES",
             prompt: "4 bar loop, j dilla laid back drums and a killer nujabes piano sample"),
        Item(id: "chip-dilla-drums", label: "DILLA DRUMS", prompt: "fill up the pads with some j dilla type drums"),
        Item(id: "chip-house-kit", label: "HOUSE KIT", prompt: "a house drum and kick"),
        Item(id: "chip-vintage-break", label: "VINTAGE BREAK", prompt: "a really vintage drum break"),
        Item(id: "chip-flip-it", label: "FLIP IT", prompt: nil),
        Item(id: "chip-ai-perform", label: "AI PERFORM", prompt: nil),
    ]

    var body: some View {
        ChipFlow(spacing: 6, lineSpacing: 6) {
            ForEach(Self.items.filter { only?.contains($0.id) ?? true }) { item in
                chip(item)
            }
        }
    }

    private func chip(_ item: Item) -> some View {
        let isPerform = item.id == "chip-ai-perform"
        let on = isPerform && state.performOn
        let accent = item.prompt == nil && !isPerform
        return Button {
            tap(item)
        } label: {
            HStack(spacing: 5) {
                if isPerform {
                    Circle().fill(on ? Color.black : Theme.orange).frame(width: 5, height: 5)
                }
                Text(item.label)
                    .crateLabel(size, tracking: 0.14)
                    .foregroundStyle(on ? Color.black : (accent ? Theme.orange : Theme.text))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: size + 14)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(on ? Theme.orange : Color.black))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(on ? Theme.orange : Theme.dim, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(ChipPressStyle())
        .accessibilityIdentifier(item.id)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func tap(_ item: Item) {
        let ui = CrateUI.shared
        switch item.id {
        case "chip-undo":
            Task { @MainActor in await Orchestrator.current?.undo() }
        case "chip-redo":
            Task { @MainActor in await Orchestrator.current?.redo() }
        case "chip-flip-it":
            state.onFlip?()
            DebugLog.event("flip")
        case "chip-ai-perform":
            let on = !state.performOn
            state.performOn = on
            state.onPerformToggle?(on)
            DebugLog.event("perform_toggle", ["on": on])
        default:
            if let p = item.prompt {
                ui.draft = ""
                ui.blurRequest += 1
                state.dig(p)
            }
        }
    }
}

struct ChipPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(Theme.orange, lineWidth: 1)
                .opacity(configuration.isPressed ? 1 : 0))
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

/// Result chips from the AI log: tag + ms bold in the tint colour, then the text (JEV 118ms DILLA · JAZZHOP…).
struct ResultChips: View {
    let lines: [LogLine]
    var columns = 4
    var size: CGFloat = 10

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .topLeading), count: max(1, columns))
        LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
            ForEach(lines) { line in
                chipText(line)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func chipText(_ line: LogLine) -> Text {
        let tint = Theme.tint(line.tint)
        let head = line.tag.uppercased() + (line.ms.map { " " + UIHelpers.msText($0) } ?? "")
        let bodyColor = (line.tint == .orange || line.tint == .grey) ? Theme.mid : tint
        return Text("\(Text(head).font(Theme.mono(size, bold: true)).foregroundStyle(tint)) \(Text(line.text).font(Theme.mono(size)).foregroundStyle(bodyColor))")
            .tracking(size * 0.04)
    }
}

/// Minimal flow layout for chips (wraps to the next line).
struct ChipFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW {
                y += lineH + lineSpacing
                x = 0
                lineH = 0
            }
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX {
                y += lineH + lineSpacing
                x = bounds.minX
                lineH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
    }
}
