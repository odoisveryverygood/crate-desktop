import SwiftUI
import AppKit

struct MacTouchSurface: NSViewRepresentable {
    var handler: (TouchPhaseUI, ObjectIdentifier, CGPoint) -> Void
    func makeNSView(context: Context) -> TouchTrackingView { let view = TouchTrackingView(); view.handler = handler; return view }
    func updateNSView(_ view: TouchTrackingView, context: Context) { view.handler = handler }
    static func dismantleNSView(_ view: TouchTrackingView, coordinator: ()) { view.finish() }
}
final class TouchTrackingView: NSView {
    var handler: ((TouchPhaseUI, ObjectIdentifier, CGPoint) -> Void)?
    override var isFlipped: Bool { true }
    private var deactivateObserver: NSObjectProtocol?
    private var pressed = false
    private var point = CGPoint.zero
    private static var live = Set<ObjectIdentifier>()
    static func isDown(_ id: ObjectIdentifier) -> Bool { live.contains(id) }
    override func mouseDown(with event: NSEvent) {
        pressed = true
        Self.live.insert(ObjectIdentifier(self))
        TouchClock.lastBegan = event.timestamp
        point = convert(event.locationInWindow, from: nil)
        handler?(.began, ObjectIdentifier(self), point)
    }
    override func mouseDragged(with event: NSEvent) {
        point = convert(event.locationInWindow, from: nil)
        handler?(.moved, ObjectIdentifier(self), point)
    }
    override func mouseUp(with event: NSEvent) { point = convert(event.locationInWindow, from: nil); finish() }
    func finish() {
        guard pressed else { return }
        pressed = false
        Self.live.remove(ObjectIdentifier(self))
        handler?(.ended, ObjectIdentifier(self), point)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        finish()
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        deactivateObserver = nil
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        deactivateObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                   object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }
    deinit { if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) } }
}
