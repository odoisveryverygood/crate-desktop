import SwiftUI

enum TouchPhaseUI { case began, moved, ended }

#if canImport(UIKit)
import UIKit

/// Transparent multi-touch layer. SwiftUI gestures serialize fingers across sibling views, so pads and keys
/// use this: every finger is tracked on its own, `began` fires on touch-down (lowest latency), `moved` allows
/// glissando. Visuals (and accessibility elements) sit underneath; AXe taps land here by coordinate.
struct TouchSurface: UIViewRepresentable {
    var handler: (TouchPhaseUI, ObjectIdentifier, CGPoint) -> Void

    func makeUIView(context: Context) -> TouchTrackingView {
        let v = TouchTrackingView()
        v.handler = handler
        return v
    }

    func updateUIView(_ v: TouchTrackingView, context: Context) {
        v.handler = handler
    }
}

final class TouchTrackingView: UIView {
    var handler: ((TouchPhaseUI, ObjectIdentifier, CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Touches currently down on any surface (weak), so pull-to-talk can ask whether its finger is still there even
    /// if an end event never arrived (the view left the window mid-touch).
    private static var live: [ObjectIdentifier: WeakTouch] = [:]
    private final class WeakTouch { weak var touch: UITouch?; init(_ t: UITouch) { touch = t } }

    static func isDown(_ id: ObjectIdentifier) -> Bool {
        guard let t = live[id]?.touch, t.window != nil else { return false }
        return t.phase != .ended && t.phase != .cancelled
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            TouchClock.lastBegan = t.timestamp
            Self.live[ObjectIdentifier(t)] = WeakTouch(t)
            handler?(.began, ObjectIdentifier(t), t.location(in: self))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { handler?(.moved, ObjectIdentifier(t), t.location(in: self)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            Self.live[ObjectIdentifier(t)] = nil
            handler?(.ended, ObjectIdentifier(t), t.location(in: self))
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            Self.live[ObjectIdentifier(t)] = nil
            handler?(.ended, ObjectIdentifier(t), t.location(in: self))
        }
    }
}
#else
typealias TouchSurface = MacTouchSurface
#endif
