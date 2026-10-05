import Foundation
import dBriefWire

/// Ownership is established before any deletions. Extensions alone are never
/// evidence: output folders may also contain a vault or unrelated project files.
struct RetentionOwnership: Sendable {
    private(set) var inspectionFailed = false
    private(set) var artifacts = Set<URL>()
    private(set) var audio = Set<URL>()
    private(set) var recordingIDs: [URL: UUID] = [:]
    private(set) var opaqueLiveBases = Set<String>()
    /// An export can have a different name or multiple recording owners.
    private(set) var owners: [URL: Set<URL>] = [:]
    /// Keep the record that proves ownership until its dependent files disappear.
    private(set) var dependencies: [URL: Set<URL>] = [:]

    init(folders: [URL], trustedAudio: Set<URL> = [], fileManager: FileManager = .default) {
        do { opaqueLiveBases = try Self.preflight(folders: folders, fileManager: fileManager) }
        catch { inspectionFailed = true; return }
        let roots = folders.map(Self.canonicalFolder)
        func inScope(_ url: URL) -> Bool {
            roots.contains { url.path.hasPrefix($0.path + "/") }
        }
        func register(_ master: URL, segments: [URL], metadata: URL?, recordingID: UUID? = nil) {
            if let recordingID { recordingIDs[master] = recordingID }
            let base = master.deletingPathExtension()
            let tracks = Set([master] + segments)
            audio.formUnion(tracks.filter(inScope))
            var children = Set(RetentionCleanup.transcriptSuffixes.filter { $0 != ".md" }.map {
                URL(fileURLWithPath: base.path + $0)
            })
            let insightsURL = base.appendingPathExtension("insights.json")
            if Self.isRegularUnlinked(insightsURL, fileManager: fileManager),
               let data = Self.smallData(insightsURL),
               let insights = try? JSONDecoder().decode(RecordingInsights.self, from: data),
               insights.version == RecordingInsights.currentVersion,
               let path = insights.markdownPath, path.hasPrefix("/"),
               URL(fileURLWithPath: path).pathExtension.lowercased() == "md" {
                let note = (try? RecordingDeletionAuthority.canonical(URL(fileURLWithPath: path))) ?? URL(fileURLWithPath: path)
                // Out-of-scope notes are never candidates, but their link must
                // survive so a future sweep of that folder can establish ownership.
                if inScope(note) { children.insert(note) }
                dependencies[insightsURL, default: []].insert(note)
            }
            artifacts.formUnion(children.filter(inScope))
            artifacts.formUnion(tracks.filter(inScope))
            for artifact in children.union(tracks) {
                owners[artifact, default: []].insert(master)
            }
            if let metadata {
                artifacts.insert(metadata)
                owners[metadata, default: []].insert(master)
                dependencies[metadata, default: []].formUnion(children.union(tracks))
            }
        }

        var count = 0
        for url in Self.regularFiles(in: roots, fileManager: fileManager) where url.pathExtension == "json" {
            guard let data = Self.smallData(url),
                  let metadata = try? JSONDecoder().decode(RecordingMetadataPayload.self, from: data),
                  Self.safeName(metadata.masterFileName), metadata.segmentFileNames.count <= 128,
                  metadata.durationSeconds.isFinite, metadata.durationSeconds >= 0,
                  ISO8601DateFormatter().date(from: metadata.dateISO8601) != nil else { continue }
            let master = url.deletingLastPathComponent().appendingPathComponent(metadata.masterFileName)
            let stem = master.deletingPathExtension().lastPathComponent
            guard RetentionCleanup.audioExtensions.contains(master.pathExtension.lowercased()),
                  url == master.deletingPathExtension().appendingPathExtension("json") else { continue }
            var segments: [URL] = []
            var valid = true
            for name in metadata.segmentFileNames {
                let segment = url.deletingLastPathComponent().appendingPathComponent(name)
                let segmentStem = segment.deletingPathExtension().lastPathComponent
                let prefix = stem + "_part"
                guard Self.safeName(name), segmentStem.hasPrefix(prefix),
                      !segmentStem.dropFirst(prefix.count).isEmpty,
                      segmentStem.dropFirst(prefix.count).allSatisfy(\.isNumber),
                      RetentionCleanup.audioExtensions.contains(segment.pathExtension.lowercased()) else {
                    valid = false
                    break
                }
                segments.append(segment)
            }
            if valid {
                count += 1
                guard count <= 128 else { inspectionFailed = true; return }
                register(master, segments: segments, metadata: url, recordingID: metadata.recordingID)
            }
        }
        // Validated durable processing/delivery journals may outlive a missing
        // metadata sidecar. The caller captures these paths before retiring them.
        for url in trustedAudio {
            let master = (try? RecordingDeletionAuthority.canonical(url)) ?? url
            guard master.isFileURL, inScope(master),
                  RetentionCleanup.audioExtensions.contains(master.pathExtension.lowercased()) else { continue }
            register(master, segments: [], metadata: nil)
        }
    }

