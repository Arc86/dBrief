import Foundation
import dBriefWire

/// Synchronous frame ingestion reserves ordered receipt writes. A call drains
/// these before returning its result, without suspending the connection's frame
/// parser or conflating a nested stage failure with the parent call's outcome.
final class PrivacyMLTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let state: State
    private var pending: Task<Void, Never>?

    init(context: PrivacyTrace.Context) { state = State(context: context) }

    func receive(_ event: MLPrivacyEvent) {
        _ = enqueue { [state] in await state.receive(event) }
    }
    func noteMissingFrame() {
        _ = enqueue { [state] in await state.noteMissingFrame() }
    }
    func end(crashed: Bool) async {
        await enqueue { [state] in await state.end(crashed: crashed) }.value
    }
    private func enqueue(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.withLock {
            let previous = pending
            let task = Task { await previous?.value; await work() }
            pending = task
            return task
        }
    }

    private actor State {
        struct Entry {
            let token: PrivacyTrace.Token?
            var finished = false
        }
        let context: PrivacyTrace.Context
        var supported = false
        var closed = false
        var entries: [UUID: Entry] = [:]
        init(context: PrivacyTrace.Context) { self.context = context }

        func receive(_ event: MLPrivacyEvent) async {
            guard !closed else { await gap(); return }
            switch event {
            case .supported(let version):
                guard version == 1, !supported, entries.isEmpty else { await gap(); return }
                supported = true
            case .started(let id, let operation):
                guard supported, entries[id] == nil,
                      entries.count < PrivacyReceiptStore.maximumStoredAttempts else { await gap(); return }
                let destination: PrivacyDestination = operation == .speakerDiarization
                    ? .local(provider: .speakerKit)
                    : .local(provider: .fluidAudio, model: "fluidaudio-wespeaker-256")
                let token = await PrivacyTrace.begin(.init(stage: .speakerAnalysis, data: [.recordingAudio, .metadata],
                                                          destination: destination), in: context)
                entries[id] = Entry(token: token)
            case .finished(let id, let outcome):
                guard supported, var entry = entries[id], !entry.finished else { await gap(); return }
                entry.finished = true
                entries[id] = entry
                let terminal: PrivacyAttempt.Outcome = switch outcome {
                case .succeeded: .succeeded
                case .failed: .failed
                case .cancelled: .cancelled
                }
                await PrivacyTrace.finish(entry.token, outcome: terminal)
            }
        }
        func end(crashed: Bool) async {
            guard !closed else { return }
            closed = true
            // A crash can drop queued stdout, even after previously complete
            // stages. Leave open attempts uncertain; never invent their outcome.
            if crashed || !supported || entries.values.contains(where: { !$0.finished }) { await gap() }
        }
        func noteMissingFrame() async { await gap() }
        private func gap() async { await context.store.noteGap(at: context.receiptURL) }
    }
}
