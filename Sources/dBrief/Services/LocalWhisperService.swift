@preconcurrency import AVFoundation
import Foundation
import SwiftWhisper
import os

private let log = Logger(subsystem: "com.dbrief.app", category: "localwhisper")

struct LocalWhisperModelSource: Sendable {
    let name: String
    let binURL: URL
    let encoderURL: URL?
    let encoderFolderName: String

    init(name: String, binURL: URL, encoderURL: URL?, encoderFolderName: String = "encoder.mlmodelc") {
        self.name = name
        self.binURL = binURL
        self.encoderURL = encoderURL
        self.encoderFolderName = encoderFolderName
    }

    static let largeV2 = LocalWhisperModelSource(
        name: "large-v2",
        binURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v2.bin")!,
        encoderURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v2-encoder.mlmodelc.zip")!,
        encoderFolderName: "ggml-large-v2-encoder.mlmodelc"
    )
}

struct LocalWhisperModelPaths: Sendable {
    let directory: URL
    let binURL: URL
    let encoderURL: URL?
}

enum LocalWhisperError: Error, LocalizedError {
    case downloadFailed
    case fileWriteFailed
    case conversionFailed(String)
    case missingEncoder(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed: "Failed to download Whisper model."
        case .fileWriteFailed: "Failed to write Whisper model to disk."
        case .conversionFailed(let message): "Failed to convert audio for Whisper. \(message)"
        case .missingEncoder(let name): "Core ML encoder '\(name)' is missing."
        }
    }
}

