import Foundation

// MARK: - Persistence Helpers

extension AppSettings {

    // MARK: Bookmark Persistence

    func saveBookmark(for url: URL, key: String) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        if let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func saveBookmark(for url: URL?, key: String) {
        guard let url else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        saveBookmark(for: url, key: key)
    }

    static func loadBookmarkURL(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        if isStale { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    // MARK: Obsidian Folder Helpers

    func obsidianRelativePath(for folderURL: URL) -> String? {
        guard let vaultURL = effectiveObsidianVaultURL?.standardizedFileURL else { return nil }
        let vaultPath = vaultURL.path
        let folderPath = folderURL.standardizedFileURL.path

        if folderPath == vaultPath { return "" }
        guard folderPath.hasPrefix(vaultPath + "/") else { return nil }
        return String(folderPath.dropFirst(vaultPath.count + 1))
    }

    func obsidianFolderURL(relativePath: String?) -> URL? {
        guard let vaultURL = effectiveObsidianVaultURL else { return nil }
        let trimmed = (relativePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return vaultURL }
        let sanitized = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        return vaultURL.appendingPathComponent(sanitized, isDirectory: true)
    }

    func obsidianFolderDisplayName(relativePath: String?) -> String {
        let trimmed = (relativePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Vault root" : trimmed
    }

    // MARK: Default Folders

    static func defaultRecordingFolder() -> URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dBrief/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func defaultTranscriptionFolder() -> URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dBrief/Transcriptions", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func resolvedFolderURL(overridePath: String?, fallback: URL) -> URL {
        guard let overridePath else { return fallback }
        let trimmed = overridePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        let url = URL(fileURLWithPath: trimmed, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return fallback
        }
    }

    // MARK: Endpoint Persistence

    func saveEndpoints(_ endpoints: [Endpoint], forKey key: String) {
        if let data = try? JSONEncoder().encode(endpoints) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func loadEndpoints(forKey key: String) -> [Endpoint] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let endpoints = try? JSONDecoder().decode([Endpoint].self, from: data)
        else { return [] }
        return endpoints
    }

    // MARK: Integration Settings Persistence

    func saveIntegrationSettings(_ settings: IntegrationSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Keys.integrationSettings)
        }
    }

    static func loadIntegrationSettings(forKey key: String) -> IntegrationSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(IntegrationSettings.self, from: data)
        else { return IntegrationSettings() }
        return value
    }

    // MARK: Profiles Persistence

    func saveProfiles(_ values: [MeetingProfile]) {
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: Keys.profiles)
        }
    }

    static func loadProfiles(forKey key: String) -> [MeetingProfile] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let values = try? JSONDecoder().decode([MeetingProfile].self, from: data)
        else { return [] }
        return values
    }
}
