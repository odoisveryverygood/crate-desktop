import Foundation

/// "make a NewJeans type beat": common artist / producer references → the style, tempo and feel they imply.
/// KeywordParser uses it offline; Jev maps references it doesn't list (its style choices include every Style).
enum ArtistReferences {
    struct Ref {
        var name: String          // display name ("NewJeans")
        var words: [String]       // lowercase spellings matched as whole words
        var drum: Style
        var sample: Style? = nil  // nil = same as drum
        var bpm: Double? = nil
        var brightness: Double? = nil
        var energy: Double? = nil
        var laidback: Double? = nil
        var vintage: Double? = nil
        var mood: String? = nil
    }

    static let table: [Ref] = [
        // K-pop / Y2K club pop
        Ref(name: "NewJeans", words: ["newjeans", "new jeans", "nwjns", "ditto", "hype boy", "super shy"],
            drum: .jerseyclub, sample: .kpop, bpm: 136, brightness: 0.85, energy: 0.7, mood: "dreamy"),
        Ref(name: "PinkPantheress", words: ["pinkpantheress", "pink pantheress"], drum: .garage, sample: .kpop, bpm: 135,
            brightness: 0.75, energy: 0.6, mood: "nostalgic"),
        Ref(name: "LE SSERAFIM", words: ["le sserafim", "lesserafim"], drum: .jerseyclub, sample: .kpop, bpm: 132, brightness: 0.8, energy: 0.8),
        Ref(name: "ILLIT", words: ["illit"], drum: .jerseyclub, sample: .kpop, bpm: 132, brightness: 0.9, energy: 0.65),
        Ref(name: "BLACKPINK", words: ["blackpink", "black pink"], drum: .kpop, bpm: 124, brightness: 0.8, energy: 0.9),
        Ref(name: "BTS", words: ["bts"], drum: .kpop, sample: .rnb, bpm: 114, brightness: 0.8, energy: 0.75),
        Ref(name: "TWICE", words: ["twice type", "twice style", "twice kpop"], drum: .kpop, bpm: 120, brightness: 0.9, energy: 0.75, mood: "uplifting"),
        Ref(name: "aespa", words: ["aespa"], drum: .kpop, sample: .trap, bpm: 128, brightness: 0.75, energy: 0.9),
        Ref(name: "Stray Kids", words: ["stray kids", "skz"], drum: .trap, sample: .kpop, bpm: 140, energy: 0.95),
        // Garage / house / dance
        Ref(name: "Fred again..", words: ["fred again", "fred again.."], drum: .garage, sample: .house, bpm: 132, brightness: 0.6,
            energy: 0.65, mood: "nostalgic"),
        Ref(name: "Burial", words: ["burial"], drum: .garage, sample: .lofi, bpm: 136, brightness: 0.25, energy: 0.4, vintage: 0.8,
            mood: "melancholic"),
        Ref(name: "Craig David", words: ["craig david"], drum: .garage, sample: .rnb, bpm: 130, brightness: 0.65),
        Ref(name: "Disclosure", words: ["disclosure"], drum: .garage, sample: .house, bpm: 124, brightness: 0.7, energy: 0.7),
        Ref(name: "Kaytranada", words: ["kaytranada", "kaytra"], drum: .house, sample: .rnb, bpm: 112, brightness: 0.6, energy: 0.65,
            laidback: 0.5, mood: "groovy"),
        Ref(name: "Daft Punk", words: ["daft punk"], drum: .house, sample: .vintage, bpm: 122, brightness: 0.7, energy: 0.75, mood: "groovy"),
        Ref(name: "Calvin Harris", words: ["calvin harris"], drum: .kpop, sample: .house, bpm: 124, brightness: 0.85, energy: 0.8),
        Ref(name: "Dua Lipa", words: ["dua lipa"], drum: .kpop, sample: .house, bpm: 118, brightness: 0.85, energy: 0.8),
        Ref(name: "The Weeknd", words: ["the weeknd", "weeknd"], drum: .kpop, sample: .rnb, bpm: 118, brightness: 0.55, energy: 0.7,
            mood: "dark"),
        Ref(name: "Ice Spice", words: ["ice spice"], drum: .drill, sample: .jerseyclub, bpm: 144, energy: 0.85),
        Ref(name: "Lil Uzi Vert", words: ["lil uzi", "uzi vert", "lil uzi vert"], drum: .jerseyclub, sample: .trap, bpm: 140, energy: 0.9),
        // Afrobeats
        Ref(name: "Burna Boy", words: ["burna boy", "burna"], drum: .afrobeats, bpm: 104, brightness: 0.6, energy: 0.65, mood: "groovy"),
        Ref(name: "Wizkid", words: ["wizkid", "wiz kid"], drum: .afrobeats, sample: .rnb, bpm: 102, brightness: 0.6, energy: 0.6,
            mood: "smooth"),
        Ref(name: "Rema", words: ["rema"], drum: .afrobeats, bpm: 107, brightness: 0.7, energy: 0.65),
        Ref(name: "Tems", words: ["tems"], drum: .afrobeats, sample: .rnb, bpm: 100, brightness: 0.5, energy: 0.5, mood: "smooth"),
        Ref(name: "Davido", words: ["davido"], drum: .afrobeats, bpm: 108, brightness: 0.7, energy: 0.75, mood: "uplifting"),
        Ref(name: "Tyla", words: ["tyla"], drum: .afrobeats, sample: .rnb, bpm: 112, brightness: 0.65, energy: 0.6),
        // Trap / drill / rap
        Ref(name: "Metro Boomin", words: ["metro boomin", "metro"], drum: .trap, bpm: 140, brightness: 0.35, energy: 0.85, mood: "dark"),
        Ref(name: "Travis Scott", words: ["travis scott", "travis", "la flame"], drum: .trap, bpm: 145, brightness: 0.25, energy: 0.9,
            mood: "dark"),
        Ref(name: "Future", words: ["future hendrix"], drum: .trap, bpm: 140, brightness: 0.3, energy: 0.85, mood: "dark"),
        Ref(name: "21 Savage", words: ["21 savage"], drum: .trap, bpm: 142, brightness: 0.25, energy: 0.8, mood: "dark"),
        Ref(name: "Playboi Carti", words: ["playboi carti", "carti"], drum: .trap, bpm: 150, brightness: 0.6, energy: 0.95),
        Ref(name: "Pop Smoke", words: ["pop smoke"], drum: .drill, bpm: 142, brightness: 0.3, energy: 0.9, mood: "dark"),
        Ref(name: "Central Cee", words: ["central cee", "cench"], drum: .drill, sample: .rnb, bpm: 142, brightness: 0.45, energy: 0.8),
        Ref(name: "Drake", words: ["drake", "drizzy", "ovo"], drum: .rnb, sample: .rnb, bpm: 74, brightness: 0.4, energy: 0.5,
            mood: "smooth"),
        Ref(name: "Kendrick Lamar", words: ["kendrick", "kendrick lamar", "k dot"], drum: .boombap, sample: .jazzhop, bpm: 92,
            brightness: 0.45, energy: 0.7),
        Ref(name: "Kanye West", words: ["kanye", "kanye west"], drum: .boombap, sample: .vintage, bpm: 90, vintage: 0.75),
        Ref(name: "Tyler, the Creator", words: ["tyler the creator", "tyler, the creator"], drum: .boombap, sample: .rnb, bpm: 88,
            brightness: 0.6),
        Ref(name: "Mac Miller", words: ["mac miller"], drum: .jazzhop, sample: .rnb, bpm: 86, laidback: 0.6, mood: "warm"),
        Ref(name: "MF DOOM", words: ["mf doom", "madvillain", "madlib"], drum: .dilla, sample: .vintage, bpm: 90, vintage: 0.9),
        Ref(name: "Alchemist", words: ["alchemist", "the alchemist"], drum: .boombap, sample: .vintage, bpm: 86, vintage: 0.85, mood: "dark"),
        Ref(name: "Griselda", words: ["griselda", "westside gunn", "conway"], drum: .boombap, sample: .vintage, bpm: 84, energy: 0.6,
            vintage: 0.9, mood: "dark"),
        Ref(name: "A Tribe Called Quest", words: ["tribe called quest", "atcq", "q-tip"], drum: .boombap, sample: .jazzhop, bpm: 94,
            mood: "groovy"),
        Ref(name: "Mobb Deep", words: ["mobb deep"], drum: .boombap, bpm: 88, brightness: 0.25, mood: "dark"),
        // Lo-fi / jazz / soul
        Ref(name: "J Dilla", words: ["j dilla", "jay dee", "dilla"], drum: .dilla, bpm: 89, laidback: 0.85),
        Ref(name: "Nujabes", words: ["nujabes"], drum: .jazzhop, bpm: 90, mood: "melancholic"),
        Ref(name: "Joji", words: ["joji"], drum: .lofi, sample: .rnb, bpm: 78, brightness: 0.3, energy: 0.3, mood: "melancholic"),
        Ref(name: "Frank Ocean", words: ["frank ocean"], drum: .rnb, bpm: 72, brightness: 0.45, energy: 0.35, mood: "dreamy"),
        Ref(name: "SZA", words: ["sza"], drum: .rnb, bpm: 76, brightness: 0.5, energy: 0.4, mood: "smooth"),
        Ref(name: "Daniel Caesar", words: ["daniel caesar"], drum: .rnb, sample: .jazzhop, bpm: 70, mood: "warm"),
        Ref(name: "Steve Lacy", words: ["steve lacy"], drum: .rnb, sample: .vintage, bpm: 80, mood: "groovy"),
        Ref(name: "D'Angelo", words: ["d'angelo", "dangelo"], drum: .dilla, sample: .rnb, bpm: 86, laidback: 0.85, mood: "warm"),
        Ref(name: "Erykah Badu", words: ["erykah badu", "badu"], drum: .dilla, sample: .rnb, bpm: 88, laidback: 0.75),
        Ref(name: "Lofi Girl", words: ["lofi girl", "lo-fi girl"], drum: .lofi, bpm: 78, energy: 0.25, mood: "nostalgic"),
    ]

    /// The first (longest-spelling) reference in a normalized prompt, with the character range it matched.
    static func match(_ text: String) -> (ref: Ref, range: NSRange)? {
        var best: (Ref, NSRange)?
        for r in table {
            for w in r.words {
                guard let pos = KeywordParser.find(w, in: text).first else { continue }
                let range = NSRange(location: pos, length: (w as NSString).length)
                if best == nil || range.length > best!.1.length { best = (r, range) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }
}
