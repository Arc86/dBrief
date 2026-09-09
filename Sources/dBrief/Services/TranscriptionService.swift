import Foundation
import dBriefWire
import OSLog

actor TranscriptionService {
    typealias FileUpload = @Sendable (URLRequest, URL) async throws -> (Data, URLResponse)
    private let fileUpload: FileUpload?

    init(upload: FileUpload? = nil) {
        self.fileUpload = upload
    }

    struct ChunkingConfiguration: Sendable {
        var enabled: Bool
        var maxUploadMB: Int
        var overlapSeconds: Double
        var retryCount: Int

        static let `default` = ChunkingConfiguration(
            enabled: true,
            maxUploadMB: 15,
            overlapSeconds: 2.0,
            retryCount: 2
        )
    }

    struct ChunkProgress: Sendable {
        let current: Int
        let total: Int
    }

    private enum OpenAIResponseFormat: String, CaseIterable {
        case verboseJSON = "verbose_json"
        case json
        case jsonVerbose = "json_verbose"
    }

    private struct FormatCapabilityCache: Codable {
        var values: [String: String]
    }

    enum ChunkTranscriptionOutcome: Sendable {
        case success(AudioChunk, TranscriptionResult)
        case failed(AudioChunk, String)
    }

    private static let formatCacheKey = "transcriptionResponseFormatCache"

    /// Shares the exact request-model policy with durable transcript provenance.
    /// A Whisper-ASR server selects its model independently of the client field.
    nonisolated static func modelName(for endpoint: Endpoint) -> String? {
        switch endpoint.provider {
        case .deepgram: return endpoint.modelName.isEmpty ? "nova-3" : endpoint.modelName
        case .elevenLabs: return endpoint.modelName.isEmpty ? "scribe_v1" : endpoint.modelName
        case .anthropic, .openAICompatible:
            guard !endpoint.isWhisperASR, !endpoint.modelName.isEmpty else { return nil }
            return endpoint.modelName
        }
    }

    func transcribe(
        fileURL: URL,
        endpoint: Endpoint,
        language: String = "",
        initialPrompt: String = "",
        diarize: Bool = false,
        chunking: ChunkingConfiguration = .default,
        progress: (@Sendable (ChunkProgress) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        guard let url = endpoint.transcriptionURL else {
            throw TranscriptionError.invalidEndpoint
        }

        try Task.checkCancellation()
        let policy = RemoteUploadPolicy(endpoint: endpoint, configuredMaxUploadMB: chunking.maxUploadMB)
        let chunkBytes = try policy.chunkSize(forFileBytes: RemoteUploadPolicy.fileByteCount(fileURL))
        let fileExtension = fileURL.pathExtension.lowercased()
        let contentType = Self.contentType(forExtension: fileExtension)

        // Native cloud ASR providers accept long audio server-side — send whole file,
        // no client-side chunking.
        switch endpoint.provider {
        case .deepgram:
            let data = try await sendDeepgramRequest(url: url, endpoint: endpoint, fileURL: fileURL, contentType: contentType, language: language, diarize: diarize)
            return CloudASRMappers.parseDeepgram(data, language: language.isEmpty ? nil : language)
        case .elevenLabs:
            let data = try await sendElevenLabsRequest(url: url, endpoint: endpoint, fileURL: fileURL, fileName: fileURL.lastPathComponent, contentType: contentType, language: language, diarize: diarize)
            return CloudASRMappers.parseElevenLabs(data)
        case .anthropic, .openAICompatible:
            break
        }

        if endpoint.isWhisperASR {
            let data = try await sendRequest(
                url: url,
                endpoint: endpoint,
                fileContent: .file(fileURL),
                fileName: fileURL.lastPathComponent,
                contentType: contentType,
                language: language,
                initialPrompt: initialPrompt,
                responseFormat: nil,
                timeout: 300
            )
            return try parseResponse(data)
        }

        if let maxUploadBytes = chunkBytes {
            return try await transcribeChunked(
                fileURL: fileURL,
                endpoint: endpoint,
                url: url,
                language: language,
                initialPrompt: initialPrompt,
                maxUploadBytes: maxUploadBytes,
                overlapSeconds: chunking.overlapSeconds,
                retryCount: max(0, chunking.retryCount),
                progress: progress
            )
        }

        return try await transcribeSingle(
            fileURL: fileURL,
            endpoint: endpoint,
            url: url,
            contentType: contentType,
            language: language,
            initialPrompt: initialPrompt,
            retryCount: max(0, chunking.retryCount)
        )
    }

    func testConnection(endpoint: Endpoint) async throws -> Bool {
        // Deepgram/ElevenLabs don't expose an OpenAI-style /v1/models list; treat a
        // configured endpoint+key as usable (validated on first real transcription).
        if endpoint.provider == .deepgram || endpoint.provider == .elevenLabs {
            return !endpoint.apiKey.isEmpty
        }
        if endpoint.isWhisperASR {
            _ = try await fetchWhisperASRHealth(endpoint: endpoint)
            return true
        }

        _ = try await fetchAvailableModels(endpoint: endpoint)
        return true
    }

    func fetchAvailableModels(endpoint: Endpoint) async throws -> [String] {
        if endpoint.provider == .deepgram || endpoint.provider == .elevenLabs {
            return []
        }
        if endpoint.isWhisperASR {
            // whisper-asr-webservice does not expose a model listing endpoint.
            _ = try await fetchWhisperASRHealth(endpoint: endpoint)
            return []
        }

        do {
            let models = try await fetchOpenAICompatibleModels(endpoint: endpoint)
            if !models.isEmpty {
                return models
            }
        } catch {
            // Fall back to Ollama-compatible discovery.
        }

        let ollamaModels = try await fetchOllamaModels(endpoint: endpoint)
        if !ollamaModels.isEmpty {
            return ollamaModels
        }

        throw TranscriptionError.noModelsFound
    }

    private func fetchWhisperASRHealth(endpoint: Endpoint) async throws -> Data {
        let base = endpoint.baseURL.trimmingSuffix("/")
        let root = base.hasSuffix("/asr") ? String(base.dropLast(4)) : base
        guard let url = URL(string: root + "/docs") else {
            throw TranscriptionError.invalidEndpoint
        }
        return try await get(url: url, endpoint: endpoint)
    }

    private func fetchOpenAICompatibleModels(endpoint: Endpoint) async throws -> [String] {
        guard let url = URL(string: endpoint.baseURL.trimmingSuffix("/") + "/v1/models") else {
            throw TranscriptionError.invalidEndpoint
        }
        let data = try await get(url: url, endpoint: endpoint)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataItems = json["data"] as? [[String: Any]]
        else {
            throw TranscriptionError.invalidResponse
        }

        let models = dataItems
            .compactMap { $0["id"] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return Array(Set(models)).sorted()
    }

    private func fetchOllamaModels(endpoint: Endpoint) async throws -> [String] {
        guard let url = URL(string: endpoint.baseURL.trimmingSuffix("/") + "/api/tags") else {
            throw TranscriptionError.invalidEndpoint
        }
        let data = try await get(url: url, endpoint: endpoint)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else {
            throw TranscriptionError.invalidResponse
        }

        let modelNames = models
            .compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return Array(Set(modelNames)).sorted()
    }

    private func transcribeSingle(
        fileURL: URL,
        endpoint: Endpoint,
        url: URL,
        contentType: String,
        language: String,
        initialPrompt: String,
        retryCount: Int
    ) async throws -> TranscriptionResult {
        let resolvedFormat = try await resolveBestResponseFormat(
            endpoint: endpoint,
            url: url,
            language: language,
            initialPrompt: initialPrompt
        )
        return try await transcribeWithRetry(
            endpoint: endpoint,
            url: url,
            fileContent: .file(fileURL),
            fileName: fileURL.lastPathComponent,
            contentType: contentType,
            language: language,
            initialPrompt: initialPrompt,
            preferredFormat: resolvedFormat,
            retryCount: retryCount
        )
    }

    private func transcribeChunked(
        fileURL: URL,
        endpoint: Endpoint,
        url: URL,
        language: String,
        initialPrompt: String,
        maxUploadBytes: Int,
        overlapSeconds: Double,
        retryCount: Int,
        progress: (@Sendable (ChunkProgress) -> Void)?
    ) async throws -> TranscriptionResult {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbrief-chunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let chunker = AudioChunker()
        let chunks = try await chunker.chunkAudio(
            fileURL: fileURL,
            maxUploadBytes: maxUploadBytes,
            overlapSeconds: overlapSeconds,
            tempDirectory: tempDirectory
        )

        guard !chunks.isEmpty else {
            throw TranscriptionError.chunkingFailed("No chunks were produced from audio.")
        }

        for chunk in chunks {
            guard try RemoteUploadPolicy.fileByteCount(chunk.url) <= Int64(maxUploadBytes) else {
                throw TranscriptionError.chunkingFailed("An exported chunk exceeds the upload limit. The original audio has been kept.")
            }
        }

        let resolvedFormat = try await resolveBestResponseFormat(
            endpoint: endpoint,
            url: url,
            language: language,
            initialPrompt: initialPrompt
        )

        var outcomes: [ChunkTranscriptionOutcome] = []
        outcomes.reserveCapacity(chunks.count)

        for (idx, chunk) in chunks.enumerated() {
            progress?(ChunkProgress(current: idx + 1, total: chunks.count))
            do {
                let result = try await transcribeWithRetry(
                    endpoint: endpoint,
                    url: url,
                    fileContent: .file(chunk.url),
                    fileName: chunk.url.lastPathComponent,
                    contentType: Self.contentType(forExtension: chunk.url.pathExtension.lowercased()),
                    language: language,
                    initialPrompt: initialPrompt,
                    preferredFormat: resolvedFormat,
                    retryCount: retryCount
                )
                outcomes.append(.success(chunk, result))
            } catch {
                try rethrowCancellation(error)
                outcomes.append(.failed(chunk, error.localizedDescription))
            }
        }

        return try mergeChunkOutcomes(outcomes)
    }

    private func transcribeWithRetry(
        endpoint: Endpoint,
        url: URL,
        fileContent: MultipartFormData.Content,
        fileName: String,
        contentType: String,
        language: String,
        initialPrompt: String,
        preferredFormat: OpenAIResponseFormat,
        retryCount: Int
    ) async throws -> TranscriptionResult {
        var lastError: Error?
        for attempt in 0...retryCount {
            try Task.checkCancellation()
            do {
                return try await transcribeWithFormatFallback(
                    endpoint: endpoint,
                    url: url,
                    fileContent: fileContent,
                    fileName: fileName,
                    contentType: contentType,
                    language: language,
                    initialPrompt: initialPrompt,
                    preferredFormat: preferredFormat
                )
            } catch {
                try rethrowCancellation(error)
                lastError = error
                if attempt < retryCount, shouldRetryAfterError(error) {
                    let delay = UInt64(pow(2.0, Double(attempt)) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: delay)
                } else {
                    break
                }
            }
        }
        throw lastError ?? TranscriptionError.invalidResponse
    }

    private func rethrowCancellation(_ error: Error) throws {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            throw error
        }
        try Task.checkCancellation()
    }

    private func shouldRetryAfterError(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                // Avoid duplicate in-flight server jobs for large uploads.
                return false
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
                 .notConnectedToInternet, .cannotLoadFromNetwork, .internationalRoamingOff,
                 .callIsActive, .dataNotAllowed:
                return true
            default:
                return false
            }
        }

        if case let TranscriptionError.serverError(statusCode, _) = error {
            if statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode) {
                return true
            }
            return false
        }

        return false
    }

    private func transcribeWithFormatFallback(
        endpoint: Endpoint,
        url: URL,
        fileContent: MultipartFormData.Content,
        fileName: String,
        contentType: String,
        language: String,
        initialPrompt: String,
        preferredFormat: OpenAIResponseFormat
    ) async throws -> TranscriptionResult {
        let preferredData: Data
        do {
            preferredData = try await sendRequest(
                url: url,
                endpoint: endpoint,
                fileContent: fileContent,
                fileName: fileName,
                contentType: contentType,
                language: language,
                initialPrompt: initialPrompt,
                responseFormat: preferredFormat.rawValue,
                timeout: 300
            )
        } catch {
            if shouldSkipFormatFallback(for: error) || !shouldAttemptFormatFallback(for: error) {
                throw error
            }

            for fallback in OpenAIResponseFormat.allCases where fallback != preferredFormat {
                do {
                    let data = try await sendRequest(
                        url: url,
                        endpoint: endpoint,
                        fileContent: fileContent,
                        fileName: fileName,
                        contentType: contentType,
                        language: language,
                        initialPrompt: initialPrompt,
                        responseFormat: fallback.rawValue,
                        timeout: 300
                    )
                    saveCachedResponseFormat(fallback, for: endpoint)
                    return try parseResponse(data)
                } catch {
                    if shouldSkipFormatFallback(for: error) || !shouldAttemptFormatFallback(for: error) {
                        throw error
                    }
                    continue
                }
            }
            throw error
        }

        // If the server already completed transcription, never re-upload the full file
        // just because parsing failed client-side.
        return try parseResponse(preferredData)
    }

    private func shouldSkipFormatFallback(for error: Error) -> Bool {
        guard case let TranscriptionError.serverError(statusCode, body) = error else {
            return false
        }
        if statusCode != 422 {
            return false
        }
        return body.lowercased().contains("response_format")
    }

    private func shouldAttemptFormatFallback(for error: Error) -> Bool {
        guard case let TranscriptionError.serverError(statusCode, body) = error else {
            return false
        }
        // Restrict fallback to likely request-format compatibility failures.
        guard statusCode == 400 || statusCode == 415 || statusCode == 422 else {
            return false
        }
        let lowercasedBody = body.lowercased()
        return lowercasedBody.contains("response_format")
            || lowercasedBody.contains("unsupported")
            || lowercasedBody.contains("not supported")
            || lowercasedBody.contains("invalid")
    }

    func mergeChunkOutcomes(
        _ outcomes: [ChunkTranscriptionOutcome]
    ) throws -> TranscriptionResult {
        var mergedText = ""
        var mergedSegments: [TranscriptionResult.Segment] = []
        var language: String?
        var warnings: [String] = []
        var successCount = 0
        var previousChunk: AudioChunk?
        var previousLastSegment: TranscriptionResult.Segment?

        for outcome in outcomes {
            switch outcome {
            case .failed(let chunk, let message):
                warnings.append(
                    "Chunk \(chunk.index + 1) (\(formatSeconds(chunk.startSeconds))-\(formatSeconds(chunk.endSeconds))) failed: \(message)"
                )
            case .success(let chunk, let result):
                successCount += 1
                if language == nil, let value = result.language, !value.isEmpty {
                    language = value
                }

                let overlapEnd = min(previousChunk?.endSeconds ?? chunk.startSeconds, chunk.endSeconds)
                var acceptedSegments: [TranscriptionResult.Segment] = []
                var droppedPrefix = false
                var lastSegmentOfThisChunk: TranscriptionResult.Segment?
                for segment in result.segments {
                    let shifted = TranscriptionResult.Segment(
                        start: segment.start + chunk.startSeconds,
                        end: segment.end + chunk.startSeconds,
                        text: segment.text,
                        words: segment.words?.map { word in
                            .init(word: word.word,
                                  start: word.start + chunk.startSeconds,
                                  end: word.end + chunk.startSeconds,
                                  probability: word.probability,
                                  speaker: word.speaker)
                        },
                        speaker: segment.speaker
                    )
                    lastSegmentOfThisChunk = shifted
                    // Only a prefix duplicated across a real audio overlap is
                    // removable. Repeated speech within a chunk or after the
                    // overlap must survive, even when its words are identical.
                    if acceptedSegments.isEmpty,
                       shouldDropSegment(shifted, previous: previousLastSegment,
                                         overlapStart: chunk.startSeconds, overlapEnd: overlapEnd) {
                        droppedPrefix = true
                        continue
                    }
                    acceptedSegments.append(shifted)
                }
                let contribution = droppedPrefix
                    ? acceptedSegments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    : result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !contribution.isEmpty {
                    if !mergedText.isEmpty { mergedText += " " }
                    mergedText += contribution
                }
                mergedSegments.append(contentsOf: acceptedSegments)
                previousChunk = chunk
                previousLastSegment = lastSegmentOfThisChunk
            }
        }

        guard successCount > 0 else {
            throw TranscriptionError.chunkingFailed("All chunks failed during transcription.")
        }

        return TranscriptionResult(
            text: mergedText.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: mergedSegments,
            language: language,
            warnings: warnings.isEmpty ? nil : warnings
        )
    }

    private func shouldDropSegment(
        _ candidate: TranscriptionResult.Segment,
        previous: TranscriptionResult.Segment?,
        overlapStart: Double,
        overlapEnd: Double
    ) -> Bool {
        guard let previous, overlapEnd > overlapStart,
              candidate.start < overlapEnd, candidate.end > overlapStart,
              candidate.start < previous.end, candidate.end > previous.start,
              candidate.speaker == previous.speaker else { return false }
        return normalizedToken(candidate.text) == normalizedToken(previous.text)
    }

    private func formatSeconds(_ value: Double) -> String {
        let total = Int(value.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func get(url: URL, endpoint: Endpoint) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !endpoint.apiKey.isEmpty {
            request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10

        let (data, response) = try await PrivacyHTTPTrace.untracedData(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.serverError(httpResponse.statusCode, responseBody)
        }
        return data
    }

    private func parseResponse(_ data: Data) throws -> TranscriptionResult {
        if let srtText = String(data: data, encoding: .utf8),
           !srtText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           srtText.contains("-->")
        {
            let parsedSegments = parseSRTSegments(srtText)
            let joinedText = parsedSegments.map(\.text).joined(separator: " ")
            return TranscriptionResult(text: joinedText, segments: parsedSegments, language: nil)
        }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if let plainText = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !plainText.isEmpty
            {
                return TranscriptionResult(text: plainText, segments: [], language: nil)
            }
            throw TranscriptionError.invalidResponse
        }
        let text = json["text"] as? String ?? ""
        let language = json["language"] as? String

        var segments: [TranscriptionResult.Segment] = []
        if let rawSegments = json["segments"] as? [[String: Any]] {
            for seg in rawSegments {
                let start = normalizeTimestamp(seg["start"])
                let end = normalizeTimestamp(seg["end"])
                let segText = seg["text"] as? String ?? ""
                var words: [TranscriptionResult.Word]?
                if let rawWords = seg["words"] as? [[String: Any]] {
                    words = rawWords.compactMap { rawWord in
                        guard let wordText = rawWord["word"] as? String else { return nil }
                        let wordStart = normalizeTimestamp(rawWord["start"])
                        let wordEnd = normalizeTimestamp(rawWord["end"])
                        let probability = rawWord["probability"] as? Double
                        return TranscriptionResult.Word(
                            word: wordText,
                            start: wordStart,
                            end: wordEnd,
                            probability: probability
                        )
                    }
                }
                segments.append(.init(start: start, end: end, text: segText, words: words))
            }
        }

        return TranscriptionResult(text: text, segments: segments, language: language)
    }

    private func resolveBestResponseFormat(
        endpoint: Endpoint,
        url: URL,
        language: String,
        initialPrompt: String
    ) async throws -> OpenAIResponseFormat {
        if let cached = cachedResponseFormat(for: endpoint) {
            let probeData = tinySilentWAV()
            do {
                _ = try await sendRequest(
                    url: url,
                    endpoint: endpoint,
                    fileContent: .data(probeData),
                    fileName: "probe.wav",
                    contentType: "audio/wav",
                    language: language,
                    initialPrompt: initialPrompt,
                    responseFormat: cached.rawValue,
                    timeout: 30
                )
                return cached
            } catch {
                try rethrowCancellation(error)
                invalidateCachedResponseFormat(for: endpoint)
            }
        }

        let probeData = tinySilentWAV()
        for format in OpenAIResponseFormat.allCases {
            do {
                _ = try await sendRequest(
                    url: url,
                    endpoint: endpoint,
                    fileContent: .data(probeData),
                    fileName: "probe.wav",
                    contentType: "audio/wav",
                    language: language,
                    initialPrompt: initialPrompt,
                    responseFormat: format.rawValue,
                    timeout: 30
                )
                saveCachedResponseFormat(format, for: endpoint)
                return format
            } catch {
                try rethrowCancellation(error)
                continue
            }
        }

        // All probes failed — likely a content rejection (e.g. silent audio) rather than a
        // format incompatibility. Fall back to verbose_json and let the actual transcription
        // request fail with a real server error if the endpoint truly can't be reached.
        return .verboseJSON
    }

    private func sendRequest(
        url: URL,
        endpoint: Endpoint,
        fileContent: MultipartFormData.Content,
        fileName: String,
        contentType: String,
        language: String,
        initialPrompt: String,
        responseFormat: String?,
        timeout: TimeInterval
    ) async throws -> Data {
        let policy = RemoteUploadPolicy(endpoint: endpoint, configuredMaxUploadMB: Int.max)
        switch fileContent {
        case .data(let data): try policy.validateFileByteCount(Int64(data.count))
        case .file(let fileURL): try policy.validateFileByteCount(RemoteUploadPolicy.fileByteCount(fileURL))
        }
        var requestURL = url
        var form = MultipartFormData()
        let fieldName = endpoint.isWhisperASR ? "audio_file" : "file"
        switch fileContent {
        case .data(let data):
            form.addFile(name: fieldName, fileName: fileName, contentType: contentType, data: data)
        case .file(let fileURL):
            form.addFile(name: fieldName, fileName: fileName, contentType: contentType, fileURL: fileURL)
        }

        if endpoint.isWhisperASR {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            var queryItems = [
                URLQueryItem(name: "output", value: "json"),
                URLQueryItem(name: "task", value: "transcribe"),
                URLQueryItem(name: "encode", value: "true"),
            ]
            if !language.isEmpty {
                queryItems.append(URLQueryItem(name: "language", value: language))
            }
            if !initialPrompt.isEmpty {
                queryItems.append(URLQueryItem(name: "initial_prompt", value: initialPrompt))
            }
            components.queryItems = queryItems
            requestURL = components.url!
        } else {
            form.addField(name: "model", value: endpoint.modelName)
            if let responseFormat {
                form.addField(name: "response_format", value: responseFormat)
                if shouldIncludeTimestampGranularities(
                    endpoint: endpoint,
                    responseFormat: responseFormat
                ) {
                    form.addField(name: "timestamp_granularities[]", value: "segment")
                    form.addField(name: "timestamp_granularities[]", value: "word")
                }
            }
            if !language.isEmpty {
                form.addField(name: "language", value: language)
            }
            if !initialPrompt.isEmpty {
                form.addField(name: "prompt", value: initialPrompt)
            }
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        if !endpoint.apiKey.isEmpty {
            request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = timeout

        let isProbe: Bool
        switch fileContent {
        case .data: isProbe = true // Only synthetic format probes use in-memory data.
        case .file: isProbe = false
        }
        var categories: Set<PrivacyOperation.DataCategory> = [isProbe ? .syntheticAudio : .recordingAudio, .metadata]
        if !initialPrompt.isEmpty { categories.insert(.text) }
        let operation = PrivacyOperation(stage: isProbe ? .formatProbe : .transcription,
            data: categories,
            destination: .remote(url: requestURL, provider: .openAICompatible,
                model: Self.modelName(for: endpoint)),
            responseFormat: responseFormat.flatMap(PrivacyOperation.ResponseFormat.init(rawValue:)))
        let (data, response) = try await uploadMultipart(form, request: request, operation: operation,
            textQueryItems: endpoint.isWhisperASR ? ["initial_prompt"] : [], textInBody: !endpoint.isWhisperASR)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            Logger.transcription.error("Remote transcription HTTP \(httpResponse.statusCode, privacy: .public) from \(url.host ?? "?", privacy: .public); responseLength=\(data.count)")
            throw TranscriptionError.serverError(httpResponse.statusCode, responseBody)
        }
        return data
    }

    // MARK: - Deepgram

    private func sendDeepgramRequest(
        url: URL,
        endpoint: Endpoint,
        fileURL: URL,
        contentType: String,
        language: String,
        diarize: Bool
    ) async throws -> Data {
        try RemoteUploadPolicy(endpoint: endpoint, configuredMaxUploadMB: Int.max)
            .validateFileByteCount(RemoteUploadPolicy.fileByteCount(fileURL))
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "model", value: Self.modelName(for: endpoint)),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
        ]
        if !language.isEmpty {
            queryItems.append(URLQueryItem(name: "language", value: language))
        } else {
            queryItems.append(URLQueryItem(name: "detect_language", value: "true"))
        }
        if diarize { queryItems.append(URLQueryItem(name: "diarize", value: "true")) }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url ?? url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if !endpoint.apiKey.isEmpty {
            request.setValue("Token \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 300

        let operation = PrivacyOperation(stage: .transcription, data: [.recordingAudio, .metadata],
            destination: .remote(url: request.url!, provider: .deepgram,
                model: Self.modelName(for: endpoint)))
        return try await runFileRequest(request, fileURL: fileURL, providerName: "Deepgram", operation: operation,
                                        modelQueryItem: "model")
    }

    // MARK: - ElevenLabs

    private func sendElevenLabsRequest(
        url: URL,
        endpoint: Endpoint,
        fileURL: URL,
        fileName: String,
        contentType: String,
        language: String,
        diarize: Bool
    ) async throws -> Data {
        try RemoteUploadPolicy(endpoint: endpoint, configuredMaxUploadMB: Int.max)
            .validateFileByteCount(RemoteUploadPolicy.fileByteCount(fileURL))
        var form = MultipartFormData()
        form.addField(name: "model_id", value: Self.modelName(for: endpoint) ?? "scribe_v1")
        if !language.isEmpty { form.addField(name: "language_code", value: language) }
        if diarize { form.addField(name: "diarize", value: "true") }
        form.addFile(name: "file", fileName: fileName, contentType: contentType, fileURL: fileURL)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        if !endpoint.apiKey.isEmpty {
            request.setValue(endpoint.apiKey, forHTTPHeaderField: "xi-api-key")
        }
        request.timeoutInterval = 300

        let uploadRequest = request
        let operation = PrivacyOperation(stage: .transcription, data: [.recordingAudio, .metadata],
            destination: .remote(url: url, provider: .elevenLabs,
                model: Self.modelName(for: endpoint)))
        return try await form.withBodyFile { [self] bodyURL in
            try await runFileRequest(uploadRequest, fileURL: bodyURL, providerName: "ElevenLabs", operation: operation)
        }
    }

    private func uploadMultipart(_ form: MultipartFormData, request: URLRequest, operation: PrivacyOperation,
                                 textQueryItems: Set<String>, textInBody: Bool) async throws -> (Data, URLResponse) {
        try await form.withBodyFile { [fileUpload] bodyURL in
            try Task.checkCancellation()
            return try await PrivacyHTTPTrace.upload(request, fromFile: bodyURL, operation: operation,
                textQueryItems: textQueryItems, textInBody: textInBody, using: fileUpload)
        }
    }

    private func runFileRequest(_ request: URLRequest, fileURL: URL, providerName: String,
                                operation: PrivacyOperation, modelQueryItem: String? = nil) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await PrivacyHTTPTrace.upload(request, fromFile: fileURL,
            operation: operation, modelQueryItem: modelQueryItem, using: fileUpload)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            Logger.transcription.error("\(providerName, privacy: .public) HTTP \(httpResponse.statusCode, privacy: .public); responseLength=\(data.count)")
            throw TranscriptionError.serverError(httpResponse.statusCode, responseBody)
        }
        return data
    }

    private func cacheLookupKey(for endpoint: Endpoint) -> String {
        "\(endpoint.baseURL.lowercased())|\(endpoint.modelName.lowercased())"
    }

    private func shouldIncludeTimestampGranularities(endpoint: Endpoint, responseFormat: String) -> Bool {
        guard responseFormat == OpenAIResponseFormat.verboseJSON.rawValue else {
            return false
        }
        // Speaches + faster-whisper supports segment/word granularities.
        return endpoint.modelName.lowercased().contains("systran/faster-whisper")
    }

    private func cachedResponseFormat(for endpoint: Endpoint) -> OpenAIResponseFormat? {
        guard let data = UserDefaults.standard.data(forKey: Self.formatCacheKey),
              let cache = try? JSONDecoder().decode(FormatCapabilityCache.self, from: data),
              let raw = cache.values[cacheLookupKey(for: endpoint)]
        else { return nil }
        return OpenAIResponseFormat(rawValue: raw)
    }

    private func invalidateCachedResponseFormat(for endpoint: Endpoint) {
        guard let data = UserDefaults.standard.data(forKey: Self.formatCacheKey),
              let cache = try? JSONDecoder().decode(FormatCapabilityCache.self, from: data)
        else { return }

        var values = cache.values
        values.removeValue(forKey: cacheLookupKey(for: endpoint))
        if let data = try? JSONEncoder().encode(FormatCapabilityCache(values: values)) {
            UserDefaults.standard.set(data, forKey: Self.formatCacheKey)
        }
    }

    private func saveCachedResponseFormat(_ format: OpenAIResponseFormat, for endpoint: Endpoint) {
        var values: [String: String] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.formatCacheKey),
           let cache = try? JSONDecoder().decode(FormatCapabilityCache.self, from: data)
        {
            values = cache.values
        }
        values[cacheLookupKey(for: endpoint)] = format.rawValue
        if let data = try? JSONEncoder().encode(FormatCapabilityCache(values: values)) {
            UserDefaults.standard.set(data, forKey: Self.formatCacheKey)
        }
    }

    private func tinySilentWAV() -> Data {
        let sampleRate = 16_000
        let seconds = 1
        let numChannels = 1
        let bitsPerSample = 16
        let numSamples = sampleRate * seconds
        let dataSize = numSamples * numChannels * (bitsPerSample / 8)
        let chunkSize = 36 + dataSize
        let byteRate = sampleRate * numChannels * (bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(UInt32(chunkSize).littleEndianData)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(UInt32(16).littleEndianData)
        data.append(UInt16(1).littleEndianData) // PCM
        data.append(UInt16(numChannels).littleEndianData)
        data.append(UInt32(sampleRate).littleEndianData)
        data.append(UInt32(byteRate).littleEndianData)
        data.append(UInt16(blockAlign).littleEndianData)
        data.append(UInt16(bitsPerSample).littleEndianData)
        data.append("data".data(using: .ascii)!)
        data.append(UInt32(dataSize).littleEndianData)
        data.append(Data(repeating: 0, count: dataSize))
        return data
    }

    private func normalizeTimestamp(_ value: Any?) -> Double {
        let raw: Double = {
            if let double = value as? Double { return double }
            if let int = value as? Int { return Double(int) }
            if let int64 = value as? Int64 { return Double(int64) }
            if let number = value as? NSNumber { return number.doubleValue }
            return 0
        }()

        // Some servers return nanoseconds for json_verbose.
        if raw > 1_000_000 {
            return raw / 1_000_000_000
        }
        return raw
    }

    private func parseSRTSegments(_ srt: String) -> [TranscriptionResult.Segment] {
        let blocks = srt.components(separatedBy: "\n\n")
        var segments: [TranscriptionResult.Segment] = []

        for block in blocks {
            let lines = block
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard lines.count >= 2 else { continue }

            let timestampLine = lines[1].contains("-->") ? lines[1] : lines.first(where: { $0.contains("-->") })
            guard let timestampLine else { continue }
            let times = timestampLine.components(separatedBy: "-->").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard times.count == 2 else { continue }
            let start = parseSRTTime(times[0])
            let end = parseSRTTime(times[1])
            let textLines = lines.filter { !$0.contains("-->") && Int($0) == nil }
            let text = textLines.joined(separator: " ")
            segments.append(.init(start: start, end: end, text: text))
        }
        return segments
    }

    private func parseSRTTime(_ value: String) -> Double {
        let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3 else { return 0 }
        let hours = Double(parts[0]) ?? 0
        let minutes = Double(parts[1]) ?? 0
        let seconds = Double(parts[2]) ?? 0
        return hours * 3600 + minutes * 60 + seconds
    }

    private func normalizedToken(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9]+"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func contentType(forExtension fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "ogg", "opus":
            return "audio/ogg"
        case "flac":
            return "audio/flac"
        default:
            return "audio/m4a"
        }
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        if hasSuffix(suffix) { return String(dropLast(suffix.count)) }
        return self
    }
}

enum TranscriptionError: Error, LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case noModelsFound
    case chunkingFailed(String)
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Invalid transcription endpoint URL."
        case .invalidResponse: "Invalid response from transcription server."
        case .noModelsFound: "Connected, but no models were returned by the provider."
        case .chunkingFailed(let message): "Chunking failed: \(message)"
        case .serverError(let code, let body): "Server error (\(code)): \(body)"
        }
    }
}

private extension UInt16 {
    var littleEndianData: Data {
        withUnsafeBytes(of: self.littleEndian) { Data($0) }
    }
}

private extension UInt32 {
    var littleEndianData: Data {
        withUnsafeBytes(of: self.littleEndian) { Data($0) }
    }
}
