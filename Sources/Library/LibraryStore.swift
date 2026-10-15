import Foundation

/// The pre-analyzed sample library (oneshots.json, loops.json, grooves.json) with absolute file URLs.
/// Falls back to the bundled `DefaultKit/manifest.json` (16 pads) and embedded grooves so pads are never empty.
final class LibraryStore {
    private(set) var root: URL
    private(set) var oneshots: [OneShot] = []
    private(set) var loops: [LoopEntry] = []
    /// Per-loop "how it sounds" scores from CLAP (vibes.json: loop id → tag → z-score), e.g. plugg, jazzy, rage.
    private(set) var vibes: [String: [String: Double]] = [:]
    private(set) var grooves: GroovesFile
    private(set) var byCategory: [String: [OneShot]] = [:]
    private(set) var isFallback = false
    private(set) var loadMs = 0
    private(set) var problems: [String] = []

    init(root: URL = AppConfig.libraryURL, bundle: Bundle = .main) {
        let t0 = Date()
        self.root = root
        self.grooves = GroovesFile(styles: [:], bankA: nil, grooves: [], fills: [], bassRhythms: [:])

        let fm = FileManager.default
        var roots = [root]
        roots.append(CrateStorage.documents.appendingPathComponent("library", isDirectory: true))
        let dec = JSONDecoder()
        for r in roots {
            guard let d1 = try? Data(contentsOf: r.appendingPathComponent("oneshots.json")) else { continue }
            do {
                let shots = try dec.decode(OneShotsFile.self, from: d1)
                self.root = r
                oneshots = shots.samples
                if let d2 = try? Data(contentsOf: r.appendingPathComponent("loops.json")) {
                    do { loops = try dec.decode(LoopsFile.self, from: d2).loops } catch { problems.append("loops.json: \(error)") }
                }
                if let dv = try? Data(contentsOf: r.appendingPathComponent("vibes.json")),
                   let v = try? JSONSerialization.jsonObject(with: dv) as? [String: Any],
                   let m = v["loops"] as? [String: [String: Double]] {
                    vibes = m
                }
                if let d3 = try? Data(contentsOf: r.appendingPathComponent("grooves.json")) {
                    do { grooves = try dec.decode(GroovesFile.self, from: d3) } catch { problems.append("grooves.json: \(error)") }
                }
                break
            } catch {
                problems.append("oneshots.json at \(r.path): \(error)")
            }
        }
        if oneshots.isEmpty { loadDefaultKit(bundle: bundle) }
        if grooves.styles.isEmpty || grooves.grooves.isEmpty {
            if let url = bundle.url(forResource: "grooves", withExtension: "json", subdirectory: "DefaultKit"),
               let d = try? Data(contentsOf: url), let g = try? dec.decode(GroovesFile.self, from: d) {
                grooves = g
            } else if let g = try? dec.decode(GroovesFile.self, from: Data(EmbeddedGrooves.json.utf8)) {
                grooves = g
            } else {
                problems.append("no grooves available")
            }
        }
        // Loops below 60 BPM are half-time detections; skip them.
        loops = loops.filter { $0.bpm >= 60 && $0.durationSec > 0.5 }
        byCategory = Dictionary(grouping: oneshots, by: { $0.category })
        loadMs = Int(Date().timeIntervalSince(t0) * 1000)
        DebugLog.event("library", ["root": self.root.path, "oneshots": oneshots.count, "loops": loops.count,
                                   "grooves": grooves.grooves.count, "fallback": isFallback, "ms": loadMs,
                                   "problems": problems.map { String($0.prefix(160)) }])
    }

    /// Absolute URL for a library-relative "file" field.
    func fileURL(_ relative: String) -> URL {
        relative.hasPrefix("/") ? URL(fileURLWithPath: relative) : root.appendingPathComponent(relative)
    }

    /// Candidates for a category, with related-category fallbacks when a category is empty.
    func candidates(_ category: String) -> [OneShot] {
        if let c = byCategory[category], !c.isEmpty { return c }
        let related: [String: [String]] = [
            "kick": ["808", "perc"], "snare": ["clap", "rim"], "clap": ["snare", "rim"], "hat": ["shaker", "openhat"],
            "openhat": ["hat", "cymbal"], "rim": ["perc", "snare"], "perc": ["rim", "shaker"], "shaker": ["hat", "perc"],
            "cymbal": ["openhat", "fx"], "808": ["bass", "kick"], "bass": ["808"], "fx": ["texture", "vocal"],
            "vocal": ["fx"], "texture": ["fx"], "keys": ["synth"], "synth": ["keys"],
        ]
        for r in related[category] ?? [] { if let c = byCategory[r], !c.isEmpty { return c } }
        return []
    }

    func styleInfo(_ s: Style) -> StyleInfo {
        grooves.style(s) ?? StyleInfo(label: s.rawValue.uppercased(), bpm: [85, 95], defaultBpm: 90, swing: 55,
                                      grooves: [], bass: s.rawValue, kit: KitTarget(dust: 0.5, brightness: 0.5, punch: 0.6),
                                      keywords: [s.rawValue])
    }

    func loop(id: String) -> LoopEntry? { loops.first { $0.id == id } }

    var summary: String {
        "\(oneshots.count) one-shots · \(loops.count) loops · \(grooves.grooves.count) grooves" + (isFallback ? " (DefaultKit)" : "")
    }

    // MARK: - Fallback: bundled DefaultKit (16 pads + one loop)

    private struct Manifest: Codable {
        struct File: Codable {
            var file: String
            var pad: Int?
            var name: String
            var category: String
            var rootNote: Int?
            var key: String?
            var bpm: Double?
            var durationSec: Double?
        }
        var files: [File]
    }

    private func loadDefaultKit(bundle: Bundle) {
        guard let url = bundle.url(forResource: "manifest", withExtension: "json", subdirectory: "DefaultKit"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            problems.append("DefaultKit manifest missing")
            return
        }
        isFallback = true
        let dir = url.deletingLastPathComponent()
        root = dir
        let neutral = Dictionary(uniqueKeysWithValues: Style.allCases.map { ($0.rawValue, 0.5) })
        for f in manifest.files {
            let name = (f.file as NSString).lastPathComponent
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) else { continue }
            if f.category == "loop" {
                let bpm = f.bpm ?? 90
                let dur = f.durationSec ?? 240 / bpm
                let bars = max(1, Int((dur / (240 / bpm)).rounded()))
                loops.append(LoopEntry(id: "DK_LOOP", file: name, name: f.name, instrument: "keys", bpm: bpm, bars: bars,
                                       durationSec: dur, key: f.key, keyConfidence: f.key == nil ? 0 : 0.8,
                                       source: "DefaultKit", styles: neutral, moods: ["nostalgic", "dreamy"]))
            } else {
                oneshots.append(OneShot(id: "DK\(f.pad ?? 0)", file: name, name: f.name, category: f.category, styles: neutral,
                                        durationSec: f.durationSec, rootNote: f.rootNote, key: f.key, source: "DefaultKit"))
            }
        }
    }
}
