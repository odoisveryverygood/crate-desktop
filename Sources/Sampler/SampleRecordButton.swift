import SwiftUI

/// The host owns a persistent `@State` MicSampler initialized with this same AppState.
@MainActor
struct SampleRecordButton: View {
    let state: AppState
    let sampler: MicSampler
    @GestureState private var pressed = false
    @State private var hold = SampleHoldState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SilkLabel("CHOP TYPE")
                ForEach(SampleChopType.allCases, id: \.self) { type in
                    Button(type.label) { sampler.chopType = type }
                        .font(Theme.label(9))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(sampler.chopType == type ? Theme.orange : Theme.button)
                        .foregroundStyle(Theme.silk)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                        .disabled(sampler.isRecording || sampler.isPreparing || sampler.isProcessing)
                        .accessibilityAddTraits(sampler.chopType == type ? .isSelected : [])
                }
            }
            HStack(spacing: 10) {
                Circle().fill(Theme.orange).frame(width: 14, height: 14)
                    .opacity(sampler.isRecording ? 1 : 0.45)
                VStack(alignment: .leading, spacing: 5) {
                    Text(status).font(Theme.label(11)).foregroundStyle(Theme.text)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Theme.dim)
                            Rectangle().fill(Theme.orange).frame(width: geometry.size.width * sampler.level)
                        }
                    }.frame(height: 5)
                }
                Text(String(format: "%05.1f s", sampler.seconds))
                    .font(Theme.doto(23)).monospacedDigit().foregroundStyle(Theme.orange)
            }
            .padding(12)
            .frame(minHeight: 64)
            .background(sampler.isRecording ? Theme.padPressed : Theme.pad)
            .clipShape(RoundedRectangle(cornerRadius: Theme.padRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.padRadius)
                .stroke(sampler.isRecording ? Theme.orange : Theme.padEdge, lineWidth: 2))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($pressed) { _, held, _ in held = true }
                .onChanged { _ in
                    if hold.begin() { sampler.startRecording() }
                }
                .onEnded { _ in
                    guard hold.finish() else { return }
                    let chop = sampler.chopType
                    Task { await sampler.stopRecording(chop: chop) }
                })
            .onChange(of: pressed) { _, held in
                if !held, hold.reset() { sampler.cancelRecording() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sample record")
            .accessibilityValue(status + String(format: ", %.1f seconds", sampler.seconds))
            .accessibilityHint("Double tap to start recording, then double tap again to stop and chop into bank D.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if sampler.isRecording || sampler.isPreparing {
                    Task { await sampler.stopRecording(chop: sampler.chopType) }
                } else { sampler.startRecording() }
            }
            if let message = sampler.errorMessage {
                Text(message).font(Theme.mono(10)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("HOLD TO RECORD · RELEASE TO CHOP → BANK D")
                    .font(Theme.label(8)).foregroundStyle(Theme.silk)
            }
        }
        .padding(10)
        .background(Theme.chassis)
        .onDisappear {
            _ = hold.reset()
            sampler.cancelRecording()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { sampler.cancelRecording() }
        }
    }

    private var status: String {
        if sampler.isProcessing { return "CHOPPING…" }
        if sampler.isPreparing { return "ALLOW MICROPHONE…" }
        return sampler.isRecording ? "RECORDING" : "SAMPLE RECORD"
    }
}

#if DEBUG
#Preview("Sample recorder", traits: .fixedLayout(width: 430, height: 180)) {
    let state = AppState(engine: MockEngine())
    SampleRecordButton(state: state, sampler: MicSampler(state: state))
}
#endif
