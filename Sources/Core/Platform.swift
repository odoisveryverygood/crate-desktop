import AVFoundation
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Platform lifecycle names keep the project store and analytics independent of UI frameworks.
enum CrateLifecycle {
    #if os(iOS)
    static let saveNotification = UIApplication.didEnterBackgroundNotification
    static let activeNotification = UIApplication.willEnterForegroundNotification
    static let deviceName = UIDevice.current.model
    #else
    static let saveNotification = NSApplication.willResignActiveNotification
    static let activeNotification = NSApplication.didBecomeActiveNotification
    static let deviceName = "Mac"
    #endif
}

enum CrateMicrophone {
    enum Permission { case granted, denied, undetermined }
    static var permission: Permission {
        #if os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .undetermined
        }
        #endif
    }
    static func requestPermission() async -> Bool {
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
}
#if os(iOS)
typealias CratePlatformImage = UIImage
#else
typealias CratePlatformImage = NSImage
// Mac has no iPhone haptic generator. Preserve shared gesture behavior without vibrating.
struct UIImpactFeedbackGenerator {
    enum Style { case light, medium, heavy, soft, rigid }
    init(style: Style) {}
    func impactOccurred(intensity: CGFloat = 1) {}
}
struct UISelectionFeedbackGenerator { func selectionChanged() {} }
#endif

/// App-managed media never spills into the user's Documents root on Mac.
enum CrateStorage {
    static var documents: URL {
        #if os(iOS)
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #else
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CRATE", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
        #endif
    }
}

extension View {
    @ViewBuilder func crateDecimalKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}
