import Foundation

enum PromptValue: Equatable, Sendable { case inherited, custom(String) }
struct PromptSnapshot: Equatable, Sendable {
    let identity: PromptIdentity
    let value: PromptValue
    let sharedText: String
    let factoryText: String
    let scopeName: String
}
struct PromptDraft: Equatable, Sendable {
    let baseline: PromptSnapshot
    var value: PromptValue
    init(snapshot: PromptSnapshot) { baseline = snapshot; value = snapshot.value }
    var text: String {
        get {
            switch value {
            case .inherited: baseline.sharedText
            case .custom(let text): text
            }
        }
        set { value = .custom(newValue) }
    }
    var hasChanges: Bool { value != baseline.value }
    var canSave: Bool {
        hasChanges && (value == .inherited || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