    static func canonicalFolder(_ url: URL) -> URL {
        (try? RecordingDeletionAuthority.canonical(url.appendingPathComponent("probe")).deletingLastPathComponent()) ?? url
    }

    private struct ManagedChatHeader: Decodable {
        let version: Int
        let identity: LiveSessionIdentity?
        let revision: UInt64?
        let bindingGeneration: UUID?
    }

    /// Reused bounded negative-ownership predicate; missing ordinary files do
    /// not grant new ownership and unsupported/artifact headers remain opaque.
    static func isOrdinaryChat(_ url: URL) throws -> Bool {
        guard let header: ManagedChatHeader = try RecordingDeletionAuthority.readHeader(url,
            maximumBytes: LiveRecordingArtifactOwner.chatHistoryLimit, tokenLimit: 1_048_576) else { return true }
        return (1...ChatHistory.currentVersion).contains(header.version) && header.identity == nil
            && header.revision == nil && header.bindingGeneration == nil
    }

    /// Admission runs before recovery reconciliation or any retention effect.
    /// The existing ownership builder is safe only within this finite worksheet.
    @discardableResult
    static func preflight(folders: [URL], fileManager: FileManager = .default) throws -> Set<String> {
        guard folders.count <= 32 else { throw LiveArtifactError.artifactTooLarge }
        var visited = 0, pathBytes = 0, metadataBytes = 0, metadataCount = 0, familyBytes = 0
        var opaque = Set<String>()
        let roots = Set(folders.map(Self.canonicalFolder))
        for root in roots {
            guard try RecordingDeletionAuthority.Stamp.read(root, directory: true) != nil else { continue }
            var failure: (any Error)?
            guard let iterator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false }) else {
                if fileManager.fileExists(atPath: root.path) { throw LiveArtifactError.unsafePath }; continue
            }
            for case let url as URL in iterator {
                visited += 1; guard visited <= 4_096 else { throw LiveArtifactError.artifactTooLarge }
                pathBytes += try RecordingDeletionAuthority.charge(url)
                guard pathBytes <= 512 * 1_024 else { throw LiveArtifactError.artifactTooLarge }
                let name = url.lastPathComponent.lowercased()
                let markerBase = try RecordingDeletionAuthority.canonical(url).deletingPathExtension().deletingPathExtension().path
                if [".live-transcript.json", ".live-binding.json"].contains(where: name.hasSuffix) {
                    opaque.insert(markerBase)
                } else if name.hasSuffix(".chat.json") {
                    // Discover negative ownership independently of valid master
                    // metadata, before recovery or private backup effects.
                    do {
                        if try !isOrdinaryChat(url) { opaque.insert(markerBase) }
                    } catch { opaque.insert(markerBase) }
                }
                guard isRegularUnlinked(url, fileManager: fileManager), url.pathExtension == "json",
                      !RetentionCleanup.isTranscriptFile(url.lastPathComponent),
                      ![".privacy.json", ".queue.json", ".live-binding.json"].contains(where: { url.lastPathComponent.hasSuffix($0) }) else { continue }
                guard let stamp = try RecordingDeletionAuthority.Stamp.read(url), stamp.size <= 128 * 1_024 else { throw LiveArtifactError.artifactTooLarge }
                metadataBytes += Int(stamp.size); metadataCount += 1
                guard metadataBytes <= 512 * 1_024, metadataCount <= 128 else { throw LiveArtifactError.artifactTooLarge }
                let metadata: RecordingMetadataPayload?
                do { metadata = try RecordingDeletionAuthority.readHeader(url, maximumBytes: 128 * 1_024, tokenLimit: 32_768) }
                catch is DecodingError { continue }
                guard let metadata else { continue }
                guard metadata.segmentFileNames.count <= 128 else { throw LiveArtifactError.artifactTooLarge }
                guard safeName(metadata.masterFileName),
                      metadata.segmentFileNames.allSatisfy(safeName) else { continue }
                let master = url.deletingLastPathComponent().appendingPathComponent(metadata.masterFileName), base = master.deletingPathExtension()
                for child in [master, url] + metadata.segmentFileNames.map({ url.deletingLastPathComponent().appendingPathComponent($0) })
                    + RetentionCleanup.transcriptSuffixes.map({ URL(fileURLWithPath: base.path + $0) }) {
                    familyBytes += try RecordingDeletionAuthority.charge(child) * 3
                    guard familyBytes <= 4 * 1_024 * 1_024 else { throw LiveArtifactError.artifactTooLarge }
                }
            }
            if let failure { throw failure }
        }
        // Linked export paths are inspected one at a time under the same bound.
        for url in regularFiles(in: Array(roots), fileManager: fileManager) where url.lastPathComponent.hasSuffix(".insights.json") {
            guard let stamp = try RecordingDeletionAuthority.Stamp.read(url), stamp.size <= 128 * 1_024 else { throw LiveArtifactError.artifactTooLarge }
            metadataBytes += Int(stamp.size)
            guard metadataBytes <= 512 * 1_024 else { throw LiveArtifactError.artifactTooLarge }
            let insights: RecordingInsights?
            do { insights = try RecordingDeletionAuthority.readHeader(url, maximumBytes: 128 * 1_024, tokenLimit: 32_768) }
            catch is DecodingError { continue }
            if let path = insights?.markdownPath {
                familyBytes += try RecordingDeletionAuthority.charge(URL(fileURLWithPath: path)) * 3
                guard familyBytes <= 4 * 1_024 * 1_024 else { throw LiveArtifactError.artifactTooLarge }
            }
        }
        return opaque
    }

    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }

    private static func smallData(_ url: URL) -> Data? {
        try? RecordingDeletionAuthority.readJSON(url, maximumBytes: 128 * 1_024, tokenLimit: 32_768)
    }

    static func isRegularUnlinked(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let path = url.standardizedFileURL
        guard path == path.resolvingSymlinksInPath(),
              let type = try? fileManager.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType else { return false }
        return type == .typeRegular
    }

    static func regularFiles(in folders: [URL], fileManager: FileManager = .default) -> Set<URL> {
        var files = Set<URL>(), visited = 0, bytes = 0
        for folder in Set(folders.map(Self.canonicalFolder)) {
            guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                visited += 1; bytes += (try? RecordingDeletionAuthority.charge(url)) ?? Int.max / 8
                guard visited <= 4_096, bytes <= 512 * 1_024 else { return [] }
                if isRegularUnlinked(url, fileManager: fileManager) { if let physical = try? RecordingDeletionAuthority.canonical(url) { files.insert(physical) } }
            }
        }
        return files
    }
}
