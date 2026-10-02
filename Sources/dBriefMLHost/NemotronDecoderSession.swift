import Foundation

struct NemotronDecoderConfiguration: Sendable, Equatable {
    enum Language: String, Codable, Sendable { case en, nl, auto }
    let language: Language
    let chunkMs: Int
    var chunkSamples: Int { chunkMs * 16 }
    init(language: Language, chunkMs: Int = 1120) throws {
        guard [560, 1120, 2240].contains(chunkMs) else { throw NemotronSessionError.invalidConfiguration }
        self.language = language
        self.chunkMs = chunkMs
    }
}

enum NemotronSessionError: Error, Equatable {
    case invalidConfiguration, invalidPacket, unavailable, invalidAccounting, invalidTiming
}

struct NemotronDecoderProgress: Sendable, Equatable {
    let consumedSamples: Int64
    let heldSamples: Int64
}

/// SDK token emission frames, not acoustic word boundaries. Confidence is synthetic.
struct NemotronEmissionTiming: Sendable, Equatable {
    let token: String
    let startSeconds: Double
    let endSeconds: Double
}

struct NemotronDecoderOutput: Sendable, Equatable {
    let text: String
    let timings: [NemotronEmissionTiming]
}

struct NemotronCommittedUtterance: Sendable, Equatable {
    let generation: UUID
    let range: Range<Int64>
    let output: NemotronDecoderOutput
}

enum NemotronDecoderEvent: Sendable, Equatable {
    case ready(UUID, Int64)
    case partial(UUID, String)
    case progress(UUID, NemotronDecoderProgress)
    case committed(NemotronCommittedUtterance)
    case gap(Range<Int64>)
    case unavailable
}

protocol NemotronStreamingDecoder: Sendable {
    func process(samples: [Float]) async throws -> NemotronDecoderProgress
    func finish() async throws -> NemotronDecoderOutput
}

protocol NemotronDecoderMaking: Sendable {
    var modelFingerprint: String? { get }
    func makeDecoder(configuration: NemotronDecoderConfiguration,
                     partial: @escaping @Sendable (String) -> Void) async throws -> any NemotronStreamingDecoder
}

extension NemotronDecoderMaking { var modelFingerprint: String? { nil } }

/// Callback admission is synchronous: retirement also rejects SDK callbacks that
/// arrive outside the task which installed them. The sink must not block.
private final class NemotronPartialGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private let generation: UUID
    private let emit: @Sendable (NemotronDecoderEvent) -> Void
    init(generation: UUID, emit: @escaping @Sendable (NemotronDecoderEvent) -> Void) {
        self.generation = generation; self.emit = emit
    }
    func activate() { lock.withLock { active = true } }
    func retire() { lock.withLock { active = false } }
    func receive(_ text: String) {
        lock.withLock { if active { emit(.partial(generation, text)) } }
    }
}

