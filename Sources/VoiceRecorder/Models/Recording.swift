import Foundation

@MainActor
@Observable
final class Recording: Identifiable {
    let id: UUID
    let date: Date
    var fileURL: URL
    var duration: TimeInterval
    var fileSize: Int64
    var transcription: TranscriptionResult?
    var summary: String?
    var actionItems: [String]?
    var tags: [String]?
    var sentiment: String?
    var generatedTitle: String?
    var associatedApp: String?
    var obsidianFolderRelativePath: String?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        fileURL: URL,
        duration: TimeInterval = 0,
        fileSize: Int64 = 0,
        associatedApp: String? = nil
    ) {
        self.id = id
        self.date = date
        self.fileURL = fileURL
        self.duration = duration
        self.fileSize = fileSize
        self.associatedApp = associatedApp
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var fileName: String {
        fileURL.deletingPathExtension().lastPathComponent
    }
}
