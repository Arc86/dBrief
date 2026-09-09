import Foundation
import AVFoundation
import dBriefWire

/// Processing data flow. Observable Recording/AppState ownership stays in the UI
/// façade while this actor sequences backend calls and transforms their results.
actor ProcessingPipeline {
    struct Input: Sendable {
        let audioURL: URL
        let segmentURLs: [URL]
    }
    struct TranscriptionOptions: Sendable {
        let removeFillerWords: Bool
        let ignoredSegments: Set<String>
        var modelName: String? = nil
    }
    struct AudioRequest: Sendable, Equatable {
        let url: URL
        let segmentIndex: Int?
        let segmentCount: Int?
    }
    struct TranscriptionOutput: Sendable {
        let transcription: TranscriptionResult
        let spellCorrectionTime: TimeInterval?
    }
    enum Event: Sendable, Equatable {
        case transcribingSegment(index: Int, count: Int)
        case correctingVocabulary
    }

    let metadataStore: RecordingMetadataStore
    let transcriptFiles: TranscriptFiles
    let duration: @Sendable (URL) async -> Double
    let now: @Sendable () -> Date
    private let cleanup: @Sendable (TranscriptionResult, TranscriptionOptions) -> TranscriptionResult

    init(duration: @escaping @Sendable (URL) async -> Double = ProcessingPipeline.probeDuration,
         now: @escaping @Sendable () -> Date = { Date() },
         cleanup: @escaping @Sendable (TranscriptionResult, TranscriptionOptions) -> TranscriptionResult = {
             TranscriptCleanup.clean($0, removeFillerWords: $1.removeFillerWords, ignoredSegments: $1.ignoredSegments)
         }, transcriptFiles: TranscriptFiles = .init(), metadataStore: RecordingMetadataStore = .shared) {
        self.metadataStore = metadataStore
        self.transcriptFiles = transcriptFiles
        self.duration = duration
        self.now = now
        self.cleanup = cleanup
    }

    func transcribe(_ input: Input, options: TranscriptionOptions,
                    using transcribeFile: @Sendable (AudioRequest) async throws -> TranscriptionResult,
                    correct: (@Sendable (TranscriptionResult) async -> TranscriptionResult)? = nil,
                    onEvent: @Sendable (Event) async -> Void = { _ in }) async throws -> TranscriptionOutput {
        try Task.checkCancellation()
        let raw: TranscriptionResult
        if input.segmentURLs.isEmpty {
            raw = try await transcribeFile(.init(url: input.audioURL, segmentIndex: nil, segmentCount: nil))
        } else {
            raw = try await transcribeSegments(input.segmentURLs, using: transcribeFile, onEvent: onEvent)
        }
        try Task.checkCancellation()
        var cleaned = cleanup(raw, options)
        cleaned.modelName = options.modelName
        try Task.checkCancellation()
        guard let correct else { return .init(transcription: cleaned, spellCorrectionTime: nil) }
        await onEvent(.correctingVocabulary)
        try Task.checkCancellation()
        let start = now()
        var corrected = await correct(cleaned)
        try Task.checkCancellation()
        // Correction owns spelling only; ASR provenance belongs to the pass.
        corrected.modelName = options.modelName
        return .init(transcription: corrected, spellCorrectionTime: now().timeIntervalSince(start))
    }

    private func transcribeSegments(_ urls: [URL],
                                    using transcribeFile: @Sendable (AudioRequest) async throws -> TranscriptionResult,
                                    onEvent: @Sendable (Event) async -> Void) async throws -> TranscriptionResult {
        let segments = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var pieces: [SegmentTranscriptionPiece] = []
        pieces.reserveCapacity(segments.count)
        var cumulativeOffset = 0.0
        var warnings: [String] = []
        var language: String?
        var inferenceSum: TimeInterval?
        var diarizationSum: TimeInterval?
        for (index, segmentURL) in segments.enumerated() {
            try Task.checkCancellation()
            let number = index + 1
            await onEvent(.transcribingSegment(index: number, count: segments.count))
            try Task.checkCancellation()
            let result = try await transcribeFile(.init(url: segmentURL, segmentIndex: number, segmentCount: segments.count))
            try Task.checkCancellation()
            if let time = result.inferenceTime { inferenceSum = (inferenceSum ?? 0) + time }
            if let time = result.diarizationTime { diarizationSum = (diarizationSum ?? 0) + time }
            if language == nil, let detected = result.language, !detected.isEmpty { language = detected }
            if let details = result.warnings { warnings.append(contentsOf: details.map { "Segment \(number): \($0)" }) }
            pieces.append(.init(offsetSeconds: cumulativeOffset, text: result.text, segments: result.segments,
                                speakerEmbeddings: result.speakerEmbeddings, modelName: result.modelName))
            let segmentDuration = await duration(segmentURL)
            try Task.checkCancellation()
            cumulativeOffset += max(segmentDuration, result.segments.last?.end ?? 1, 1)
        }
        let merged = Self.mergeSegmentTranscriptions(pieces)
        return .init(text: merged.text, segments: merged.segments, language: language,
                     warnings: warnings.isEmpty ? nil : warnings, speakerCount: merged.speakerCount,
                     inferenceTime: inferenceSum, diarizationTime: diarizationSum,
                     speakerEmbeddings: merged.speakerEmbeddings, modelName: merged.modelName)
    }

    private nonisolated static func probeDuration(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }
    struct SegmentTranscriptionPiece: Sendable {
        let offsetSeconds: Double
        let text: String
        let segments: [TranscriptionResult.Segment]
        let speakerEmbeddings: [String: [Float]]?
        let modelName: String?

        init(
            offsetSeconds: Double,
            text: String,
            segments: [TranscriptionResult.Segment],
            speakerEmbeddings: [String: [Float]]? = nil,
            modelName: String? = nil
        ) {
            self.offsetSeconds = offsetSeconds
            self.text = text
            self.segments = segments
            self.speakerEmbeddings = speakerEmbeddings
            self.modelName = modelName
        }
    }

    nonisolated static func mergeSegmentTranscriptions(_ pieces: [SegmentTranscriptionPiece]) -> TranscriptionResult {
        // Unify each part's independently-diarized speakers into one global space.
        let reconciled = SegmentSpeakerReconciler.reconcile(
            pieces.map { .init(segments: $0.segments, speakerEmbeddings: $0.speakerEmbeddings) }
        )

        var fullTextParts: [String] = []
        var mergedSegments: [TranscriptionResult.Segment] = []

        for (index, piece) in pieces.enumerated() {
            let remap = reconciled.remaps[index]
            let trimmed = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                fullTextParts.append(trimmed)
            }

            for segment in piece.segments {
                let globalSpeaker = segment.speaker.flatMap { remap[$0] }
                let remappedWords = segment.words?.map { word -> TranscriptionResult.Word in
                    var w = word
                    if let s = word.speaker { w.speaker = remap[s] }
                    return w
                }
                mergedSegments.append(
                    .init(
                        start: segment.start + piece.offsetSeconds,
                        end: segment.end + piece.offsetSeconds,
                        text: segment.text,
                        words: remappedWords,
                        speaker: globalSpeaker
                    )
                )
            }
        }

        return TranscriptionResult(
            text: fullTextParts.joined(separator: " "),
            segments: mergedSegments,
            speakerCount: reconciled.speakerCount == 0 ? nil : reconciled.speakerCount,
            speakerEmbeddings: reconciled.speakerEmbeddings.isEmpty ? nil : reconciled.speakerEmbeddings,
            modelName: !pieces.isEmpty && pieces.allSatisfy({ $0.modelName == pieces.first?.modelName })
                ? pieces.first?.modelName : nil
        )
    }
}
