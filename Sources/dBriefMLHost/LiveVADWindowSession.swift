import Foundation
import dBriefWire

protocol LiveVADPredicting: Sendable {
    func predict(_ input: LiveVADNativeInput) async throws -> LiveVADNativeOutput
}
enum LiveVADWindowError: Error, Equatable { case invalidWindow, overlap, inactive }
struct LiveVADWindowResult: Sendable, Equatable {
    let source: LiveSource
    let continuityID: UUID
    let sampleStart: Int64
    let sampleEnd: Int64
    let probability: Float
}
struct LiveVADWindowProgress: Sendable, Equatable {
    let processedEnd: Int64
    let hasInFlight: Bool
    let isActive: Bool
}

/// Isolated inference state, not a packet pump or evidence/credit authority.
/// Fresh source continuity creates a fresh actor; ASR flushes do not reset it.
actor LiveVADWindowSession {
    nonisolated let source: LiveSource
    nonisolated let continuityID = UUID()
    private let predictor: any LiveVADPredicting
    private var context = [Float](repeating: 0,count: 64)
    private var hidden = [Float](repeating: 0,count: 128)
    private var cell = [Float](repeating: 0,count: 128)
    private var processedEnd: Int64
    private var inFlight = false
    private var active = true
    init(source: LiveSource, predictor: any LiveVADPredicting, sampleStart: Int64 = 0) throws {
        guard source.isCaptureSource, sampleStart >= 0 else { throw LiveVADWindowError.invalidWindow }
        self.source = source; self.predictor = predictor; processedEnd = sampleStart
    }
    func progress() -> LiveVADWindowProgress { .init(processedEnd: processedEnd,hasInFlight: inFlight,isActive: active) }
    func retire() {
        active = false
        context = [Float](repeating: 0,count: 64); hidden = [Float](repeating: 0,count: 128); cell = hidden
        // Logical sealing is not actual invocation/input retirement.
    }
    func process(samples: [Float], startSample: Int64) async throws -> LiveVADWindowResult {
        try Task.checkCancellation()
        guard active else { throw LiveVADWindowError.inactive }
        guard !inFlight else { throw LiveVADWindowError.overlap }
        let end = startSample.addingReportingOverflow(Int64(LiveVADIdentity.windowSamples))
        guard startSample == processedEnd, !end.overflow, samples.count == LiveVADIdentity.windowSamples else {
            throw LiveVADWindowError.invalidWindow
        }
        let input: LiveVADNativeInput
        do { input = try .init(audio: context+samples,hiddenState: hidden,cellState: cell) }
        catch { throw LiveVADWindowError.invalidWindow }
        inFlight = true
        defer { withExtendedLifetime(input) {}; inFlight = false }
        try Task.checkCancellation()
        let output = try await predictor.predict(input)
        try Task.checkCancellation()
        guard active else { throw LiveVADWindowError.inactive }
        // No await between these checks and the whole successful state commit.
        context = Array(samples.suffix(64)); hidden = output.hiddenState; cell = output.cellState; processedEnd = end.partialValue
        return .init(source: source,continuityID: continuityID,sampleStart: startSample,sampleEnd: end.partialValue,probability: output.probability)
    }
}
