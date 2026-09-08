import Foundation

/// Frozen before publishing a note. Recovery uses these exact bytes and destination
/// even if titles, export settings, or model configuration change after a crash.
struct MarkdownExportPlan: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version: Int = currentVersion
    let destination: URL
    let content: String
    let generatedTitle: String?

    func validate() throws {
        guard version == Self.currentVersion else {
            throw MarkdownOutputStore.OutputError.unsupportedVersion
        }
        guard destination.isFileURL, destination.path.hasPrefix("/"),
              destination.pathExtension.lowercased() == "md" else {
            throw MarkdownOutputStore.OutputError.invalidDestination
        }
    }
}
