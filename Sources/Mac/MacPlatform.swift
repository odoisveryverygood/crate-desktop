import SwiftUI
import AppKit

/// Mac screen capabilities; the existing lid/deck layout uses the tablet density.
enum DeviceInfo {
    static let hasHardwareKeyboard = true
    static let isPad = true
    static let simulatorDuo = false
    static let rememberedDuo = false
    static let machine = "Mac"
    static var windowEdgeInsets: EdgeInsets { EdgeInsets() }
    static func rememberDuo() {}
}

enum MacExportError {
    @MainActor static func show(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't save export"
        alert.informativeText = message
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}

/// SwiftUI panels explicitly report their stack on Mac, without inspecting UIKit controllers.
@MainActor final class ScreenTracker {
    static let shared = ScreenTracker()
    var base = "main"
    private var overlays: [(String, String)] = []
    var current: String { overlays.last?.0 ?? base }
    func setBase(_ name: String) { base = name; publish() }
    func push(_ name: String, token: String) { overlays.removeAll { $0.1 == token }; overlays.append((name, token)); publish() }
    func pop(token: String) { overlays.removeAll { $0.1 == token }; publish() }
    private func publish() { Analytics.shared.recordScreen(current) }
}
struct MacScreenModifier: ViewModifier {
    let name: String
    @State private var token = UUID().uuidString
    func body(content: Content) -> some View {
        content.onAppear { ScreenTracker.shared.push(name, token: token) }
            .onDisappear { ScreenTracker.shared.pop(token: token) }
    }
}
extension View {
    func analyticsScreen(_ name: String) -> some View { modifier(MacScreenModifier(name: name)) }
}
