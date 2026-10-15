import AVFoundation

// iOS 26 support: iOS 27 renamed AVAudioEngine's connect / play / tap calls into throwing versions and hands taps
// a read-only buffer. These wrappers call the iOS 27 API when it's there (unchanged behaviour on 27+) and the older,
// now-deprecated call below it.

/// A master-tap buffer on any OS: iOS 27's `AVReadOnlyAudioPCMBuffer` or the older `AVAudioPCMBuffer`.
struct TapBuffer {
    let frameLength: Int
    let format: AVAudioFormat
    private let list: ((UnsafePointer<AudioBufferList>) -> Void) -> Void

    func withUnsafeAudioBufferList(_ body: (UnsafePointer<AudioBufferList>) -> Void) { list(body) }

    @available(iOS 27.0, macOS 27.0, *)
    init(_ b: AVReadOnlyAudioPCMBuffer) {
        frameLength = Int(b.frameLength)
        format = b.format
        list = { body in b.withUnsafeAudioBufferList { body($0) } }
    }

    init(_ b: AVAudioPCMBuffer) {
        frameLength = Int(b.frameLength)
        format = b.format
        list = { body in body(b.audioBufferList) }
    }
}

extension AVAudioEngine {
    /// `connect(_:to:format:)`: bus 0 → bus 0, or a mixer's next free input bus.
    func crateConnect(_ a: AVAudioNode, to b: AVAudioNode, format: AVAudioFormat?) throws {
        if #available(iOS 27.0, macOS 27.0, *) {
            try connectNode(a, to: b, format: format)
        } else {
            connect(a, to: b, format: format)
        }
    }

    func crateConnect(_ a: AVAudioNode, to b: AVAudioNode, fromBus: AVAudioNodeBus, toBus: AVAudioNodeBus,
                      format: AVAudioFormat?) throws {
        if #available(iOS 27.0, macOS 27.0, *) {
            try connectNode(a, to: b, fromBus: fromBus, toBus: toBus, format: format)
        } else {
            connect(a, to: b, fromBus: fromBus, toBus: toBus, format: format)
        }
    }
}

extension AVAudioPlayerNode {
    func cratePlay() throws {
        if #available(iOS 27.0, macOS 27.0, *) {
            try playAudio()
        } else {
            play()
        }
    }
}

extension AVAudioNode {
    func crateInstallTap(onBus bus: AVAudioNodeBus, bufferSize: AVAudioFrameCount, format: AVAudioFormat?,
                         block: @escaping (TapBuffer, AVAudioTime) -> Void) throws {
        if #available(iOS 27.0, macOS 27.0, *) {
            try installAudioTap(onBus: bus, bufferSize: bufferSize, format: format) { buf, time in
                block(TapBuffer(buf), time)
            }
        } else {
            installTap(onBus: bus, bufferSize: bufferSize, format: format) { buf, time in
                block(TapBuffer(buf), time)
            }
        }
    }
}
