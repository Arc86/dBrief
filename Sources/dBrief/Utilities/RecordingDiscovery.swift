import Foundation

struct RecordingFileEntry: Sendable {
    let url: URL
    let createdAt: Date
    let size: Int64
}

enum RecordingDiscovery {
    static let supportedExtensions: Set<String> = ["flac", "m4a", "wav", "mp3", "aac"]

    static func discover(
        in folder: URL,
        fileManager: FileManager = .default
    ) -> [RecordingFileEntry] {
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [RecordingFileEntry] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }
            // Skip the spoken-summary audio sidecar (`<base>.spokensummary.m4a`) —
            // it's a derived artifact, not a recording, so it must not appear in
            // the browser/history lists.
            guard !fileURL.deletingPathExtension().lastPathComponent.hasSuffix(".spokensummary") else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .creationDateKey, .fileSizeKey])
            guard values?.isRegularFile ?? false else { continue }

            results.append(
                RecordingFileEntry(
                    url: fileURL,
                    createdAt: values?.creationDate ?? .distantPast,
                    size: Int64(values?.fileSize ?? 0)
                )
            )
        }

        return results.sorted { $0.createdAt > $1.createdAt }
    }
}
