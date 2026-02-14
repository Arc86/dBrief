import Foundation

// MARK: - Profile Management

extension AppSettings {
    func setActiveProfile(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileId = id
    }

    @discardableResult
    func createProfile(name: String) -> MeetingProfile {
        let uniqueName = uniqueProfileName(from: name)
        let profile = MeetingProfile(name: uniqueName)
        profiles.append(profile)
        return profile
    }

    func deleteProfile(id: UUID) {
        guard let existing = profiles.first(where: { $0.id == id }) else { return }
        guard !existing.isProtectedDefault else { return }
        profiles.removeAll { $0.id == id }
        if activeProfileId == id, let fallback = profiles.first(where: { $0.preset == .default }) ?? profiles.first {
            activeProfileId = fallback.id
        }
    }

    func resetDefaultProfileToBuiltInDefaults() {
        guard let index = profiles.firstIndex(where: { $0.preset == .default }) else { return }
        profiles[index].overrides = .empty
        profiles[index].name = "Default"
        profiles[index].iconSystemName = MeetingProfile.defaultIcon(for: .default)
        profiles[index].iconBackgroundColorKey = MeetingProfile.defaultIconBackgroundColor(for: .default)

        transcriptionLanguage = ""
        whisperPrompt = ""
        summaryPrompt = Self.defaultSummaryPrompt
        actionItemsPrompt = Self.defaultActionItemsPrompt
        tagsPrompt = Self.defaultTagsPrompt
        autoTranscribe = true
        autoSummary = true
        autoActionItems = true
        autoTags = true
        recordingFolderURL = Self.defaultRecordingFolder()
        transcriptionFolderURL = Self.defaultTranscriptionFolder()
        obsidianVaultURL = nil
        obsidianDefaultFolderRelativePath = ""
    }

    func importProfiles(from data: Data) throws -> ImportResult {
        let envelope: ProfilesExportEnvelope
        do {
            envelope = try JSONDecoder().decode(ProfilesExportEnvelope.self, from: data)
        } catch {
            throw ProfileImportError.invalidFormat
        }

        guard envelope.version == 1 else {
            throw ProfileImportError.invalidVersion(envelope.version)
        }
        guard !envelope.profiles.isEmpty else {
            throw ProfileImportError.emptyImport
        }

        var renamedCount = 0
        var warnings: [String] = []
        var workingProfiles = profiles

        for sourceProfile in envelope.profiles {
            var profile = sourceProfile
            if profile.preset == .default {
                profile.preset = .custom
                warnings.append("Imported default profile was converted to custom.")
            }

            let newName = uniqueImportedProfileName(from: profile.name, existing: workingProfiles)
            if newName != profile.name {
                renamedCount += 1
                profile.name = newName
            }

            profile.id = UUID()
            workingProfiles.append(profile)
        }

        profiles = workingProfiles
        return ImportResult(
            importedCount: envelope.profiles.count,
            renamedCount: renamedCount,
            warnings: warnings
        )
    }

    func exportProfiles(ids: [UUID]? = nil) throws -> Data {
        let selectedProfiles: [MeetingProfile]
        if let ids {
            let allowed = Set(ids)
            selectedProfiles = profiles.filter { allowed.contains($0.id) }
        } else {
            selectedProfiles = profiles
        }

        let envelope = ProfilesExportEnvelope(
            version: 1,
            exportedAtISO8601: ISO8601DateFormatter().string(from: Date()),
            profiles: selectedProfiles
        )
        return try JSONEncoder().encode(envelope)
    }

    func warnings(for profile: MeetingProfile) -> [String] {
        var values: [String] = []
        if let endpointID = profile.overrides.transcriptionEndpointId,
           !transcriptionEndpoints.contains(where: { $0.id == endpointID })
        {
            values.append("Transcription endpoint override not found; default endpoint will be used.")
        }
        if let endpointID = profile.overrides.aiEndpointId,
           !aiEndpoints.contains(where: { $0.id == endpointID })
        {
            values.append("AI endpoint override not found; default endpoint will be used.")
        }
        if let path = profile.overrides.obsidianVaultPath,
           !path.isEmpty,
           !FileManager.default.fileExists(atPath: path)
        {
            values.append("Obsidian vault override path is unavailable; default vault will be used.")
        }
        return values
    }

    // MARK: - Profile Factories

    static func defaultProfile() -> MeetingProfile {
        MeetingProfile(name: "Default", preset: .default)
    }

    static func teamMeetingProfile() -> MeetingProfile {
        MeetingProfile(
            name: "Team meeting",
            preset: .teamMeeting,
            overrides: MeetingProfileOverrides(
                whisperPrompt: teamMeetingWhisperPrompt,
                summaryPrompt: teamMeetingSummaryPrompt,
                actionItemsPrompt: teamMeetingActionItemsPrompt,
                tagsPrompt: teamMeetingTagsPrompt,
                autoSummary: true,
                autoActionItems: true,
                autoTags: true
            )
        )
    }

    static func salesMeetingProfile() -> MeetingProfile {
        MeetingProfile(
            name: "Sales meeting",
            preset: .salesMeeting,
            overrides: MeetingProfileOverrides(
                whisperPrompt: salesMeetingWhisperPrompt,
                summaryPrompt: salesMeetingSummaryPrompt,
                actionItemsPrompt: salesMeetingActionItemsPrompt,
                tagsPrompt: salesMeetingTagsPrompt,
                autoSummary: true,
                autoActionItems: true,
                autoTags: true
            )
        )
    }

    static func builtInProfiles() -> [MeetingProfile] {
        [defaultProfile(), teamMeetingProfile(), salesMeetingProfile()]
    }

    // MARK: - Unique Name Helpers

    func uniqueProfileName(from baseName: String, existing: [MeetingProfile]? = nil) -> String {
        let values = existing ?? profiles
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "Profile" : trimmed
        let existingNames = Set(values.map { $0.name.lowercased() })
        if !existingNames.contains(candidate.lowercased()) {
            return candidate
        }

        var index = 1
        while true {
            let suffix = " \(index + 1)"
            let nextName = candidate + suffix
            if !existingNames.contains(nextName.lowercased()) {
                return nextName
            }
            index += 1
        }
    }

    func uniqueImportedProfileName(from baseName: String, existing: [MeetingProfile]) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "Profile" : trimmed
        let existingNames = Set(existing.map { $0.name.lowercased() })
        if !existingNames.contains(candidate.lowercased()) {
            return candidate
        }

        var index = 1
        while true {
            let suffix = index == 1 ? " (Imported)" : " (Imported \(index))"
            let nextName = candidate + suffix
            if !existingNames.contains(nextName.lowercased()) {
                return nextName
            }
            index += 1
        }
    }
}
