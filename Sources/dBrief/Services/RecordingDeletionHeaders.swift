import Darwin
import Foundation

extension RecordingDeletionAuthority {
    /// Deletion reads identity projections, never transcript/delivery content.
    /// Bounds charge app-owned values conservatively; Foundation scratch/RSS is
    /// not measured or qualified by this worksheet.
    static func readHeader<T: Decodable>(_ url: URL) throws -> T? {
        guard let stamp = try Stamp.read(url) else { return nil }
        guard stamp.size >= 0, stamp.size <= 16 * 1_024 else { throw LiveArtifactError.artifactTooLarge }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw LiveArtifactError.unsafePath }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 16 * 1_024 + 1) ?? Data()
        guard data.count <= 16 * 1_024 else { throw LiveArtifactError.artifactTooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw LiveArtifactError.corruptArtifact }
        try preflightJSON(data)
        // JSONDecoder validates the complete syntax, while the small T selects
        // only ownership fields. No array of participant or delivery content.
        let result = try JSONDecoder().decode(T.self, from: data)
        guard try Stamp.read(url) == stamp else { throw LiveArtifactError.wrongOwner }
        return result
    }

    private static func preflightJSON(_ data: Data) throws {
        struct Frame { let object: Bool; var key = true; var seen: UInt16 = 0; var valueLimit = 0 }
        let keys = ["version", "id", "recordingID", "jobID", "masterFileName", "finalizedAudioPath", "audioFileURL", "source", "checkpoint", "bundle"]
        var frames: [Frame] = []; frames.reserveCapacity(32)
        var index = 0, tokens = 0
        func token() throws { tokens += 1; guard tokens <= 512 else { throw LiveArtifactError.artifactTooLarge } }
        while index < data.count {
            let byte = data[index]
            if [9, 10, 13, 32].contains(byte) { index += 1; continue }
            try token()
            switch byte {
            case 123, 91:
                guard frames.count < 32 else { throw LiveArtifactError.artifactTooLarge }
                frames.append(.init(object: byte == 123)); index += 1
            case 125, 93:
                guard let last = frames.popLast(), last.object == (byte == 125) else { throw LiveArtifactError.corruptArtifact }
                index += 1
            case 58:
                if frames.last?.object == true { frames[frames.count - 1].key = false }; index += 1
            case 44:
                if frames.last?.object == true { frames[frames.count - 1].key = true }; index += 1
            case 34:
                let start = index; index += 1
                while index < data.count, data[index] != 34 {
                    if data[index] == 92 { index += 1 }
                    index += 1
                }
                guard index < data.count else { throw LiveArtifactError.corruptArtifact }
                index += 1
                if frames.last?.object == true, frames.last?.key == true {
                    guard index - start <= 256 else { throw LiveArtifactError.artifactTooLarge }
                    let name = try JSONDecoder().decode(String.self, from: data.subdata(in: start..<index))
                    frames[frames.count - 1].valueLimit = 0
                    if let bit = keys.firstIndex(of: name) {
                        let flag = UInt16(1) << bit, last = frames.count - 1
                        guard frames[last].seen & flag == 0 else { throw LiveArtifactError.wrongOwner }
                        frames[last].seen |= flag
                        if [2, 1, 3].contains(bit) { frames[last].valueLimit = 256 }
                        if [4, 5, 6].contains(bit) { frames[last].valueLimit = 4_096 }
                    }
                } else if let frame = frames.last, frame.object, frame.valueLimit > 0 {
                    guard index - start <= frame.valueLimit else { throw LiveArtifactError.artifactTooLarge }
                }
            default:
                while index < data.count, ![9, 10, 13, 32, 123, 125, 91, 93, 58, 44, 34].contains(data[index]) { index += 1 }
            }
        }
        guard frames.isEmpty else { throw LiveArtifactError.corruptArtifact }
    }

    static func scanChildren(_ root: URL, visit: (URL) throws -> Void) throws {
        guard try Stamp.read(root, directory: true) != nil else { return }
        var failure: (any Error)?
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles], errorHandler: { _, error in failure = error; return false }) else { throw LiveArtifactError.unsafePath }
        var visited = 0
        for case let item as URL in iterator {
            visited += 1; guard visited <= 4_096, item.absoluteString.utf8.count <= 4_096 else { throw LiveArtifactError.artifactTooLarge }
            try visit(item)
        }
        if let failure { throw failure }
    }
}
