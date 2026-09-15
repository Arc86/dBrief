import Foundation
import AppKit
import Testing
@testable import dBrief

@MainActor @Suite(.serialized)
struct PromptEditorSessionTests {
    @Test func nativeTypingUndoRestoresInheritance() throws {
        let settings = AppSettings()
        let savedProfiles = settings.profiles
        defer { settings.profiles = savedProfiles }
        var profile = MeetingProfile(name: "Undo test")
        profile.overrides.summaryPrompt = nil
        settings.profiles = [profile]
        let session = try PromptEditorSession(identity: .init(kind: .summary, scope: .profile(profile.id)), store: PromptPreferencesStore(settings: settings))
        let undo = UndoManager()
        undo.groupsByEvent = false
        session.undoManager = undo
        undo.beginUndoGrouping()
        session.edit(session.draft.text + "x")
        undo.endUndoGrouping()
        #expect(session.draft.hasChanges)
        undo.undo()
        #expect(session.draft.value == .inherited)
        #expect(!session.draft.hasChanges)
        undo.redo()
        #expect(session.draft.hasChanges)
    }

    @Test func editingRestoringAndReloadingNeverWriteUntilSave() throws {
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        try #require(!domain.hasPrefix("com.dbrief.app"))
        let defaults = UserDefaults.standard
        let saved = defaults.persistentDomain(forName: domain)
        defer { if let saved { defaults.setPersistentDomain(saved, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) } }
        let settings = AppSettings()
        settings.summaryPrompt = "Original"
        let store = PromptPreferencesStore(settings: settings)
        let session = try PromptEditorSession(identity: .init(kind: .summary, scope: .appDefaults), store: store)
        session.edit("Typed immediately before Save!")
        #expect(settings.summaryPrompt == "Original")
        try session.save()
        #expect(settings.summaryPrompt == "Typed immediately before Save!")
        #expect(!session.draft.hasChanges)
        session.restoreDefault()
        #expect(settings.summaryPrompt == "Typed immediately before Save!")
        try session.reloadSaved()
        #expect(session.draft.text == "Typed immediately before Save!")
        session.edit("Conflicting draft")
        settings.summaryPrompt = "External edit"
        #expect(throws: PromptPreferencesError.conflict) { try session.save() }
        #expect(session.draft.text == "Conflicting draft")
    }
}