/// Owns one lane. A lane-local mutex serializes whole operations across awaits;
/// it is independent of the ordinary helper's heavy-operation mutex.
actor NemotronDecoderSession {
    private let factory: any NemotronDecoderMaking
    private let emit: @Sendable (NemotronDecoderEvent) -> Void
    private let operations = AsyncMutex()
    private var decoder: (any NemotronStreamingDecoder)?
    private var gate: NemotronPartialGate?
    private var configuration: NemotronDecoderConfiguration?
    private var generation = UUID()
    private var origin: Int64 = 0
    private var end: Int64 = 0
    private var consumed: Int64 = 0
    private var retired = false

    init(factory: any NemotronDecoderMaking, emit: @escaping @Sendable (NemotronDecoderEvent) -> Void) {
        self.factory = factory; self.emit = emit
    }

    /// Immediate callback retirement does not await a native operation. The
    /// owner settles its queued/unprocessed input separately and never reuses
    /// this session. A native call may still unwind under the external deadline.
    func retire() {
        guard !retired else { return }
        discardProvisional()
        retired = true
    }

    @discardableResult
    func prepare(configuration: NemotronDecoderConfiguration, origin: Int64 = 0) async throws -> UUID {
        try await operations.withLock { try await self.prepareLocked(configuration, origin: origin) }
    }

    private func prepareLocked(_ configuration: NemotronDecoderConfiguration, origin: Int64) async throws -> UUID {
        guard !retired else { throw NemotronSessionError.unavailable }
        guard decoder == nil, origin >= end else { throw NemotronSessionError.invalidConfiguration }
        self.configuration = configuration
        self.origin = origin; end = origin; consumed = 0
        try await makeFreshDecoder()
        return generation
    }

    private func makeFreshDecoder() async throws {
        guard let configuration else { throw NemotronSessionError.unavailable }
        generation = UUID()
        let nextGate = NemotronPartialGate(generation: generation, emit: emit)
        do {
            let next = try await factory.makeDecoder(configuration: configuration, partial: nextGate.receive)
            guard !retired else { throw NemotronSessionError.unavailable }
            try Task.checkCancellation()
            decoder = next; gate = nextGate
            emit(.ready(generation, origin))
            nextGate.activate()
        } catch {
            nextGate.retire()
            if !retired { decoder = nil; gate = nil; emit(.unavailable) }
            throw error
        }
    }

    @discardableResult
    func append(samples: [Float], startSample: Int64) async throws -> NemotronDecoderProgress {
        try await operations.withLock { try await self.appendLocked(samples: samples, startSample: startSample) }
    }

    private func appendLocked(samples: [Float], startSample: Int64) async throws -> NemotronDecoderProgress {
        guard !retired else { throw NemotronSessionError.unavailable }
        let (nextEnd, overflow) = startSample.addingReportingOverflow(Int64(samples.count))
        guard !samples.isEmpty, samples.count <= 3200, samples.allSatisfy(\.isFinite),
              startSample == end, !overflow else { throw NemotronSessionError.invalidPacket }
        end = nextEnd
        guard let decoder else {
            emit(.gap(startSample..<end)); origin = end
            throw NemotronSessionError.unavailable
        }
        do {
            let progress = try await decoder.process(samples: samples)
            guard !retired else { throw NemotronSessionError.unavailable }
            try Task.checkCancellation()
            let count = end - origin
            guard progress.consumedSamples >= consumed, progress.consumedSamples <= count,
                  progress.heldSamples == count - progress.consumedSamples else {
                throw NemotronSessionError.invalidAccounting
            }
            consumed = progress.consumedSamples
            emit(.progress(generation, progress))
            return progress
        } catch {
            if !retired { discardProvisional() }
            throw error
        }
    }

    @discardableResult
    func finish(replacingDecoder: Bool = true) async throws -> NemotronCommittedUtterance {
        try await operations.withLock { try await self.finishLocked(replacingDecoder: replacingDecoder) }
    }

    private func finishLocked(replacingDecoder: Bool) async throws -> NemotronCommittedUtterance {
        guard !retired, let decoder else { throw NemotronSessionError.unavailable }
        let output: NemotronDecoderOutput
        do {
            output = try await decoder.finish()
            guard !retired else { throw NemotronSessionError.unavailable }
            try Task.checkCancellation()
        } catch {
            if !retired { discardProvisional() }
            throw error
        }
        // Copy the result before retirement; padding must not create evidence
        // outside the actual accepted input. Untimed text is retained.
        let duration = Double(end - origin) / 16000
        var clipped: [NemotronEmissionTiming] = []
        for timing in output.timings {
            guard timing.startSeconds.isFinite, timing.endSeconds.isFinite,
                  timing.startSeconds >= 0, timing.endSeconds >= timing.startSeconds else {
                discardProvisional()
                throw NemotronSessionError.invalidTiming
            }
            let start = min(duration, timing.startSeconds), stop = min(duration, timing.endSeconds)
            if stop > start { clipped.append(.init(token: timing.token, startSeconds: start, endSeconds: stop)) }
        }
        let committed = NemotronCommittedUtterance(generation: generation, range: origin..<end,
            output: .init(text: output.text, timings: clipped))
        gate?.retire(); gate = nil; self.decoder = nil
        emit(.committed(committed))
        origin = end; consumed = 0
        if replacingDecoder { try await makeFreshDecoder() }
        return committed
    }

    private func discardProvisional() {
        gate?.retire(); gate = nil; decoder = nil
        if end > origin { emit(.gap(origin..<end)) }
        origin = end; consumed = 0
        emit(.unavailable)
    }
}