actor LocalWhisperService {
    private static let bilingualPromptPrefix = "This conversation is likely in Dutch and/or English; however, adjust language accordingly."

    private let model: LocalWhisperModelSource
    private let session: URLSession
    private let fileManager = FileManager.default

    private(set) var downloadProgress: Double = 0

    init(model: LocalWhisperModelSource = .largeV2, session: URLSession = .shared) {
        self.model = model
        self.session = session
    }

    func transcribe(fileURL: URL, initialPrompt: String? = nil) async throws -> TranscriptionResult {
        let modelPaths = try await ensureModelAvailable()
        let audioFrames = try convertToWhisperFormat(url: fileURL)

        let params = WhisperParams(strategy: .beamSearch)
        params.beam_search.beam_size = 5
        params.language = .auto
        params.suppress_non_speech_tokens = true

        let whisper = Whisper(fromFileURL: modelPaths.binURL, withParams: params)

        var promptPointer: UnsafeMutablePointer<CChar>?
        let composedPrompt = composeInitialPrompt(userPrompt: initialPrompt)
        if let pointer = strdup(composedPrompt) {
            promptPointer = pointer
            params.initial_prompt = UnsafePointer(pointer)
        }
        defer {
            params.initial_prompt = nil
            if let promptPointer {
                free(promptPointer)
            }
        }

        let segments = try await whisper.transcribe(audioFrames: audioFrames)
        let text = segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)

        let mappedSegments = segments.map { segment in
            TranscriptionResult.Segment(
                start: Double(segment.startTime) / 1000.0,
                end: Double(segment.endTime) / 1000.0,
                text: segment.text
            )
        }

        return TranscriptionResult(
            text: text,
            segments: mappedSegments,
            language: nil
        )
    }

    func releaseResources() {
        // Whisper is scoped to each transcription call, so deallocation happens automatically
        // once the function exits. This hook exists for lifecycle-triggered cleanup points.
    }

    func ensureModelAvailable() async throws -> LocalWhisperModelPaths {
        let modelDir = try modelDirectory()
        let binURL = modelDir.appendingPathComponent("ggml-\(model.name).bin")
        let encoderURL = model.encoderURL.map { _ in
            modelDir.appendingPathComponent(model.encoderFolderName, isDirectory: true)
        }

        var tasks: [(URL, URL, Bool)] = []
        if !fileManager.fileExists(atPath: binURL.path) {
            tasks.append((model.binURL, binURL, false))
        }
        if let remoteEncoderURL = model.encoderURL, let localEncoderURL = encoderURL {
            if !fileManager.fileExists(atPath: localEncoderURL.path) {
                tasks.append((remoteEncoderURL, localEncoderURL, true))
            }
        }

        if tasks.isEmpty {
            downloadProgress = 100
            return LocalWhisperModelPaths(directory: modelDir, binURL: binURL, encoderURL: encoderURL)
        }

        let totalTasks = Double(tasks.count)
        for (index, task) in tasks.enumerated() {
            let (remoteURL, destinationURL, isEncoder) = task
            try await downloadWithProgress(remoteURL: remoteURL, destinationURL: destinationURL, isEncoder: isEncoder) { fraction in
                let overall = (Double(index) + fraction) / totalTasks
                self.downloadProgress = max(0, min(100, overall * 100))
            }
        }

        if let encoderURL, model.encoderURL != nil, !fileManager.fileExists(atPath: encoderURL.path) {
            throw LocalWhisperError.missingEncoder(model.encoderFolderName)
        }

        downloadProgress = 100
        return LocalWhisperModelPaths(directory: modelDir, binURL: binURL, encoderURL: encoderURL)
    }

    // MARK: - Audio Conversion

    private func convertToWhisperFormat(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat

        guard let whisperFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw LocalWhisperError.conversionFailed("Unable to create output format.")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: whisperFormat) else {
            throw LocalWhisperError.conversionFailed("Unable to create converter.")
        }

        let inputFrameCapacity: AVAudioFrameCount = 32_768
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: inputFrameCapacity
        ) else {
            throw LocalWhisperError.conversionFailed("Unable to allocate input buffer.")
        }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: whisperFormat,
            frameCapacity: inputFrameCapacity
        ) else {
            throw LocalWhisperError.conversionFailed("Unable to allocate output buffer.")
        }

        let expectedFrames = Int(Double(file.length) * whisperFormat.sampleRate / inputFormat.sampleRate)
        var samples: [Float] = []
        samples.reserveCapacity(max(0, expectedFrames))

        var error: NSError?
        var isDone = false

        while !isDone {
            let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
                if file.framePosition >= file.length {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                let framesToRead = min(
                    inNumPackets,
                    AVAudioFrameCount(file.length - file.framePosition)
                )
                do {
                    try file.read(into: inputBuffer, frameCount: framesToRead)
                    inputBuffer.frameLength = framesToRead
                    outStatus.pointee = .haveData
                    return inputBuffer
                } catch {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }

            if let error {
                throw LocalWhisperError.conversionFailed(error.localizedDescription)
            }

            switch status {
            case .haveData:
                let frameLength = Int(outputBuffer.frameLength)
                if frameLength > 0, let channel = outputBuffer.floatChannelData?.pointee {
                    samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frameLength))
                }
                outputBuffer.frameLength = 0
            case .inputRanDry:
                continue
            case .endOfStream:
                isDone = true
            case .error:
                throw LocalWhisperError.conversionFailed("Converter error.")
            @unknown default:
                isDone = true
            }
        }

        return samples
    }

    // MARK: - Downloading

    private func modelDirectory() throws -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolder = Bundle.main.bundleIdentifier ?? "dBrief"
        let modelDir = base
            .appendingPathComponent(appFolder, isDirectory: true)
            .appendingPathComponent("WhisperModels", isDirectory: true)
            .appendingPathComponent(model.name, isDirectory: true)
        try fileManager.createDirectory(at: modelDir, withIntermediateDirectories: true)
        return modelDir
    }

    private func composeInitialPrompt(userPrompt: String?) -> String {
        let trimmedUserPrompt = userPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedUserPrompt.isEmpty {
            return Self.bilingualPromptPrefix
        }
        return "\(Self.bilingualPromptPrefix)\n\(trimmedUserPrompt)"
    }

    private func downloadWithProgress(
        remoteURL: URL,
        destinationURL: URL,
        isEncoder: Bool,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let parentDir = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)

        if isEncoder {
            let tempZip = parentDir.appendingPathComponent("encoder-\(UUID().uuidString).zip")
            try await downloadFile(remoteURL: remoteURL, destinationURL: tempZip, onProgress: onProgress)
            try extractEncoder(from: tempZip, to: destinationURL)
            try? fileManager.removeItem(at: tempZip)
        } else {
            try await downloadFile(remoteURL: remoteURL, destinationURL: destinationURL, onProgress: onProgress)
        }
    }

    private func downloadFile(
        remoteURL: URL,
        destinationURL: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let request = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData)
        let (bytes, response) = try await session.bytes(for: request)

        let expectedLength = response.expectedContentLength
        let tempURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)")

        fileManager.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        var received: Int64 = 0
        var buffer: [UInt8] = []
        buffer.reserveCapacity(64 * 1024)

        func flushBuffer() throws {
            guard !buffer.isEmpty else { return }
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }

        for try await byte in bytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= 64 * 1024 {
                try flushBuffer()
                if expectedLength > 0 {
                    onProgress(Double(received) / Double(expectedLength))
                }
            }
        }

        try flushBuffer()
        if expectedLength > 0 {
            onProgress(1)
        }

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        } catch {
            throw LocalWhisperError.fileWriteFailed
        }
    }

    private func extractEncoder(from zipURL: URL, to destinationURL: URL) throws {
        let tempDir = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".encoder-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, tempDir.path]

        let stderr = Pipe()
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "ditto failed"
            log.error("Failed to extract encoder: \(message, privacy: .public)")
            throw LocalWhisperError.downloadFailed
        }

        guard let encoderFolder = findEncoderFolder(in: tempDir) else {
            throw LocalWhisperError.missingEncoder(model.encoderFolderName)
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: encoderFolder, to: destinationURL)
    }

    private func findEncoderFolder(in directory: URL) -> URL? {
        if directory.pathExtension == "mlmodelc" {
            return directory
        }

        if let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for item in contents {
                if item.pathExtension == "mlmodelc" {
                    return item
                }
                if let nested = findEncoderFolder(in: item) {
                    return nested
                }
            }
        }
        return nil
    }
}
