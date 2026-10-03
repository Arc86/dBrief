import Foundation
import dBriefWire

enum LiveVADBoundaryError: Error, Equatable { case invalidConfiguration, invalidWindow }

/// Scheduling classification only; this cannot certify acoustic silence.
enum LiveVADThresholdClass: Sendable, Equatable { case entry, band, belowExit }
struct LiveVADBoundaryDecision: Sendable, Equatable {
    let range: LiveSampleRange
    let thresholdClass: LiveVADThresholdClass
    /// Actual completed window end, with no external barrier/ACK authority.
    let flushEnd: Int64?
}

/// One source continuity's constant-size scheduling state. Ordinary ASR
/// flushes preserve it; fresh source continuity creates a fresh policy.
struct LiveVADBoundaryPolicy: Sendable, Equatable {
    let identity: LiveVADIdentity
    let source: LiveSource
    let continuityID: UUID
    private(set) var processedEnd: Int64
    private(set) var speechArmed = false
    private(set) var quietSamples = 0

    init(identity: LiveVADIdentity, source: LiveSource, continuityID: UUID, sampleStart: Int64 = 0) throws {
        guard identity.isValid, identity.runtimeRevision == LiveVADNativeConfiguration.runtimeRevision,
              identity.implementationRevision == LiveVADIdentity.currentImplementationRevision,
              source.isCaptureSource, sampleStart >= 0 else { throw LiveVADBoundaryError.invalidConfiguration }
        self.identity = identity; self.source = source; self.continuityID = continuityID; processedEnd = sampleStart
    }

    mutating func observe(_ window: LiveVADWindowResult) throws -> LiveVADBoundaryDecision {
        let end = window.sampleStart.addingReportingOverflow(Int64(LiveVADIdentity.windowSamples))
        guard window.source == source, window.continuityID == continuityID,
              window.sampleStart == processedEnd, !end.overflow, end.partialValue == window.sampleEnd,
              window.probability.isFinite, (0...1).contains(window.probability) else { throw LiveVADBoundaryError.invalidWindow }
        // The whole result is validated before any mutation; no await or
        // throwing operation follows. Local IDs correlate, not authenticate.
        let classification: LiveVADThresholdClass
        var flushEnd: Int64?
        if window.probability >= identity.positiveThreshold {
            classification = .entry; speechArmed = true; quietSamples = 0
        } else if window.probability >= identity.negativeThreshold {
            classification = .band; quietSamples = 0
        } else {
            classification = .belowExit
            if speechArmed {
                // The frozen minimum is at most240000, so this addition is
                // bounded regardless of how many windows arrive.
                quietSamples = min(identity.minSilenceSamples,quietSamples+LiveVADIdentity.windowSamples)
                if quietSamples == identity.minSilenceSamples {
                    flushEnd = window.sampleEnd; speechArmed = false; quietSamples = 0
                }
            }
        }
        processedEnd = window.sampleEnd
        // Frozen padding is reserved for qualified evidence handling. It
        // cannot extend this scheduling proposal into unobserved samples.
        return .init(range: .init(start: window.sampleStart,end: window.sampleEnd),thresholdClass: classification,flushEnd: flushEnd)
    }
}
