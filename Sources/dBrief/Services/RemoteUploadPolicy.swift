import Foundation

/// Hosted limits are keyed by the actual API host and adapter, never by a model
/// name, URL substring, or a custom endpoint's OpenAI-compatible API shape.
struct RemoteUploadPolicy: Sendable {
    private struct Limit: Sendable {
        let provider: String
        let maximumBytes: Int64
        let description: String
    }

    private let limit: Limit?
    private let chunkThreshold: Int?

    init(endpoint: Endpoint, configuredMaxUploadMB: Int) {
        let url = endpoint.transcriptionURL
        var host = url?.host?.lowercased() ?? ""
        if host.hasSuffix(".") { host.removeLast() }
        let standardHTTPS = url?.scheme?.lowercased() == "https" && (url?.port == nil || url?.port == 443)
        var hostedLimit: Limit?
        var hostedDiarization = false
        if standardHTTPS {
            switch endpoint.provider {
            case .openAICompatible where Self.openAIHosts.contains(host):
                hostedLimit = Limit(provider: "OpenAI", maximumBytes: 25_000_000, description: "25 MB or less")
                hostedDiarization = endpoint.modelName.lowercased().contains("diarize")
            case .openAICompatible where host == "api.groq.com":
                // Direct multipart attachments are 25 MB, even though the Dev
                // tier's URL-based input supports 100 MB. We upload files.
                hostedLimit = Limit(provider: "Groq", maximumBytes: 25_000_000, description: "25 MB or less")
            case .deepgram where Self.deepgramHosts.contains(host):
                hostedLimit = Limit(provider: "Deepgram", maximumBytes: 2_000_000_000, description: "2 GB or less")
            case .elevenLabs where Self.elevenLabsHosts.contains(host):
                // The API explicitly requires a file *less than* 5.0 GB.
                hostedLimit = Limit(provider: "ElevenLabs", maximumBytes: 4_999_999_999, description: "smaller than 5 GB")
            default:
                break
            }
        }
        limit = hostedLimit

        if endpoint.provider == .openAICompatible && !endpoint.isWhisperASR && !hostedDiarization {
            let (bytes, overflow) = max(1, configuredMaxUploadMB).multipliedReportingOverflow(by: 1_024 * 1_024)
            let configuredBytes = overflow ? Int.max : bytes
            chunkThreshold = min(configuredBytes, hostedLimit.map { Int($0.maximumBytes) } ?? Int.max)
        } else {
            // Native cloud diarization needs one request to keep speaker IDs
            // consistent. Custom native/whisper-asr endpoints retain their
            // existing whole-file behavior and are not assigned hosted caps.
            chunkThreshold = nil
        }
    }

    /// A non-nil result means local splitting is required, even if the optional
    /// chunking toggle is off. Inclusive thresholds allow an exact-size file.
    func chunkSize(forFileBytes bytes: Int64) throws -> Int? {
        guard bytes >= 0 else { throw RemoteUploadError.unreadableAudio }
        if let chunkThreshold, bytes > Int64(chunkThreshold) { return chunkThreshold }
        try validateFileByteCount(bytes)
        return nil
    }

    /// Recheck immediately before a request, including probe/fallback/retry
    /// requests, so a changed input or unexpected export cannot bypass a cap.
    func validateFileByteCount(_ bytes: Int64) throws {
        guard bytes >= 0 else { throw RemoteUploadError.unreadableAudio }
        if let limit, bytes > limit.maximumBytes {
            throw RemoteUploadError.fileTooLarge(provider: limit.provider, requirement: limit.description)
        }
    }

    static func fileByteCount(_ url: URL) throws -> Int64 {
        var uncachedURL = url
        uncachedURL.removeAllCachedResourceValues()
        guard uncachedURL.isFileURL,
              let values = try? uncachedURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
            throw RemoteUploadError.unreadableAudio
        }
        return Int64(size)
    }

    // Verified 2026-09-08. Decimal MB/GB honor the documented limits
    // conservatively; the existing user-configured threshold remains in MiB.
    // https://developers.openai.com/api/docs/guides/speech-to-text
    // https://platform.openai.com/docs/models/default-usage-policies-by-endpoint
    private static let openAIHosts: Set<String> = [
        "api.openai.com", "us.api.openai.com", "eu.api.openai.com", "au.api.openai.com",
        "ca.api.openai.com", "jp.api.openai.com", "in.api.openai.com", "sg.api.openai.com",
        "kr.api.openai.com", "gb.api.openai.com", "ae.api.openai.com",
    ]
    // https://console.groq.com/docs/speech-to-text
    // https://developers.deepgram.com/docs/pre-recorded-audio
    // https://developers.deepgram.com/reference/custom-endpoints
    private static let deepgramHosts: Set<String> = [
        "api.deepgram.com", "api.eu.deepgram.com", "api.au.deepgram.com",
    ]
    // https://elevenlabs.io/docs/api-reference/speech-to-text/convert
    // https://elevenlabs.io/docs/overview/administration/data-residency
    // https://elevenlabs.io/docs/eleven-api/guides/how-to/best-practices/latency-optimization
    private static let elevenLabsHosts: Set<String> = [
        "api.elevenlabs.io", "api.us.elevenlabs.io", "api.eu.residency.elevenlabs.io",
        "api.in.residency.elevenlabs.io", "api.sg.residency.elevenlabs.io",
    ]
}

enum RemoteUploadError: Error, LocalizedError, Equatable {
    case unreadableAudio
    case fileTooLarge(provider: String, requirement: String)

    var errorDescription: String? {
        switch self {
        case .unreadableAudio:
            "The audio file's size could not be read. Check that the recording is still available and accessible."
        case .fileTooLarge(let provider, let requirement):
            "\(provider) requires an audio file \(requirement). Compress this recording or choose another endpoint, then retry. The original audio has been kept."
        }
    }
}
