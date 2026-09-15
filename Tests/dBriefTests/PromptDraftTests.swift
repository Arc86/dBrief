import Foundation
import Testing
@testable import dBrief

struct PromptDraftTests {
    @Test func inheritedDraftOnlyOverridesWhenEdited() {
        let snapshot = PromptSnapshot(identity: .init(kind: .summary, scope: .profile(UUID())),
                                      value: .inherited, sharedText: "Shared", factoryText: "Factory", scopeName: "Work")
        var draft = PromptDraft(snapshot: snapshot)
        #expect(draft.text == "Shared")
        #expect(!draft.hasChanges)
        draft.text = "Shared"
        #expect(draft.hasChanges)
        #expect(draft.value == .custom("Shared"))
        draft.value = .inherited
        #expect(!draft.hasChanges)
    }
}

@MainActor @Suite(.serialized)
struct PromptPreferencesStoreTests {
    private func withSettings(_ body: (AppSettings, PromptPreferencesStore) throws -> Void) throws {
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        try #require(!domain.hasPrefix("com.dbrief.app"))
        let defaults = UserDefaults.standard
        let saved = defaults.persistentDomain(forName: domain)
        defer {
            if let saved { defaults.setPersistentDomain(saved, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
        }
        let settings = AppSettings()
        try body(settings, PromptPreferencesStore(settings: settings))
    }

    @Test func saveTargetsInactiveProfileAndPreservesOtherChanges() throws {
        try withSettings { settings, store in
            let edited = MeetingProfile(name: "Edited")
            let active = MeetingProfile(name: "Active")
            settings.profiles = [edited, active]
            settings.setActiveProfile(active.id)
            settings.summaryPrompt = "Shared"
            var draft = PromptDraft(snapshot: try store.load(.init(kind: .summary, scope: .profile(edited.id))))
            draft.text = "Only edited profile"
            #expect(settings.profiles[0].overrides.summaryPrompt == nil)
            settings.profiles[0].overrides.autoSummary = false
            _ = try store.save(draft)
            #expect(settings.activeProfileId == active.id)
            #expect(settings.profiles[0].overrides.summaryPrompt == "Only edited profile")
            #expect(settings.profiles[0].overrides.autoSummary == false)
            #expect(settings.summaryPrompt == "Shared")
            #expect(settings.profiles[1].overrides.summaryPrompt == nil)
        }
    }

    @Test func conflictingSaveAndDeletedProfileKeepStoredValues() throws {
        try withSettings { settings, store in
            settings.summaryPrompt = "Original"
            var draft = PromptDraft(snapshot: try store.load(.init(kind: .summary, scope: .appDefaults)))
            draft.text = "Draft"
            settings.summaryPrompt = "Changed elsewhere"
            #expect(throws: PromptPreferencesError.conflict) { try store.save(draft) }
            #expect(settings.summaryPrompt == "Changed elsewhere")
            let profile = MeetingProfile(name: "Temporary")
            settings.profiles.append(profile)
            var profileDraft = PromptDraft(snapshot: try store.load(.init(kind: .summary, scope: .profile(profile.id))))
            profileDraft.text = "Draft"
            settings.profiles.removeAll { $0.id == profile.id }
            #expect(throws: PromptPreferencesError.profileMissing) { try store.save(profileDraft) }
        }
    }

    @Test func inheritanceResetWritesNilAndSharedChangeConflicts() throws {
        try withSettings { settings, store in
            let profile = MeetingProfile(name: "Work", overrides: .init(summaryPrompt: "Override"))
            settings.profiles = [profile]
            let identity = PromptIdentity(kind: .summary, scope: .profile(profile.id))
            var draft = PromptDraft(snapshot: try store.load(identity))
            draft.value = .inherited
            _ = try store.save(draft)
            #expect(settings.profiles[0].overrides.summaryPrompt == nil)
            draft = PromptDraft(snapshot: try store.load(identity))
            draft.text = "New override"
            settings.summaryPrompt += " externally changed"
            #expect(throws: PromptPreferencesError.conflict) { try store.save(draft) }
        }
    }

    @Test func allDefaultsSaveAndInvalidScopeOrBlankIsRejected() throws {
        try withSettings { settings, store in
            for kind in PromptKind.allCases {
                let identity = PromptIdentity(kind: kind, scope: .appDefaults)
                var draft = PromptDraft(snapshot: try store.load(identity))
                draft.text = "New \(kind.rawValue)\nKeep formatting\n"
                #expect(try store.save(draft).value == draft.value)
                var blank = PromptDraft(snapshot: try store.load(identity))
                blank.text = "  \n"
                #expect(throws: PromptPreferencesError.emptyPrompt) { try store.save(blank) }
            }
            #expect(throws: PromptPreferencesError.unsupportedScope) {
                try store.load(.init(kind: .spokenSummary, scope: .profile(settings.profiles[0].id)))
            }
        }
    }
}
