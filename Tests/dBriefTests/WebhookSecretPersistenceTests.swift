import Foundation
import Testing
@testable import dBrief

@Suite("Webhook secret persistence")
struct WebhookSecretPersistenceTests {
    @Test func ordinaryEncodingExcludesCompleteURLAndEveryHeaderValue() throws {
        var settings = IntegrationSettings()
        settings.webhook.url = "https://example.test/path-secret?token=query-secret"
        settings.webhook.headers = [
            WebhookHeader(key: "Authorization", value: "Bearer bearer-secret"),
            WebhookHeader(key: "X-Custom", value: "custom-secret"),
        ]
        let data = try JSONEncoder().encode(settings)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("path-secret"))
        #expect(!text.contains("query-secret"))
        #expect(!text.contains("bearer-secret"))
        #expect(!text.contains("custom-secret"))
        let header = String(decoding: try JSONEncoder().encode(settings.webhook.headers[0]), as: UTF8.self)
        #expect(!header.contains("bearer-secret"))
        let restored = try JSONDecoder().decode(IntegrationSettings.self, from: data)
        #expect(restored.webhook.url.isEmpty)
        #expect(restored.webhook.headers.map(\.key) == ["Authorization", "X-Custom"])
    }

    @Test func legacyDecodePreservesSecretsForMigration() throws {
        let data = Data("""
        {"enabled":true,"url":"https://example.test/legacy-token","headers":[{"id":"11111111-2222-3333-4444-555555555555","key":"X-API-Key","value":"legacy-header"}],"timeoutSeconds":30,"retryCount":1,"fields":["summary"]}
        """.utf8)
        let value = try JSONDecoder().decode(WebhookConfig.self, from: data)
        #expect(value.url == "https://example.test/legacy-token")
        #expect(value.headers[0].value == "legacy-header")
    }
}

extension WebhookSecretPersistenceTests {
    private final class MemorySecrets {
        var values: [UUID: String] = [:]
        var failRead = false
        var failWrite = false
        var failReadAfterWrite = false
        var dropWrites = false
        var store: WebhookSecretStore {
            WebhookSecretStore(read: { id in
                if self.failRead { throw KeychainError.verificationFailed }
                return self.values[id] ?? ""
            }, write: { value, id in
                if self.failWrite { throw KeychainError.verificationFailed }
                if !self.dropWrites { self.values[id] = value }
                if self.failReadAfterWrite { self.failRead = true }
            })
        }
    }

