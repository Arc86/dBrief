import Foundation
import dBriefWire

/// Injectable adapter for one capture's preview. Stop is terminal: it latches
/// against later Start calls and joins any channel work already dispatched.
struct CaptureLivePreview: Sendable {
    struct Inputs: Sendable {
        let mic: AsyncStream<LiveAudioBuffer>?
        let system: AsyncStream<LiveAudioBuffer>?
        let language: String
    }
    enum Event: Sendable {
        case finalized([LiveTranscriptSegment])
        case volatile(String, String)
        case status(String)
    }
    struct Session: Sendable {
        var start: @Sendable (Inputs, @escaping @Sendable (Event) -> Void) async -> Void
        var stop: @Sendable () async -> Void
    }
    var prepare: @Sendable (CaptureCoordinator.Request) async -> PrivacyTrace.Context?
    var make: @MainActor @Sendable () -> Session

    static func live() -> Self {
        .init(prepare: { request in
            guard let scope = request.privacyScope else { return nil }
            let context = await scope.context()
            if !PrivacyTrace.coversAllProcessingStages { await scope.store.noteGap(at: scope.pendingReceiptURL) }
            return context
        }, make: {
            let service = LiveTranscriptionService()
            return .init(start: { input, emit in
                await service.start(mic: input.mic, system: input.system, language: input.language,
                    onFinalized: { emit(.finalized($0)) }, onVolatile: { emit(.volatile($0, $1)) },
                    onStatus: { emit(.status($0)) })
            }, stop: { await service.stop() })
        })
    }
}
