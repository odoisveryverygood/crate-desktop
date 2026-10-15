import Foundation

extension AudioEngine {
    /// Capture from the next bar and publish only a finalized, sample-counted WAV.
    func bounce(bars: Int = 4, title: String) async throws -> URL {
        let operation = BounceOperation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    let capture = try MasterBounce(engine: self, bars: bars, title: title) { result in
                        operation.clear()
                        continuation.resume(with: result)
                    }
                    operation.install(capture)
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: { operation.cancel() }
    }

    enum BounceError: LocalizedError {
        case playbackRequired, busy, interrupted, timedOut
        var errorDescription: String? {
            switch self {
            case .playbackRequired: return "Start playback before bouncing."
            case .busy: return "A bounce is already running."
            case .interrupted: return "Bounce cancelled because playback, tempo, or the audio route changed."
            case .timedOut: return "No audio arrived. Start playback and try again."
            }
        }
    }
}

/// Owns the capture across suspension and handles cancellation before installation.
private final class BounceOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var capture: MasterBounce?
    private var cancelled = false
    func install(_ value: MasterBounce) {
        let shouldCancel = lock.withLock { capture = value; return cancelled }
        if shouldCancel { value.cancel() }
    }
    func clear() { lock.withLock { capture = nil } }
    func cancel() {
        let value = lock.withLock { cancelled = true; return capture }
        value?.cancel()
    }
}
