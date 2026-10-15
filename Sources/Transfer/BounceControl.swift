import SwiftUI
import UniformTypeIdentifiers

/// Exports the bytes of the recorded WAV to Files or another app in Split View.
struct BounceDocument: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(filenameExtension: "wav") ?? .audio) { file in
            SentTransferredFile(file.url)
        }
    }
}

struct BounceControl: View {
    let state: AppState

    @State private var busy = false
    @State private var bounceTask: Task<Void, Never>?
    @State private var bouncedURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 7) {
            Button {
                if busy { bounceTask?.cancel() }
                else {
                    busy = true
                    bounceTask = Task { await record() }
                }
            } label: {
                Text(busy ? "CANCEL BOUNCE" : "↗ BOUNCE")
                    .crateLabel(8, tracking: 0.12)
                    .foregroundStyle(Theme.silk)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Theme.button, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.buttonBorder))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("bounce-button")

            if let bouncedURL {
                let file = BounceDocument(url: bouncedURL)
                Text("↗ " + bouncedURL.lastPathComponent)
                    .font(Theme.mono(8, bold: true))
                    .foregroundStyle(Theme.silk)
                    .lineLimit(1)
                    .frame(maxWidth: 125)
                    .draggable(file)
                    .accessibilityIdentifier("bounce-file")
                ShareLink(item: bouncedURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.silk)
                }
                .accessibilityLabel("Share bounced WAV")
            }
        }
        .onDisappear { bounceTask?.cancel() }
        .alert("Bounce failed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @MainActor private func record() async {
        defer { busy = false; bounceTask = nil }
        guard !Task.isCancelled else { return }
        guard let engine = state.engine as? AudioEngine else {
            errorMessage = "Bounce needs the audio engine."
            return
        }
        busy = true
        bouncedURL = nil
        if !engine.isPlaying {
            state.togglePlay()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        let title = state.sampleLabel.split(separator: "·").first.map(String.init)
            ?? state.styleLabel
        do {
            bouncedURL = try await engine.bounce(bars: 4, title: title)
            state.addLog("BOUNCE", "↗ \(bouncedURL!.lastPathComponent)", tint: .ochre)
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
            state.addLog("ERR", "Bounce: \(error.localizedDescription)", tint: .red)
        }
    }
}
