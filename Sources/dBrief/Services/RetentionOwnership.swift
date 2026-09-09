import Foundation

/// Ownership is established before any deletions. Extensions alone are never
/// evidence: output folders may also contain a vault or unrelated project files.
struct RetentionOwnership {
    private(set) var artifacts = Set<URL>()
    private(set) var audio = Set<URL>()
    /// An export can have a different name or multiple recording owners.
    private(set) var owners: [URL: Set<URL>] = [:]
    /// Keep the record that proves ownership until its dependent files disappear.
    private(set) var dependencies: [URL: Set<URL>] = [:]

    init(folders: [URL], trustedAudio: Set<URL> = [], fileManager: FileManager = .default) {
        let roots = folders.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        func inScope(_ url: URL) -> Bool {
            roots.contains { url.path.hasPrefix($0.path + "/") }
        }
        func register(_ master: URL, segments: [URL], metadata: URL?) {
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
                let note = URL(fileURLWithPath: path).standardizedFileURL
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

        for url in Self.regularFiles(in: roots, fileManager: fileManager) where url.pathExtension == "json" {
            guard let data = Self.smallData(url),
                  let metadata = try? JSONDecoder().decode(RecordingMetadataPayload.self, from: data),
                  Self.safeName(metadata.masterFileName),
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
            if valid { register(master, segments: segments, metadata: url) }
        }
        // Validated durable processing/delivery journals may outlive a missing
        // metadata sidecar. The caller captures these paths before retiring them.
        for url in trustedAudio {
            let master = url.standardizedFileURL
            guard master.isFileURL, inScope(master),
                  RetentionCleanup.audioExtensions.contains(master.pathExtension.lowercased()) else { continue }
            register(master, segments: [], metadata: nil)
        }
    }

    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }

    private static func smallData(_ url: URL) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 4 * 1_024 * 1_024 else { return nil }
        return try? Data(contentsOf: url)
    }

    static func isRegularUnlinked(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let path = url.standardizedFileURL
        guard path == path.resolvingSymlinksInPath(),
              let type = try? fileManager.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType else { return false }
        return type == .typeRegular
    }

    static func regularFiles(in folders: [URL], fileManager: FileManager = .default) -> Set<URL> {
        var files = Set<URL>()
        for folder in Set(folders.map { $0.resolvingSymlinksInPath().standardizedFileURL }) {
            guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where isRegularUnlinked(url, fileManager: fileManager) {
                files.insert(url.standardizedFileURL)
            }
        }
        return files
    }
}
