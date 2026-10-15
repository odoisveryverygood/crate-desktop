import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// A copied, validated audio file. The source supplied by Files may disappear as soon as
/// NSItemProvider's callback returns, so every drop is copied before the UI receives it.
struct ImportedAudio {
    let url: URL
    let name: String
    let duration: Double
    let pad: PadID
}

enum AudioImport {
    static func receive(_ providers: [NSItemProvider], at pad: PadID,
                        completion: @escaping (Result<ImportedAudio, Error>) -> Void) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.audio.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
            let audioType = provider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: .audio) == true
            } ?? UTType.audio.identifier
            provider.loadFileRepresentation(forTypeIdentifier: audioType) { url, error in
                finish(url: url, error: error, provider: provider, pad: pad, completion: completion)
            }
        } else {
            provider.loadObject(ofClass: NSURL.self) { item, error in
                finish(url: item as? URL, error: error, provider: provider, pad: pad, completion: completion)
            }
        }
        return true
    }

    private static func finish(url source: URL?, error: Error?, provider: NSItemProvider, pad: PadID,
                               completion: @escaping (Result<ImportedAudio, Error>) -> Void) {
        let result: Result<ImportedAudio, Error>
        do {
            if let error { throw error }
            guard let source, source.isFileURL else { throw ImportError.noFile }
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw ImportError.noFile }
            guard (values.fileSize ?? 0) <= 100 * 1024 * 1024 else { throw ImportError.tooLarge }

            let files = FileManager.default
            let docs = CrateStorage.documents
            let directory = docs.appendingPathComponent("imported", isDirectory: true)
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            let suggested = provider.suggestedName ?? source.lastPathComponent
            let rawExtension = (suggested as NSString).pathExtension
            let typeExtension = provider.registeredTypeIdentifiers
                .compactMap(UTType.init)
                .first(where: { $0.conforms(to: .audio) })?.preferredFilenameExtension
            let sourceExtension = source.pathExtension == "tmp" ? "" : source.pathExtension
            let ext = rawExtension.isEmpty ? (typeExtension ?? sourceExtension) : rawExtension
            let safeExtension = ext.isEmpty ? "wav" : String(ext.prefix(8))
            let name = (suggested as NSString).deletingPathExtension
            let destination = directory.appendingPathComponent(UUID().uuidString + "." + safeExtension)
            try files.copyItem(at: source, to: destination)

            do {
                let file = try AVAudioFile(forReading: destination)
                let seconds = Double(file.length) / file.processingFormat.sampleRate
                guard seconds.isFinite, seconds > 0 else { throw ImportError.emptyAudio }
                guard seconds <= 300 else { throw ImportError.tooLarge }
                result = .success(ImportedAudio(url: destination,
                                               name: name.isEmpty ? "IMPORTED" : name,
                                               duration: seconds, pad: pad))
            } catch {
                try? files.removeItem(at: destination)
                throw error
            }
        } catch {
            result = .failure(error)
        }
        DispatchQueue.main.async { completion(result) }
    }

    @MainActor static func loadOnPad(_ audio: ImportedAudio, state: AppState) async {
        let pad = audio.pad
        Orchestrator.current?.checkpoint("load \(audio.name) on \(pad.bank.letter)\(pad.number)")
        var bank = [Int: PadSound]()
        for i in 0..<16 {
            let existing = PadID(pad.bank, i)
            if let sound = state.sound(existing) { bank[i] = sound }
        }
        let sound = PadSound(id: "import-" + UUID().uuidString,
                             name: audio.name,
                             category: audio.duration > 2 ? .loop : .chop,
                             fileURL: audio.url, rootNote: 60)
        bank[pad.index] = sound
        do {
            try await state.engine.loadBank(pad.bank, sounds: bank)
            guard state.engine.sound(for: pad)?.id == sound.id else { throw ImportError.loadFailed }
            for (i, item) in bank { state.sounds[PadID(pad.bank, i)] = item }
            state.selectedPad = pad
            state.bank = pad.bank
            state.hit(pad)
            state.addLog("SAMPLE", "▸ \(audio.name) on \(pad.bank.letter)\(pad.number)", tint: .blue)
            DebugLog.event("sample_drop", ["pad": "\(pad.bank.letter)\(pad.number)", "sec": audio.duration])
        } catch {
            state.addLog("ERR", "Drop: \(error.localizedDescription)", tint: .red)
        }
    }

    /// A long file that matches `demo_samples.json` (kept for the drop path; every long file now goes to CHOP 16).
    static func autoChops(_ audio: ImportedAudio) -> Bool { audio.duration > 2 && DemoSamples.match(audio.name) != nil }

    /// Slice starts (seconds): the demo manifest's hand-picked points → 16 transients → 16 equal regions.
    static func sliceStarts(_ audio: ImportedAudio, demo: DemoSample?) -> [Double] {
        if let s = demo?.slicesSec, s.count >= 16, s.allSatisfy({ $0 >= 0 && $0 < audio.duration }) { return Array(s.prefix(16)) }
        if let a = try? SampleChopper.analyze(url: audio.url, chop: .threshold), a.slices.count == 16 { return a.slices.map(\.start) }
        return (0..<16).map { audio.duration * Double($0) / 16 }
    }

    /// ＋ in the prompt bar (`.fileImporter`): copy the picked file in, then a song (> 2 s) becomes 16 chops on bank D
    /// and a short sound lands on the selected pad.
    @MainActor static func importPicked(_ source: URL, state: AppState) async {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        await importFile(source, name: source.deletingPathExtension().lastPathComponent, state: state,
                         shortPad: state.selectedPad)
    }

    /// Host-file import (router `crate://import?path=`): the same path as ＋ and a Files drag-in.
    @MainActor static func importPath(_ path: String, state: AppState) async {
        let source = URL(fileURLWithPath: path)
        await importFile(source, name: source.deletingPathExtension().lastPathComponent, state: state,
                         shortPad: PadID(state.bank, 0))
    }

    @MainActor private static func importFile(_ source: URL, name rawName: String, state: AppState, shortPad: PadID) async {
        let files = FileManager.default
        do {
            guard (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 <= 100 * 1024 * 1024 else {
                throw ImportError.tooLarge
            }
            let docs = CrateStorage.documents
            let directory = docs.appendingPathComponent("imported", isDirectory: true)
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = source.pathExtension.isEmpty ? "wav" : String(source.pathExtension.prefix(8))
            let destination = directory.appendingPathComponent(UUID().uuidString + "." + ext)
            try files.copyItem(at: source, to: destination)
            let file = try AVAudioFile(forReading: destination)
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            guard seconds.isFinite, seconds > 0 else { throw ImportError.emptyAudio }
            guard seconds <= 300 else { throw ImportError.tooLarge }
            let audio = ImportedAudio(url: destination, name: rawName.isEmpty ? "IMPORTED" : rawName, duration: seconds,
                                      pad: shortPad)
            if seconds > 2 { await chop16(audio, state: state) } else { await loadOnPad(audio, state: state) }
        } catch {
            state.addLog("ERR", "Import: \(error.localizedDescription)", tint: .red)
        }
    }

    @MainActor static func chop16(_ audio: ImportedAudio, state: AppState) async {
        // On-device analysis: the best region of the song (or the whole loop), FIND CHOPS inside it, heroes on D1–D8.
        let demo = DemoSamples.match(audio.name)
        let label = (demo?.name ?? audio.name).uppercased()
        if let orchestrator = Orchestrator.current, let a = await analyzed(audio, demo: demo, label: label, state: state) {
            // 16 chops on bank D, chop 1 auditions, FLIP IT glows (no auto-flip).
            if await orchestrator.importChops(a.set, plan: a.plan) {
                DebugLog.event("sample_drop", ["bank": "D", "slices": a.set.sounds.count, "sec": audio.duration, "demo": demo?.match ?? ""])
            } else {
                state.addLog("ERR", "Chop: \(ImportError.loadFailed.localizedDescription)", tint: .red)
            }
            return
        }
        // Analysis failed (or no orchestrator): transients → 16 equal regions, without an AI session.
        let starts = sliceStarts(audio, demo: demo)
        let sounds = Dictionary(uniqueKeysWithValues: (0..<16).map { i in
            (i, PadSound(id: "import-chop-\(i)-" + UUID().uuidString,
                         name: "\(audio.name) \(String(format: "%02d", i + 1))",
                         category: .chop,
                         fileURL: audio.url,
                         start: starts[i],
                         end: i < 15 ? starts[i + 1] : audio.duration,
                         rootNote: 60))
        })
        do {
            try await state.engine.loadBank(.d, sounds: sounds)
            guard sounds.allSatisfy({ state.engine.sound(for: PadID(.d, $0.key))?.id == $0.value.id }) else { throw ImportError.loadFailed }
            state.sounds = state.sounds.filter { $0.key.bank != .d }
            for (i, sound) in sounds { state.sounds[PadID(.d, i)] = sound }
            state.bank = .d
            state.selectedPad = PadID(.d, 0)
            DebugLog.event("sample_drop", ["bank": "D", "slices": 16, "sec": audio.duration])
        } catch {
            state.addLog("ERR", "Chop: \(error.localizedDescription)", tint: .red)
        }
    }

    enum ImportError: LocalizedError {
        case noFile, emptyAudio, loadFailed, tooLarge
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "Use audio under 100 MB and five minutes."
            case .noFile: return "No audio file was supplied."
            case .emptyAudio: return "The audio file is empty."
            case .loadFailed: return "The audio engine could not load this file."
            }
        }
    }
}