    private func legacySettingsData() throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(IntegrationSettings())) as? [String: Any])
        object["webhook"] = ["enabled": true, "url": "https://example.test/path-token?token=query-token",
            "headers": [["id": "11111111-2222-3333-4444-555555555555", "key": "X-Route", "value": "header-token"]],
            "timeoutSeconds": 30, "retryCount": 1, "fields": ["summary"]] as [String: Any]
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func migrationAndRelaunchRestoreRuntimeSecretsAndRouting() throws {
        let memory = MemorySecrets()
        let persistence = WebhookSettingsPersistence(secrets: memory.store)
        let loaded = persistence.load(data: try legacySettingsData())
        #expect(loaded.errorMessage == nil)
        let sanitized = try #require(loaded.sanitizedData)
        #expect(!String(decoding: sanitized, as: UTF8.self).contains("path-token"))
        let relaunched = persistence.load(data: sanitized)
        #expect(relaunched.errorMessage == nil)
        #expect(relaunched.settings.webhook.url == "https://example.test/path-token?token=query-token")
        #expect(relaunched.settings.webhook.headers[0].value == "header-token")
        #expect(relaunched.settings.webhook.credentialID == loaded.settings.webhook.credentialID)
        #expect(try IntegrationDeliveryBatch.configurationDigests(relaunched.settings) == IntegrationDeliveryBatch.configurationDigests(loaded.settings))
        var changed = relaunched.settings
        changed.webhook.headers[0].value = "different-route"
        #expect(try IntegrationDeliveryBatch.configurationDigests(changed) != IntegrationDeliveryBatch.configurationDigests(relaunched.settings))
    }

    @Test func failedAndUnverifiedMigrationNeverScrubLegacyData() throws {
        for dropWrites in [false, true] {
            let memory = MemorySecrets()
            memory.failWrite = !dropWrites
            memory.dropWrites = dropWrites
            let persistence = WebhookSettingsPersistence(secrets: memory.store)
            let loaded = persistence.load(data: try legacySettingsData())
            #expect(loaded.sanitizedData == nil)
            #expect(loaded.errorMessage != nil)
            #expect(loaded.settings.webhook.url == "https://example.test/path-token?token=query-token")
            #expect(loaded.settings.webhook.headers[0].value == "header-token")
        }
    }

    @Test func unreadableSecretsBlockSavingEmptyValuesAndCanBeRetried() throws {
        let memory = MemorySecrets()
        let persistence = WebhookSettingsPersistence(secrets: memory.store)
        let migrated = persistence.load(data: try legacySettingsData())
        let sanitized = try #require(migrated.sanitizedData)
        memory.failRead = true
        var loaded = persistence.load(data: sanitized)
        #expect(loaded.settings.webhook.credentialsUnavailable)
        #expect(loaded.errorMessage != nil)
        loaded.settings.webhook.timeoutSeconds = 60
        #expect(throws: (any Error).self) { try persistence.encodeForSaving(loaded.settings) }
        memory.failRead = false
        let retried = persistence.load(data: sanitized)
        #expect(retried.settings.webhook.url == "https://example.test/path-token?token=query-token")
        #expect(retried.settings.webhook.headers[0].value == "header-token")
    }

    @Test func missingSecretRecordAlsoBlocksOverwrite() throws {
        let memory = MemorySecrets()
        let persistence = WebhookSettingsPersistence(secrets: memory.store)
        let migrated = persistence.load(data: try legacySettingsData())
        let sanitized = try #require(migrated.sanitizedData)
        memory.values.removeAll()
        let loaded = persistence.load(data: sanitized)
        #expect(loaded.settings.webhook.credentialsUnavailable)
        #expect(throws: (any Error).self) { try persistence.encodeForSaving(loaded.settings) }
    }

    @Test func saveFailureIsReportedAndSuccessfulRetryKeepsSecretsOutOfMetadata() throws {
        let memory = MemorySecrets()
        let persistence = WebhookSettingsPersistence(secrets: memory.store)
        let loaded = persistence.load(data: try legacySettingsData())
        var edited = loaded.settings
        edited.webhook.headers[0].value = "replacement-token"
        memory.failWrite = true
        #expect(throws: (any Error).self) { try persistence.encodeForSaving(edited) }
        memory.failWrite = false
        let data = try persistence.encodeForSaving(edited).metadata
        #expect(!String(decoding: data, as: UTF8.self).contains("replacement-token"))
        #expect(persistence.load(data: data).settings.webhook.headers[0].value == "replacement-token")
    }

    @Test func incompleteBundleNeverHydratesDestinationWithoutItsHeaders() throws {
        let memory = MemorySecrets()
        let persistence = WebhookSettingsPersistence(secrets: memory.store)
        let migrated = persistence.load(data: try legacySettingsData())
        let sanitized = try #require(migrated.sanitizedData)
        memory.values[migrated.settings.webhook.credentialID] = "{\"url\":\"https://example.test/private\",\"headerValues\":{}}"
        let loaded = persistence.load(data: sanitized)
        #expect(loaded.settings.webhook.credentialsUnavailable)
        #expect(loaded.settings.webhook.url.isEmpty)
        #expect(throws: (any Error).self) { try persistence.encodeForSaving(loaded.settings) }
    }

    @Test func deliberateCredentialClearingPersistsAfterSuccessfulHydration() throws {
        let memory = MemorySecrets()
        let persistence = WebhookSettingsPersistence(secrets: memory.store)
        var loaded = persistence.load(data: try legacySettingsData()).settings
        loaded.webhook.url = ""
        loaded.webhook.headers[0].value = ""
        let metadata = try persistence.encodeForSaving(loaded).metadata
        let relaunched = persistence.load(data: metadata)
        #expect(relaunched.errorMessage == nil)
        #expect(relaunched.settings.webhook.url.isEmpty)
        #expect(relaunched.settings.webhook.headers[0].value.isEmpty)
    }

    @Test func failedReadbackOfEditedHeadersLeavesPreviousSavedRevisionIntact() throws {
        let memory = MemorySecrets()
        let persistence = WebhookSettingsPersistence(secrets: memory.store)
        let original = persistence.load(data: try legacySettingsData())
        let originalMetadata = try #require(original.sanitizedData)
        var edited = original.settings
        edited.webhook.url = "https://replacement.test/new-token"
        edited.webhook.headers = [WebhookHeader(key: "Authorization", value: "replacement-token")]
        memory.failReadAfterWrite = true
        #expect(throws: (any Error).self) { try persistence.encodeForSaving(edited) }
        memory.failRead = false
        let restored = persistence.load(data: originalMetadata)
        #expect(restored.errorMessage == nil)
        #expect(restored.settings.webhook.url == "https://example.test/path-token?token=query-token")
        #expect(restored.settings.webhook.headers[0].key == "X-Route")
        #expect(restored.settings.webhook.headers[0].value == "header-token")
    }

    @Test func uncommittedVerifiedSaveLeavesPreviousMetadataUsable() throws {
        let memory = MemorySecrets()
        let persistence = WebhookSettingsPersistence(secrets: memory.store)
        let original = persistence.load(data: try legacySettingsData())
        let originalMetadata = try #require(original.sanitizedData)
        var edited = original.settings
        edited.webhook.headers.removeAll()
        let saved = try persistence.encodeForSaving(edited)
        let newMetadata = saved.metadata
        let old = persistence.load(data: originalMetadata)
        #expect(old.errorMessage == nil)
        #expect(old.settings.webhook.headers[0].value == "header-token")
        let new = persistence.load(data: newMetadata)
        #expect(new.errorMessage == nil)
        #expect(new.settings.webhook.headers.isEmpty)
        #expect(new.settings.webhook.credentialID != old.settings.webhook.credentialID)
        #expect(saved.settings.webhook.credentialID == new.settings.webhook.credentialID)
    }

    @Test func unrelatedSettingsEditsReuseVerifiedCredentialRevision() throws {
        let memory = MemorySecrets()
        let persistence = WebhookSettingsPersistence(secrets: memory.store)
        let original = persistence.load(data: try legacySettingsData())
        var edited = original.settings
        edited.webhook.timeoutSeconds = 50
        edited.appleNotes.enabled = true
        // Reuse must not attempt any write when the verified bundle is identical.
        memory.failWrite = true
        let saved = try persistence.encodeForSaving(edited)
        #expect(saved.settings.webhook.credentialID == original.settings.webhook.credentialID)
        let relaunched = persistence.load(data: saved.metadata)
        #expect(relaunched.errorMessage == nil)
        #expect(relaunched.settings.appleNotes.enabled)
        #expect(relaunched.settings.webhook.timeoutSeconds == 50)
        #expect(relaunched.settings.webhook.headers[0].value == "header-token")
    }

}
