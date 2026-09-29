import Foundation

/// CLI aliases follow the provider's current model; full IDs pin a version.
/// IDs verified against https://code.claude.com/docs/en/model-config and
/// https://platform.claude.com/docs/en/models/overview on 2026-09-29.
enum ClaudeModelCatalog {
    struct Choice: Identifiable {
        let id: String
        let name: String
    }

    static let aliases: [Choice] = [
        .init(id: "haiku", name: "Haiku"),
        .init(id: "sonnet", name: "Sonnet"),
        .init(id: "opus", name: "Opus"),
        .init(id: "fable", name: "Fable"),
    ]

    static let versions: [Choice] = [
        .init(id: "claude-haiku-4-5-20251001", name: "Haiku 4.5"),
        .init(id: "claude-sonnet-5-5", name: "Sonnet 5.5"),
        .init(id: "claude-sonnet-5", name: "Sonnet 5"),
        .init(id: "claude-sonnet-4-6", name: "Sonnet 4.6"),
        .init(id: "claude-opus-5-5", name: "Opus 5.5"),
        .init(id: "claude-opus-5", name: "Opus 5"),
        .init(id: "claude-opus-4-6", name: "Opus 4.6"),
        .init(id: "claude-fable-5-1", name: "Fable 5.1"),
        .init(id: "claude-fable-5", name: "Fable 5"),
    ]

    static func contains(_ id: String) -> Bool {
        (aliases + versions).contains { $0.id == id }
    }
}
