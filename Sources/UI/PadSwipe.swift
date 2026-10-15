import SwiftUI

/// Pad swipes on the plain pad layer: ↓ = pull-to-talk (VoiceDig), ↑ = remove the pad, ← → = previous / next sound
/// of the same kind. Touch-down always plays first; a swipe needs one deliberate finger (a second finger cancels it),
/// a dominant axis (≥ 1.5×) and stays within ~1.5 pads, so finger drumming never triggers one.
struct PadSwipe {
    enum Axis { case up, horizontal }

    /// The finger must move this far before the axis is decided (same as the pull's start).
    static let decide: CGFloat = 12
    /// Dominant axis ÷ the other one.
    static let ratio: CGFloat = 1.5
    /// Release past these to commit.
    static let removeAt: CGFloat = 44
    static let swapAt: CGFloat = 40
    /// Wandering farther than this many pad widths / heights = playing, not swiping.
    static let reach: CGFloat = 1.5

    let id: ObjectIdentifier
    let pad: PadID
    let start: CGPoint
    var axis: Axis? = nil
    var delta: CGSize = .zero
    /// Past the threshold (a selection tick when it arms).
    var armed = false

    /// Whether releasing here commits.
    var commits: Bool {
        let dx = delta.width, dy = delta.height
        switch axis {
        case .up: return -dy >= Self.removeAt && -dy >= abs(dx) * Self.ratio
        case .horizontal: return abs(dx) >= Self.swapAt && abs(dx) >= abs(dy) * Self.ratio
        case nil: return false
        }
    }

    /// The live preview: ↑ lifts and fades the pad's name with the finger; ← → lets it follow the finger a little.
    var preview: PadPose {
        switch axis {
        case .up:
            let p = min(1.2, max(0, -delta.height / Self.removeAt))
            return PadPose(nameOffset: CGSize(width: 0, height: -min(26, 22 * p)), nameOpacity: 1 - 0.65 * min(1, p),
                           cellOffset: CGSize(width: 0, height: -3 * min(1, p)), cellScale: 1 - 0.03 * min(1, p))
        case .horizontal:
            let dx = delta.width
            let p = min(1, abs(dx) / Self.swapAt)
            return PadPose(nameOffset: CGSize(width: max(-30, min(30, dx * 0.5)), height: 0), nameOpacity: 1 - 0.45 * p,
                           cellOffset: CGSize(width: max(-4, min(4, dx * 0.08)), height: 0))
        case nil:
            return PadPose()
        }
    }
}

/// How a pad is drawn mid-swipe: its name (label) moves inside the pad, the pad itself barely moves.
struct PadPose {
    var nameOffset: CGSize = .zero
    var nameOpacity: Double = 1
    var cellOffset: CGSize = .zero
    var cellScale: CGFloat = 1
}

/// A committed swipe's animation, driven by the pad grid's 60 fps timeline.
struct PadMotion {
    enum Kind: Equatable {
        /// ← →: the name slides out in the swipe direction; the new one slides in from the other side.
        case swap(dir: CGFloat)
        /// ↑: the name slides up and fades; the pad settles empty.
        case remove
        /// Nothing to swap: a gentle sideways shake.
        case shake
        /// ↑ on an empty pad: a small bump.
        case bump
        /// Released before the threshold: back to rest.
        case settle
    }

    var kind: Kind
    var start: Date
    /// The name's offset when the finger let go (the animation picks up from there).
    var from: CGSize
    /// When the change landed (the new name is on the pad): the slide-in starts then.
    var inAt: Date? = nil

    static let outDur = 0.14
    static let inDur = 0.2

    func pose(now: Date, width: CGFloat) -> PadPose {
        let t = now.timeIntervalSince(start)
        func ease(_ x: Double) -> Double { let c = min(1, max(0, x)); return 1 - pow(1 - c, 3) }
        var slide: (horizontal: Bool, d: CGFloat)? = nil
        if case .swap(let k) = kind { slide = (true, k) } else if kind == .remove { slide = (false, -1) }
        if let (horizontal, d) = slide {
            let travel = horizontal ? width * 0.8 : 40
            func at(_ k: CGFloat) -> CGSize { horizontal ? CGSize(width: k, height: 0) : CGSize(width: 0, height: k) }
            let fromK = horizontal ? from.width : from.height
            if t < Self.outDur {
                let e = ease(t / Self.outDur)
                return PadPose(nameOffset: at(fromK + (d * travel - fromK) * e), nameOpacity: (1 - e) * 0.6)
            }
            // hidden until the new sound landed (≤ 1 s), then in from the other side (↑: the empty pad fades in)
            let landed = max(start.addingTimeInterval(Self.outDur), inAt ?? start.addingTimeInterval(1))
            let u = now.timeIntervalSince(landed)
            guard u >= 0 else { return PadPose(nameOffset: at(d * travel), nameOpacity: 0) }
            let e = ease(u / Self.inDur)
            let enter: CGFloat = horizontal ? -d * travel : 8
            return PadPose(nameOffset: at(enter * (1 - e)), nameOpacity: e)
        }
        switch kind {
        case .shake:
            let dur = 0.36
            guard t < dur else { return PadPose() }
            let x = sin(t / dur * 3 * 2 * .pi) * 5 * (1 - t / dur)
            return PadPose(nameOffset: CGSize(width: x * 1.4, height: 0), cellOffset: CGSize(width: x, height: 0))
        case .bump:
            let dur = 0.22
            guard t < dur else { return PadPose() }
            return PadPose(cellOffset: CGSize(width: 0, height: -4 * sin(.pi * t / dur)))
        case .settle:
            let dur = 0.16
            guard t < dur else { return PadPose() }
            let e = ease(t / dur)
            return PadPose(nameOffset: CGSize(width: from.width * (1 - e), height: from.height * (1 - e)),
                           nameOpacity: 0.6 + 0.4 * e)
        default:
            return PadPose()
        }
    }
}
