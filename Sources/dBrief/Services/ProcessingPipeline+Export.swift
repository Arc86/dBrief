import Foundation
import dBriefWire

extension ProcessingPipeline {
    struct TitleRequest: Sendable {
        let transcription: String
        let summary: String?
        let language: String?
        let endpoint: Endpoint
    }
    struct TitleInput: Sendable {
        let transcription: String
        let language: String?
        let endpoint: Endpoint
    }
    struct TitleOutput: Sendable {
        let title: String?
        let duration: TimeInterval?
    }
    enum MarkdownMode: Sendable {
        case restartable(jobID: UUID, savedPlan: MarkdownExportPlan?, alreadyCompleted: Bool)
        case regenerate
    }
    struct MarkdownRequest: Sendable {
        let snapshot: MarkdownGenerator.Snapshot
        let outputFolder: URL
        let includeTranscript: Bool
        let mode: MarkdownMode
    }
    struct MarkdownOutput: Sendable {
        let plan: MarkdownExportPlan
        let url: URL
    }
    struct RestoredAnalysis: Sendable {
        let insights: RecordingInsights?
        let adoptedPlan: MarkdownExportPlan?
    }

    /// Full speaker grouping/formatting belongs off the UI actor, including the
    /// empty-transcript decision made before presenting the optional title step.
    func prepareTitleTranscript(_ transcription: TranscriptionResult,
                                format: @Sendable (TranscriptionResult) -> String = { $0.textForLLM }) throws -> String {
        try Task.checkCancellation()
        let text = format(transcription)
        try Task.checkCancellation()
        return text
    }

    func generateTitle(_ request: TitleRequest,
                       using generate: @Sendable (TitleInput) async throws -> String,
                       validateOwnership: @Sendable () async throws -> Void = {}) async throws -> TitleOutput {
        try Task.checkCancellation()
        let input = TitleInput(transcription: request.summary ?? String(request.transcription.prefix(500)),
                               language: request.language, endpoint: request.endpoint)
        let start = now()
        try await validateOwnership()
        try Task.checkCancellation()
        do {
            let title = try await generate(input)
            try Task.checkCancellation()
            try await validateOwnership()
            try Task.checkCancellation()
            return .init(title: title, duration: now().timeIntervalSince(start))
        } catch {
            try Task.checkCancellation()
            // Title errors remain non-critical; Markdown can derive a title from
            // existing analysis/transcription. User cancellation still propagates.
            return .init(title: nil, duration: nil)
        }
    }

    /// A checkpoint callback must finish before restartable publication. Frozen
    /// plans bypass rendering/collision selection entirely, including on recovery.
    func publishMarkdown(_ request: MarkdownRequest, store: MarkdownOutputStore,
                         savePlan: @Sendable (MarkdownExportPlan) async throws -> Void,
                         validateOwnership: @Sendable () async throws -> Void = {}) async throws -> MarkdownOutput {
        try Task.checkCancellation()
        try await validateOwnership()
        try Task.checkCancellation()
        let plan: MarkdownExportPlan
        let alreadyCompleted: Bool
        if case .restartable(_, let saved?, let completed) = request.mode {
            plan = saved
            alreadyCompleted = completed
        } else {
            let proposed = MarkdownGenerator().prepare(snapshot: request.snapshot, outputFolder: request.outputFolder,
                includeTranscript: request.includeTranscript)
            try Task.checkCancellation()
            if case .restartable(let jobID, _, let completed) = request.mode {
                plan = try await store.prepare(proposed, jobID: jobID)
                try Task.checkCancellation()
                try await validateOwnership()
                try Task.checkCancellation()
                try await savePlan(plan)
                alreadyCompleted = completed
            } else {
                plan = proposed
                alreadyCompleted = false
            }
        }
        try Task.checkCancellation()
        try await validateOwnership()
        try Task.checkCancellation()
        let url: URL
        switch request.mode {
        case .restartable: url = try await store.publish(plan, alreadyCompleted: alreadyCompleted)
        case .regenerate: url = try await store.regenerate(plan)
        }
        try Task.checkCancellation()
        try await validateOwnership()
        try Task.checkCancellation()
        return .init(plan: plan, url: url)
    }

    func saveAnalysis(_ insights: RecordingInsights, to url: URL?, store: InsightsStore) async throws {
        try Task.checkCancellation()
        guard let url else { throw InsightsStoreError.noSidecarURL }
        try await store.save(insights, to: url)
        try Task.checkCancellation()
    }

    func restoreAnalysis(from url: URL?, required: Bool, adoptLegacyMarkdown: Bool,
                         insightsStore: InsightsStore, markdownStore: MarkdownOutputStore) async throws -> RestoredAnalysis {
        try Task.checkCancellation()
        let insights: RecordingInsights?
        if let url { insights = try await insightsStore.load(from: url) }
        else { insights = nil }
        try Task.checkCancellation()
        if required, insights == nil { throw InsightsStoreError.noSidecarURL }
        var adopted: MarkdownExportPlan?
        if adoptLegacyMarkdown, let insights, let path = insights.markdownPath {
            adopted = try await markdownStore.adoptExisting(at: URL(fileURLWithPath: path), generatedTitle: insights.generatedTitle)
            try Task.checkCancellation()
        }
        return .init(insights: insights, adoptedPlan: adopted)
    }

    func updateAnalysisExportLink(at url: URL?, markdownURL: URL?, generatedTitle: String?, store: InsightsStore) async throws {
        try Task.checkCancellation()
        guard let url else { return }
        try await store.setExportLink(markdownURL, generatedTitle: generatedTitle, at: url)
        try Task.checkCancellation()
    }
}
