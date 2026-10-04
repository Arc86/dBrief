import Darwin
import Foundation

/// Content-free physical ownership frozen before deletion awaits. A missing
/// original is idempotent; a replacement at its name never inherits authority.
struct RecordingDeletionAuthority: Sendable {
    static let ticketLimit = 32 * 1_024
    static let inspectionAllowance = 128 * 1_024
    static func charge(_ url: URL) throws -> Int {
        guard url.absoluteString.utf8.count <= 4_096 else { throw LiveArtifactError.artifactTooLarge }
        return 160 + url.absoluteString.utf8.count * 6
    }
    struct Stamp: Codable, Sendable, Equatable {
        let device: UInt64, inode: UInt64, mode: UInt32, size: Int64
        let modified: Int64, modifiedNS: Int64, changed: Int64, changedNS: Int64
        static func read(_ url: URL, directory: Bool = false) throws -> Self? {
            var value = stat()
            guard lstat(url.path, &value) == 0 else {
                if errno == ENOENT { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { throw LiveArtifactError.unsafePath }
            return .init(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: UInt64(value.st_ino), mode: UInt32(value.st_mode),
                size: directory ? 0 : value.st_size,
                modified: directory ? 0 : Int64(value.st_mtimespec.tv_sec), modifiedNS: directory ? 0 : Int64(value.st_mtimespec.tv_nsec),
                changed: directory ? 0 : Int64(value.st_ctimespec.tv_sec), changedNS: directory ? 0 : Int64(value.st_ctimespec.tv_nsec))
        }
    }
    struct Item: Codable, Sendable {
        let url: URL
        let stamp: Stamp?
        let directory: Bool
        init(_ url: URL, directory: Bool = false) throws {
            self.url = try RecordingDeletionAuthority.canonical(url)
            self.directory = directory; stamp = try Stamp.read(self.url, directory: directory)
        }
        func validate() throws {
            // The first cleanup may have removed only part of the inventory.
            guard let current = try Stamp.read(url, directory: directory) else { return }
            guard current == stamp else { throw LiveArtifactError.wrongOwner }
        }
    }
    let audio: Item
    let metadata: Item
    let recordingID: UUID?
    var audioURL: URL { audio.url }
    static func canonical(_ url: URL) throws -> URL {
        guard url.isFileURL, url.absoluteString.utf8.count <= 4_096 else { throw LiveArtifactError.unsafePath }
        var directory = url.deletingLastPathComponent(), missing: [String] = []
        var resolved = directory.path.withCString { realpath($0, nil) }
        while resolved == nil, errno == ENOENT, directory.path != "/" {
            missing.append(directory.lastPathComponent); directory.deleteLastPathComponent()
            resolved = directory.path.withCString { realpath($0, nil) }
        }
        guard let parent = resolved else { throw LiveArtifactError.unsafePath }
        defer { free(parent) }
        var result = URL(fileURLWithPath: String(cString: parent))
        for component in missing.reversed() { result.appendPathComponent(component) }
        return result.appendingPathComponent(url.lastPathComponent)
    }
    init(audioURL: URL, expectedRecordingID: UUID? = nil) throws {
        audio = try Item(audioURL)
        metadata = try Item(audioURL.deletingPathExtension().appendingPathExtension("json"))
        let owner = try Self.metadataOwner(at: metadata.url, audioURL: audio.url)
        guard expectedRecordingID == nil || owner == nil || owner == expectedRecordingID else { throw LiveArtifactError.wrongOwner }
        recordingID = expectedRecordingID ?? owner
    }
    func validate() throws {
        try audio.validate(); try metadata.validate()
        if let owner = try Self.metadataOwner(at: metadata.url, audioURL: audio.url), owner != recordingID { throw LiveArtifactError.wrongOwner }
    }
    private static func metadataOwner(at url: URL, audioURL: URL) throws -> UUID? {
        struct Owner: Decodable { let recordingID: UUID; let masterFileName: String }
        // Legacy malformed metadata can still be explicitly deleted, using the
        // exact physical stamp. Supported metadata additionally binds its UUID.
        let value: Owner
        do { guard let header: Owner = try readHeader(url) else { return nil }; value = header }
        catch is DecodingError { return nil }
        catch LiveArtifactError.corruptArtifact { return nil }
        guard value.masterFileName.utf8.count <= 256 else { throw LiveArtifactError.artifactTooLarge }
        guard value.masterFileName == audioURL.lastPathComponent else { throw LiveArtifactError.wrongOwner }
        return value.recordingID
    }
}
