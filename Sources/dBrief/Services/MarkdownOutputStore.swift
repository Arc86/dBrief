import Foundation
import Darwin

/// Publishes frozen Markdown without replacing an existing note. The caller must
/// durably save the plan before calling publish, then checkpoint the verified result.
actor MarkdownOutputStore {
    enum OutputError: Error, LocalizedError {
        case unsupportedVersion, invalidDestination, conflict

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: "The saved Markdown export version is not supported."
            case .invalidDestination: "The saved Markdown destination is invalid."
            case .conflict: "The Markdown destination contains another file or edited note. It was left untouched."
            }
        }
    }

    /// Preserve the usual filename when available; isolate collisions by job UUID.
    /// Once saved, the plan never chooses a new path during recovery.
    func prepare(_ proposed: MarkdownExportPlan, jobID: UUID) throws -> MarkdownExportPlan {
        try proposed.validate()
        guard exists(proposed.destination) else { return proposed }
        let destination = proposed.destination.deletingPathExtension()
            .appendingPathExtension("\(jobID.uuidString.lowercased()).md")
        return MarkdownExportPlan(destination: destination, content: proposed.content,
                                  generatedTitle: proposed.generatedTitle)
    }

    /// Migration for a Phase 5B export already recorded in insights.json. Read and
    /// preserve the note as-is, including user edits made since its original export.
    func adoptExisting(at destination: URL, generatedTitle: String?) throws -> MarkdownExportPlan {
        let content = try readRegularFile(destination)
        let plan = MarkdownExportPlan(destination: destination, content: content,
                                      generatedTitle: generatedTitle)
        try plan.validate()
        return plan
    }

    func publish(_ plan: MarkdownExportPlan, alreadyCompleted: Bool = false) async throws -> URL {
        try plan.validate()
        try Task.checkCancellation()
        if alreadyCompleted {
            // A completed note becomes user-owned. Verify availability but never
            // restore the original bytes over subsequent edits.
            _ = try readRegularFile(plan.destination)
            return plan.destination
        }
        if exists(plan.destination) {
            try verify(plan)
            return plan.destination
        }
        return try await PrivacyTrace.perform(.init(stage: .markdownExport, data: [.text, .metadata],
                                                     destination: .local(provider: .fileSystem))) {
            let folder = plan.destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let temporary = folder.appendingPathComponent(".dbrief-export-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Data(plan.content.utf8).write(to: temporary, options: .atomic)
            try Task.checkCancellation()
            // Publish a fully written sibling atomically, refusing to replace a target
            // created since the existence check. No hard-link support is required.
            let result = temporary.withUnsafeFileSystemRepresentation { source in
                plan.destination.withUnsafeFileSystemRepresentation { destination in
                    renamex_np(source!, destination!, UInt32(RENAME_EXCL))
                }
            }
            if result != 0 {
                let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                guard exists(plan.destination) else { throw failure }
                try verify(plan)
            }
            try verify(plan)
            return plan.destination
        }
    }

    /// Explicit AI retry historically regenerates its destination. Keep that
    /// policy separate from restartable publication, which never replaces edits.
    func regenerate(_ plan: MarkdownExportPlan) async throws -> URL {
        try plan.validate()
        try Task.checkCancellation()
        return try await PrivacyTrace.perform(.init(stage: .markdownExport, data: [.text, .metadata],
                                                     destination: .local(provider: .fileSystem))) {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: plan.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plan.content.write(to: plan.destination, atomically: true, encoding: .utf8)
            try Task.checkCancellation()
            try verify(plan)
            return plan.destination
        }
    }

    private func verify(_ plan: MarkdownExportPlan) throws {
        guard try readRegularFile(plan.destination) == plan.content else {
            throw OutputError.conflict
        }
    }

    private func readRegularFile(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw OutputError.conflict
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool {
        // Includes dangling symlinks: they must never be followed or overwritten.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}
