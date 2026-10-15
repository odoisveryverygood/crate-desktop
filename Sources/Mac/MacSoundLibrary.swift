import SwiftUI
import AVFoundation

/// Audition and place library sounds without a prompt or a network request.
struct MacSoundLibrary: View {
    let state: AppState
    let orchestrator: Orchestrator
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var kind = "All"
    @State private var style = "All styles"
    @State private var selected: String?
    @State private var bank: Bank
    @State private var pad: Int
    @State private var player: AVAudioPlayer?
    @State private var busy = false
    @State private var message = ""

    init(state: AppState, orchestrator: Orchestrator) {
        self.state = state; self.orchestrator = orchestrator
        _bank = State(initialValue: state.selectedPad.bank)
        _pad = State(initialValue: state.selectedPad.index)
    }
    struct Item: Identifiable {
        let id: String
        let name: String
        let type: String
        let file: String
        let tags: String
        let styles: [String: Double]
        let shot: OneShot?
        let loop: LoopEntry?
        var detail: String {
            if let l = loop { return "\(type.uppercased()) · \(Int(l.bpm)) BPM · \(l.key ?? "—") · \(l.bars) bars" }
            return "\(type.uppercased()) · \(String(format: "%.1f", shot?.durationSec ?? 0)) s" + (shot?.rootNote.map { " · MIDI \($0)" } ?? "")
        }
    }
    private var items: [Item] {
        let lib = orchestrator.library
        let shots = lib.oneshots.map { Item(id: $0.id, name: $0.name, type: $0.category, file: $0.file,
                                           tags: ($0.tags ?? []).joined(separator: " "), styles: $0.styles, shot: $0, loop: nil) }
        let loops = lib.loops.map { Item(id: $0.id, name: $0.name, type: $0.instrument, file: $0.file,
                                         tags: ($0.moods ?? []).joined(separator: " "), styles: $0.styles, shot: nil, loop: $0) }
        return (kind == "One-shots" ? shots : kind == "Loops" ? loops : shots + loops).filter { i in
            let text = "\(i.name) \(i.type) \(i.tags) \(i.detail)".lowercased()
            let matches = query.lowercased().split(separator: " ").allSatisfy { text.contains($0) }
            return matches && (style == "All styles" || (i.styles[style] ?? 0) >= 0.7)
        }
    }
    private var choice: Item? { items.first { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SOUND LIBRARY").font(Theme.inter(18, 700)).tracking(1)
                    Text(orchestrator.library.summary).font(Theme.mono(11)).foregroundStyle(Theme.mid)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Search piano, dark bass, metal hat, flute…", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("library-search")
            HStack {
                Picker("Sounds", selection: $kind) { ForEach(["All", "One-shots", "Loops"], id: \.self) { Text($0) } }
                Picker("Style", selection: $style) {
                    Text("All styles").tag("All styles")
                    ForEach(Style.allCases, id: \.rawValue) { Text($0.rawValue.uppercased()).tag($0.rawValue) }
                }
                Text("\(items.count) matches").font(Theme.mono(11)).foregroundStyle(Theme.mid)
            }
            List(items) { item in
                Button {
                    selected = item.id
                    message = ""
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(Theme.inter(13, 600))
                            Text(item.detail).font(Theme.mono(10)).foregroundStyle(Theme.mid)
                        }
                        Spacer()
                        Text(item.loop == nil ? "HIT" : "LOOP").font(Theme.mono(10)).foregroundStyle(Theme.mid)
                    }.contentShape(Rectangle()).padding(.vertical, 3)
                }.buttonStyle(.plain).listRowBackground(selected == item.id ? Theme.orange.opacity(0.18) : Color.clear)
            }
            if let item = choice {
                Text(item.name + " · " + item.detail).font(Theme.mono(11)).lineLimit(2)
                HStack {
                    Button("Preview") { preview(item) }.accessibilityIdentifier("library-preview")
                    Button("Stop") { player?.stop(); player = nil }
                    Spacer()
                    Picker("Bank", selection: $bank) { ForEach(Bank.allCases, id: \.rawValue) { Text($0.letter).tag($0) } }.frame(width: 110)
                    Picker("Pad", selection: $pad) { ForEach(0..<16, id: \.self) { Text("\($0 + 1)").tag($0) } }.frame(width: 100)
                    Button("Load \(bank.letter)\(pad + 1)") { load(item) }.disabled(busy)
                        .accessibilityIdentifier("library-load-pad")
                    if item.loop != nil {
                        Button("Chop to D") { chop(item) }.disabled(busy).accessibilityIdentifier("library-chop")
                    }
                }
                Text("Load replaces one pad. Chop replaces Bank D with 16 chops. Both support Undo.")
                    .font(Theme.inter(11, 400)).foregroundStyle(Theme.mid)
            } else {
                Text("Select a sound to preview it, load a pad, or chop a loop.").font(Theme.inter(12, 400)).foregroundStyle(Theme.mid)
            }
            if !message.isEmpty { Text(message).font(Theme.inter(12, 400)).foregroundStyle(Theme.orange) }
        }.padding(24).frame(width: 840, height: 620).background(Theme.oled).preferredColorScheme(.dark)
            .onDisappear { player?.stop() }
    }
    private func preview(_ item: Item) {
        do {
            player?.stop()
            let p = try AVAudioPlayer(contentsOf: orchestrator.library.fileURL(item.file))
            p.volume = 0.65; p.prepareToPlay()
            guard p.play() else { message = "Couldn’t start the preview."; return }
            player = p; message = "Previewing \(item.name)"
        } catch { message = "Couldn’t preview: \(error.localizedDescription)" }
    }
    private func load(_ item: Item) {
        busy = true; player?.stop()
        Task { @MainActor in
            defer { busy = false }
            let target = PadID(bank, pad)
            let sound: PadSound
            if let shot = item.shot { sound = Retrieval.padSound(shot, lib: orchestrator.library) }
            else if let loop = item.loop {
                sound = PadSound(id: loop.id, name: loop.name, category: .loop,
                                 fileURL: orchestrator.library.fileURL(loop.file), rootNote: Music.parseKey(loop.key).map { 60 + $0.pc },
                                 source: loop.source ?? "Library")
            } else { return }
            orchestrator.checkpoint("library \(target.bank.letter)\(target.number)")
            var sounds = orchestrator.currentBank(bank)
            sounds[pad] = sound
            let ms = await orchestrator.loadBanks([(bank, sounds)])
            guard state.engine.sound(for: target)?.id == sound.id else { message = "The sound couldn’t be loaded."; return }
            state.bank = bank; state.selectedPad = target
            state.hit(target)
            message = "Loaded \(item.name) on \(bank.letter)\(pad + 1) · \(ms) ms"
            state.addLog("LIBRARY", message, tint: .orange)
        }
    }
    private func chop(_ item: Item) {
        guard var loop = item.loop else { return }
        // The imported-chop contract identifies Bank D by its import- prefix.
        loop.id = "import-library-" + loop.id
        busy = true; player?.stop()
        Task { @MainActor in
            defer { busy = false }
            let set = Retrieval.chops(loop, lib: orchestrator.library, bars: min(4, loop.bars))
            message = await orchestrator.importChops(set, plan: nil) ? "\(loop.name) · 16 chops loaded on D" : "The loop couldn’t be chopped."
        }
    }
}
