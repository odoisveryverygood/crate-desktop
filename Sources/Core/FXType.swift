import Foundation

/// MPC-Sample-style PAD FX. The hinge (or the on-screen FX knob) sets the amount 0…1 of the selected effect;
/// `nil` = the default PUNCH chain (LP filter + crush + delay + reverb, breakdown > 0.92).
enum FXType: String, CaseIterable, Codable, Hashable {
    case beatRepeat = "repeat", crush, delay, reverb
    case ringMod = "ring", lofi, color, granular
    case comb, lpFilter = "lpf", hpFilter = "hpf", bpFilter = "bpf"
    case halfSpeed = "half", radio, dub

    var label: String {
        switch self {
        case .beatRepeat: return "BEAT REPEAT"
        case .crush: return "CRUSH"
        case .delay: return "DELAY"
        case .reverb: return "REVERB"
        case .ringMod: return "RING MOD"
        case .lofi: return "LOFI"
        case .color: return "COLOR"
        case .granular: return "GRANULAR"
        case .comb: return "COMB"
        case .lpFilter: return "LP FILTER"
        case .hpFilter: return "HP FILTER"
        case .bpFilter: return "BP FILTER"
        case .halfSpeed: return "HALF SPEED"
        case .radio: return "RADIO"
        case .dub: return "DUB ECHO"
        }
    }

    /// What the amount does, for the pad's second line / the lid.
    var hint: String {
        switch self {
        case .beatRepeat: return "1/8 · 1/16 · 1/32"
        case .crush: return "BIT DECIMATE"
        case .delay: return "3/16 SYNC"
        case .reverb: return "LARGE HALL"
        case .ringMod: return "80HZ → 1.5K"
        case .lofi: return "BITBRUSH + LPF"
        case .color: return "TILT EQ"
        case .granular: return "BUFFER BEATS"
        case .comb: return "10 → 1.5MS"
        case .lpFilter: return "CUTOFF ↓"
        case .hpFilter: return "CUTOFF ↑"
        case .bpFilter: return "BAND SQUEEZE"
        case .halfSpeed: return "TAPE ×0.5"
        case .radio: return "RADIO TOWER"
        case .dub: return "3/8 FEEDBACK"
        }
    }

    /// 4×4 PAD FX layout by pad index (0 = pad 1 bottom-left, MPC order; top row = pads 13–16),
    /// mirroring the MPC Sample screen. nil = PUNCH (the default hinge chain).
    static let padLayout: [FXType?] = [
        .halfSpeed, .radio, .dub, nil,               // pads 1–4 (bottom row)
        .comb, .lpFilter, .hpFilter, .bpFilter,      // pads 5–8
        .ringMod, .lofi, .color, .granular,          // pads 9–12
        .beatRepeat, .crush, .delay, .reverb,        // pads 13–16 (top row)
    ]

    /// Router / test names: raw value, label ("lp filter", "lpfilter"), or "punch"/"none"/"off" → .some(nil).
    static func parse(_ s: String) -> FXType?? {
        let k = s.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
        if ["punch", "none", "off", "default", "nil"].contains(k) { return .some(nil) }
        if let t = FXType(rawValue: k) { return .some(t) }
        if let t = allCases.first(where: { $0.label.lowercased().replacingOccurrences(of: " ", with: "") == k }) { return .some(t) }
        let aliases: [String: FXType] = ["beatrepeat": .beatRepeat, "ringmod": .ringMod, "lp": .lpFilter, "hp": .hpFilter,
                                         "bp": .bpFilter, "halfspeed": .halfSpeed, "tape": .halfSpeed, "stutter": .granular,
                                         "dubecho": .dub, "echo": .dub, "bitcrush": .crush]
        if let t = aliases[k] { return .some(t) }
        return nil
    }
}

extension SamplerEngine {
    /// Default for engines without PAD FX (MockEngine): ignore.
    func setFX(_ type: FXType?) {}
    /// Default for engines without a jam buffer (MockEngine).
    func jamInfo() -> (count: Int, age: Double) { (0, .infinity) }
    func captureJam(_ done: @escaping @MainActor (Int) -> Void) { Task { @MainActor in done(0) } }
}

extension AppState {
    var fx: FXType? { fxType.flatMap { FXType(rawValue: $0) } }

    /// Select the PAD FX the hinge / knob drives (nil = PUNCH default chain).
    func selectFX(_ t: FXType?) {
        guard fxType != t?.rawValue else { return }
        fxType = t?.rawValue
        engine.setFX(t)
        DebugLog.event("fx", ["t": t?.rawValue ?? "punch", "amt": (punch * 100).rounded() / 100])
    }
}
