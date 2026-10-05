import Foundation

/// Runtime, content-free capture anchor. Admission proves only lexical bounds;
/// the retention transaction must separately verify actual storage authority.
struct LiveRAMCaptureMetadata: Sendable, Equatable {
    let startedAt: Date
    let intendedFolder: URL?
    init(startedAt: Date, intendedFolder: URL? = nil) throws {
        guard startedAt.timeIntervalSinceReferenceDate.isFinite else { throw LiveArtifactError.corruptArtifact }
        if let folder = intendedFolder {
            guard folder.isFileURL, folder.baseURL == nil, folder.absoluteString.utf8.count <= 4_096 else { throw LiveArtifactError.unsafePath }
            let path = folder.path
            // Foundation's standardizedFileURL consults an existing directory
            // to infer a trailing slash. Capture admission must stay lexical.
            guard path.hasPrefix("/"),
                  folder.host == nil || folder.host == "" || folder.host == "localhost",
                  folder.user == nil, folder.password == nil, folder.port == nil,
                  folder.query == nil, folder.fragment == nil,
                  !path.contains("//"), !path.utf8.contains(0),
                  path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }),
                  folder.absoluteString == URL(fileURLWithPath: path, isDirectory: folder.hasDirectoryPath).absoluteString
            else { throw LiveArtifactError.unsafePath }
        }
        self.startedAt = startedAt; self.intendedFolder = intendedFolder
    }
    private init(trustedStart: Date) { startedAt = trustedStart; intendedFolder = nil }
    static func now() -> Self { .init(trustedStart: Date.now) }
}

/// Never serialized and never contains transcript/chat facts. The retirement
/// marker cannot be cleared by another accepted clock sample or by a disk hint.
struct LiveRAMSourceMetadata: Sendable, Equatable {
    let capture: LiveRAMCaptureMetadata
    let lastFinalAcceptedAt: Date?
    let sourceRetired: Bool
    init(capture: LiveRAMCaptureMetadata) {
        self.capture = capture; lastFinalAcceptedAt = nil; sourceRetired = false
    }
    private init(capture: LiveRAMCaptureMetadata, final: Date?, retired: Bool) {
        self.capture = capture; lastFinalAcceptedAt = final; sourceRetired = retired
    }
    func acceptingFinal(at time: Date) throws -> Self {
        guard time.timeIntervalSinceReferenceDate.isFinite else { throw LiveArtifactError.corruptArtifact }
        let conservative = max(time, capture.startedAt, lastFinalAcceptedAt ?? capture.startedAt)
        return .init(capture: capture, final: conservative, retired: sourceRetired)
    }
    func retiringSource() -> Self { .init(capture: capture, final: lastFinalAcceptedAt, retired: true) }
    func isOlder(than cutoff: Date) -> Bool {
        cutoff.timeIntervalSinceReferenceDate.isFinite && capture.startedAt < cutoff
            && (lastFinalAcceptedAt.map { $0 < cutoff } ?? true)
    }
    var charge: Int { 128 + (capture.intendedFolder?.absoluteString.utf8.count ?? 0) * 6 }
}
