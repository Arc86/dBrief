import Foundation

/// Execution metadata only. Content and arbitrary diagnostic strings have no
/// fields in this schema; a missing receipt never establishes local execution.
struct PrivacyReceipt: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    var attempts: [PrivacyAttempt] = []
    var omittedAttempts = 0
    /// Known missing evidence. False is not a completeness guarantee: receipts
    /// cover recorded attempts only, never activity before instrumentation.
    var hasGaps = false
}

struct PrivacyAttempt: Codable, Equatable, Sendable, Identifiable {
    enum Outcome: String, Codable, Sendable {
        /// An operation was about to execute. A crash or lost completion leaves
        /// this uncertain: it does not prove that data was or was not received.
        case started, succeeded, failed, cancelled, redirected
    }
    let id: UUID
    let runID: UUID
    let operation: PrivacyOperation
    let startedAt: Date
    var finishedAt: Date?
    var outcome: Outcome = .started
    var isConfirmedSuccess: Bool { outcome == .succeeded && finishedAt != nil }
}

struct PrivacyOperation: Codable, Equatable, Sendable {
    enum ResponseFormat: String, Codable, Sendable {
        case verboseJSON = "verbose_json", json, jsonVerbose = "json_verbose"
    }
    enum Stage: String, Codable, Sendable {
        case finalization, transcription, liveTranscription, formatProbe, speakerAnalysis, spelling
        case analysis, summary, actionItems, tags, title, chat, markdownExport, integration
        case clipboardExport, spokenSummaryScript, speechSynthesis, audioExport
    }
    enum DataCategory: String, Codable, Sendable {
        case recordingAudio, syntheticAudio, generatedAudio, text, metadata
    }
    let stage: Stage
    let data: Set<DataCategory>
    let destination: PrivacyDestination
    var responseFormat: ResponseFormat? = nil
}

struct PrivacyDestination: Codable, Equatable, Sendable {
    enum Location: String, Codable, Sendable {
        case local, remote, externallyManaged
    }
    enum Provider: String, Codable, Sendable {
        case openAICompatible, anthropic, deepgram, elevenLabs, custom
        case whisper, speakerKit, parakeet, fluidAudio, appleSpeech, speechAnalyzer, appleIntelligence, localModel
        case localCLI, appleNotes, appleReminders, webhook, fileSystem
        case clipboard, ttsKit, kokoro
    }
    let location: Location
    let provider: Provider
    let hostname: String?
    let model: String?

    static func remote(url: URL, provider: Provider, model: String? = nil) -> Self {
        Self(location: .remote, provider: provider,
             hostname: url.host?.lowercased(), model: sanitizedModel(model))
    }

    static func local(provider: Provider, model: String? = nil) -> Self {
        Self(location: .local, provider: provider, hostname: nil, model: sanitizedModel(model))
    }

    /// Local invocation of an application or arbitrary CLI cannot establish
    /// whether that application synchronizes or sends its input elsewhere.
    static func externallyManaged(provider: Provider) -> Self {
        Self(location: .externallyManaged, provider: provider, hostname: nil, model: nil)
    }

    private init(location: Location, provider: Provider, hostname: String?, model: String?) {
        self.location = location
        self.provider = provider
        self.hostname = hostname
        self.model = model
    }

    static func sanitizedModel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128, !value.contains("://"),
              !value.lowercased().hasPrefix("sk-"),
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._/:".contains($0)) }) else { return nil }
        return value
    }

    var isValid: Bool {
        guard model == Self.sanitizedModel(model) else { return false }
        if location != .remote { return hostname == nil }
        guard let hostname, !hostname.isEmpty, hostname.utf8.count <= 253 else { return false }
        // Hostname-only metadata: no user info, path, query, fragment or port.
        // Colons/brackets permit IPv6; URL parsing above supplies the host.
        return hostname == hostname.lowercased()
            && hostname.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-:[]".contains($0)) }
    }
}
