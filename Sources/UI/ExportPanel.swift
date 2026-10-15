import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// EXPORT at the top of the projects sheet: pick the length (1× / 4× / 8× the loop, or 8 bars) and the format, tap
/// EXPORT → an offline render (seconds, with progress) → the share sheet. No new deck button.
struct ExportPanel: View {
    let state: AppState
    @AppStorage("crateExportLength") private var lengthRaw = ExportLength.loop4.rawValue
    @AppStorage("crateExportFormat") private var formatRaw = ExportFormat.m4a.rawValue
    @State private var progress: Double? = nil
    @State private var error: String?

    private var length: ExportLength { ExportLength(rawValue: lengthRaw) ?? .loop4 }
    private var format: ExportFormat { ExportFormat(rawValue: formatRaw) ?? .m4a }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("EXPORT").fieldLabel(9).foregroundStyle(Theme.lidGrey1)
                Spacer(minLength: 6)
                ForEach(ExportLength.allCases, id: \.self) { l in
                    chip(l.label, on: l == length, id: "export-len-\(l.rawValue)") { lengthRaw = l.rawValue }
                }
                Rectangle().fill(Theme.lidGrey3).frame(width: 0.5, height: 18).padding(.horizontal, 2)
                ForEach(ExportFormat.allCases, id: \.self) { f in
                    chip(f.label, on: f == format, id: "export-fmt-\(f.rawValue)") { formatRaw = f.rawValue }
                }
            }
            Button(action: start) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(progress == nil ? Theme.lidInk : Theme.lidGrey3)
                    if let p = progress {
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 6).fill(Theme.live)
                                .frame(width: max(8, g.size.width * p))
                        }
                    }
                    Text(progress.map { "RENDERING · \(Int(($0 * 100).rounded())) %" }
                         ?? "↗ EXPORT \(state.song.songMode && length == .loop1 ? "THE SONG" : length.spoken) · \(format.label)")
                        .font(Theme.inter(10, 700)).tracking(1.2)
                        .foregroundStyle(progress == nil ? Color.black : Theme.lidInk)
                        .frame(maxWidth: .infinity)
                }
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(ChipPressStyle())
            .disabled(progress != nil)
            .accessibilityIdentifier("export-button")
            if let error {
                Text(error).font(Theme.mono(9)).foregroundStyle(Theme.red).lineLimit(2)
            }
        }
        .padding(.bottom, 12)
    }

    private func start() {
        guard progress == nil else { return }
        error = nil
        progress = 0
        let l = length, f = format
        Task { @MainActor in
            do {
                let url = try await BeatExport.run(state: state, length: l, format: f) { p in
                    if progress != nil { progress = max(progress ?? 0, p) }
                }
                progress = nil
                state.addLog("EXPORT", "↗ \(url.lastPathComponent)", tint: .ochre)
                ShareSheet.present(url)
            } catch {
                progress = nil
                self.error = error.localizedDescription
                state.addLog("ERR", "Export: \(error.localizedDescription)", tint: .red)
            }
        }
    }

    private func chip(_ label: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.inter(8, 700)).tracking(0.6)
                .foregroundStyle(on ? Color.black : Theme.chipText)
                .padding(.horizontal, 7)
                .frame(minWidth: 28)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? Theme.lidInk : Color.black))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.chipStroke, lineWidth: 0.5).opacity(on ? 0 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(ChipPressStyle())
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The iOS share sheet for a file, from whatever is on screen (a sheet included).
enum ShareSheet {
    @MainActor static func present(_ url: URL) {
        #if os(iOS)
        guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
        var top = root
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = vc.popoverPresentationController {   // iPad: anchor it mid-screen
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(vc, animated: true)
        DebugLog.event("share_sheet", ["file": url.lastPathComponent])
        #else
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url, destination.standardizedFileURL != url.standardizedFileURL else { return }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".crate-export-" + UUID().uuidString)
            do {
                try FileManager.default.copyItem(at: url, to: temporary)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else { try FileManager.default.moveItem(at: temporary, to: destination) }
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                MacExportError.show("Export save: \(error.localizedDescription)")
            }
        }
        if var parent = NSApp.keyWindow ?? NSApp.mainWindow {
            while let sheet = parent.attachedSheet { parent = sheet }
            panel.beginSheetModal(for: parent, completionHandler: completion)
        } else { panel.begin(completionHandler: completion) }
        #endif
    }
}
