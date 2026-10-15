import Foundation

/// Hand-analyzed songs for the drag-in demo (`<library>/demo_samples.json`): slice points, key, chords and the flip tempo.
/// A dropped/imported file whose name contains `match` (case/space-insensitive) skips the CHOP dialog and flips at once.
struct DemoSample: Codable, Hashable {
    var match: String
    var name: String? = nil
    var bpm: Double? = nil
    var key: String? = nil
    var bars: Int? = nil
    var durationSec: Double? = nil
    var slicesSec: [Double]? = nil
    var flipBpm: Double? = nil
    var chords: [String]? = nil
}

enum DemoSamples {
    static let all: [DemoSample] = {
        let url = AppConfig.libraryURL.appendingPathComponent("demo_samples.json")
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([DemoSample].self, from: data) else { return [] }
        return list
    }()

    static func normalize(_ s: String) -> String {
        s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
            .reduce(into: "") { out, c in if !(c == "_" && out.last == "_") { out.append(c) } }
    }

    static func match(_ name: String) -> DemoSample? {
        let n = normalize(name)
        return all.first { !$0.match.isEmpty && n.contains(normalize($0.match)) }
    }
}
