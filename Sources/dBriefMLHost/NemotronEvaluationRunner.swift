import CryptoKit
import Darwin
import FluidAudio
import Foundation

struct NemotronEvaluationOptions: Sendable {
    let manifest: URL
    let inputDirectory: URL
    let modelDirectory: URL
    let report: URL
    let chunkMs: Int
    let lanes: Int
    let allowDownload: Bool
    static func parse(_ arguments: [String]) throws -> Self {
        let pathKeys = ["--manifest", "--input-directory", "--model-directory", "--report"]
        let valueKeys = Set(pathKeys + ["--chunk-ms", "--lanes"])
        var values: [String: String] = [:], flags = Set<String>()
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            if ["--nemotron-evaluate", "--allow-download"].contains(key) {
                guard flags.insert(key).inserted else { throw NemotronSessionError.invalidConfiguration }
            } else {
                guard valueKeys.contains(key), values[key] == nil, index + 1 < arguments.count else {
                    throw NemotronSessionError.invalidConfiguration
                }
                index += 1
                values[key] = arguments[index]
            }
            index += 1
        }
        guard flags.contains("--nemotron-evaluate"), pathKeys.allSatisfy({ values[$0]?.hasPrefix("/") == true }),
              let chunkMs = Int(values["--chunk-ms"] ?? "1120"), let lanes = Int(values["--lanes"] ?? "1"),
              [1, 2].contains(lanes) else { throw NemotronSessionError.invalidConfiguration }
        _ = try NemotronDecoderConfiguration(language: .auto, chunkMs: chunkMs)
        return .init(manifest: URL(fileURLWithPath: values["--manifest"]!),
            inputDirectory: URL(fileURLWithPath: values["--input-directory"]!),
            modelDirectory: URL(fileURLWithPath: values["--model-directory"]!),
            report: URL(fileURLWithPath: values["--report"]!), chunkMs: chunkMs, lanes: lanes,
            allowDownload: flags.contains("--allow-download"))
    }
}

struct NemotronFixtureManifest: Decodable, Sendable {
    struct Fixture: Decodable, Sendable {
        let id: String
        let pcmFile: String
        let language: NemotronDecoderConfiguration.Language
        let utteranceEnds: [Int64]
    }
    let schemaVersion: Int
    let fixtures: [Fixture]
    func validate() throws {
        guard schemaVersion == 1, !fixtures.isEmpty, fixtures.count <= 100,
              Set(fixtures.map(\.id)).count == fixtures.count,
              fixtures.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 80 &&
                  $0.id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                      (48...57).contains($0) || [45, 95].contains($0) }) }) else {
            throw NemotronSessionError.invalidConfiguration
        }
    }
}

struct NemotronFixturePacket: Sendable, Equatable {
    let range: Range<Int64>
    let finishesUtterance: Bool
}

enum NemotronFixtureSchedule {
    static func packets(sampleCount: Int64, utteranceEnds: [Int64]) throws -> [NemotronFixturePacket] {
        guard sampleCount > 0, sampleCount <= 16000 * 90 * 60, utteranceEnds.last == sampleCount else {
            throw NemotronSessionError.invalidConfiguration
        }
        var previous: Int64 = 0
        for end in utteranceEnds {
            guard end > previous, end - previous <= 240000 else { throw NemotronSessionError.invalidConfiguration }
            previous = end
        }
        var result: [NemotronFixturePacket] = [], start: Int64 = 0
        for end in utteranceEnds {
            while start < end {
                let stop = min(end, start + 1600)
                result.append(.init(range: start..<stop, finishesUtterance: stop == end))
                start = stop
            }
        }
        return result
    }
}

final class NemotronFixtureInput: @unchecked Sendable {
    let sampleCount: Int64
    private let handle: FileHandle
    private var position: Int64 = 0
    private var hash = SHA256()
    // Exactly one fixture task owns this stream; never share it between lanes.
    init(fixture: NemotronFixtureManifest.Fixture, directory: URL) throws {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let components = fixture.pcmFile.split(separator: "/", omittingEmptySubsequences: false)
        guard !fixture.pcmFile.hasPrefix("/"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw NemotronSessionError.invalidPacket
        }
        let path = root.appendingPathComponent(fixture.pcmFile).resolvingSymlinksInPath().standardizedFileURL
        guard path.path.hasPrefix(root.path + "/") else { throw NemotronSessionError.invalidPacket }
        let opened = try FileHandle(forReadingFrom: path)
        var info = stat()
        guard fstat(opened.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size % 4 == 0, info.st_size / 4 <= 16000 * 90 * 60 else {
            try? opened.close(); throw NemotronSessionError.invalidPacket
        }
        sampleCount = Int64(info.st_size / 4)
        handle = opened
    }
    deinit { try? handle.close() }
    func read(_ range: Range<Int64>) throws -> [Float] {
        guard range.lowerBound == position, range.upperBound <= sampleCount,
              !range.isEmpty, range.count <= 3200 else { throw NemotronSessionError.invalidPacket }
        let bytes = range.count * 4
        let data = try handle.read(upToCount: bytes) ?? Data()
        guard data.count == bytes else { throw NemotronSessionError.invalidPacket }
        let samples = data.withUnsafeBytes { raw in
            stride(from: 0, to: bytes, by: 4).map { offset in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
        }
        guard samples.allSatisfy(\.isFinite) else { throw NemotronSessionError.invalidPacket }
        hash.update(data: data); position = range.upperBound
        return samples
    }
    var sha256: String { hash.finalize().map { String(format: "%02x", $0) }.joined() }
}

enum NemotronEvaluationRunner {
    static let usage = """
    dBriefMLHost --nemotron-evaluate --manifest /absolute/manifest.json
      --input-directory /absolute/fixtures --model-directory /absolute/variant
      --report /absolute/new-report.json [--chunk-ms 560|1120|2240] [--lanes 1|2]
      [--allow-download]

    Input is mono 16 kHz Float32 little-endian PCM, paced in at most 100 ms packets.
    Without --allow-download, model-directory is an existing full multilingual variant.
    With --allow-download, model-directory is the explicit download cache root;
    the full multilingual variant is selected independently of EN/NL/auto hints.
    Reports contain aggregate metrics, not transcript text; quality remains unscored.
    """

    static func run(_ options: NemotronEvaluationOptions) async throws -> NemotronEvaluationReport {
        let driver = NemotronEvaluationDriver(clock: NemotronMonotonicClock()) { options, languages in
            let directory: URL
            if options.allowDownload {
                directory = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                    languageCode: "multilingual", chunkMs: options.chunkMs, to: options.modelDirectory)
            } else { directory = options.modelDirectory }
            for language in languages {
                try NemotronDecoderFactory.validateMetadata(at: directory,
                    configuration: .init(language: language, chunkMs: options.chunkMs))
            }
            return try await NemotronDecoderFactory.load(from: directory,
                configuration: .init(language: .auto, chunkMs: options.chunkMs))
        }
        let report = try await driver.run(options)
        try write(report, to: options.report)
        return report
    }

    static func write(_ report: NemotronEvaluationReport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".nemotron-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw NemotronSessionError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        // link creates the final name atomically and fails if it already exists.
        // A concurrent report writer cannot overwrite an earlier result.
        guard link(temporary.path, url.path) == 0 else { throw NemotronSessionError.unavailable }
    }
}
