import AppKit
import Foundation

/// Recording content is frozen by the caller before preparing its scope. The
/// latest copy intent wins if receipt I/O delays an earlier click.
@MainActor enum RecordingClipboard {
    private static var latestIntent = UUID()
    private enum CopyError: Error { case rejected }

    static func copy(_ text: String, for recording: Recording) async -> Bool {
        await copy(text, contextProvider: { await recording.privacyContext() })
    }
    static func copy(_ text: String, from audioURL: URL) async -> Bool {
        await copy(text, contextProvider: {
            let context = PrivacyTrace.Context(receiptURL: PrivacyReceiptStore.sidecarURL(for: audioURL))
            if !PrivacyTrace.coversAllProcessingStages { await context.store.noteGap(at: context.receiptURL) }
            return context
        })
    }

    static func copy(_ text: String,
                     contextProvider: () async -> PrivacyTrace.Context?,
                     write: (String) -> Bool = { text in
                         NSPasteboard.general.clearContents()
                         return NSPasteboard.general.setString(text, forType: .string)
                     }) async -> Bool {
        guard !text.isEmpty else { return false }
        let intent = UUID()
        latestIntent = intent
        let context = await contextProvider()
        guard latestIntent == intent else { return false }
        do {
            return try await PrivacyTrace.$context.withValue(context) {
                try await PrivacyTrace.perform(.init(stage: .clipboardExport, data: [.text, .metadata],
                                                     destination: .externallyManaged(provider: .clipboard))) {
                    guard latestIntent == intent else { throw CancellationError() }
                    guard write(text) else { throw CopyError.rejected }
                    return true
                }
            }
        } catch { return false }
    }
}
