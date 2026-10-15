import Foundation
import AVFoundation

/// A selected library must contain decodable indexes and every referenced audio file.
enum MacLibraryValidation {
    struct Report {
        let oneShots: Int
        let loops: Int
        let missing: [String]
        let unreadable: [String]
        var complete: Bool { missing.isEmpty && unreadable.isEmpty && oneShots > 0 && loops > 0 }
        var message: String {
            if complete { return "\(oneShots) one-shots · \(loops) loops verified. Restart CRATE to load this library." }
            return "Library not installed: \(missing.count) missing and \(unreadable.count) unreadable sounds (\(oneShots) one-shots · \(loops) loops indexed)."
        }
    }
    static func inspect(_ folder: URL) throws -> Report {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let decoder = JSONDecoder()
        let shots = try decoder.decode(OneShotsFile.self, from: Data(contentsOf: root.appendingPathComponent("oneshots.json")))
        let loops = try decoder.decode(LoopsFile.self, from: Data(contentsOf: root.appendingPathComponent("loops.json")))
        _ = try decoder.decode(GroovesFile.self, from: Data(contentsOf: root.appendingPathComponent("grooves.json")))
        var missing: [String] = []
        var unreadable: [String] = []
        for relative in Set(shots.samples.map(\.file) + loops.loops.map(\.file)).sorted() {
            let url = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
            guard !relative.hasPrefix("/"), url.path.hasPrefix(root.path + "/") else { unreadable.append(relative); continue }
            guard FileManager.default.fileExists(atPath: url.path) else { missing.append(relative); continue }
            do {
                let file = try AVAudioFile(forReading: url)
                if file.length == 0 || file.processingFormat.sampleRate <= 0 { unreadable.append(relative) }
            } catch { unreadable.append(relative) }
        }
        return Report(oneShots: shots.samples.count, loops: loops.loops.count, missing: missing, unreadable: unreadable)
    }
}
