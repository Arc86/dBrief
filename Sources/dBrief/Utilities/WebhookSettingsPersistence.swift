import Foundation

/// Injected boundary keeps migration tests away from the user's Keychain.
struct WebhookSecretStore {
    var read: (UUID) throws -> String
    var write: (String, UUID) throws -> Void

    static var keychain: Self {
        Self(read: { try KeychainHelper.webhookCredentials(credentialID: $0) },
             write: { try KeychainHelper.setWebhookCredentials($0, credentialID: $1) })
    }
}

struct WebhookSettingsPersistence {
    let secrets: WebhookSecretStore

    struct LoadResult {
        var settings: IntegrationSettings
        var sanitizedData: Data?
        var errorMessage: String?
    }

    struct SaveResult {
        var settings: IntegrationSettings
        var metadata: Data
    }

    // Deliberately separate from the ordinary configuration's Codable schema.
    private struct Credentials: Codable, Equatable {
        var url: String
        var headerValues: [String: String]
    }

    func encodeForSaving(_ settings: IntegrationSettings) throws -> SaveResult {
        // An empty field caused by a locked/missing Keychain item is not a user
        // request to erase it. Require a successful reload before accepting edits.
        guard !settings.webhook.credentialsUnavailable else {
            throw KeychainError.invalidStoredValue
        }
        var values: [String: String] = [:]
        for header in settings.webhook.headers {
            guard values.updateValue(header.value, forKey: header.id.uuidString) == nil else {
                throw KeychainError.invalidStoredValue
            }
        }
        let bundle = Credentials(url: settings.webhook.url, headerValues: values)
        let encoded = String(decoding: try JSONEncoder().encode(bundle), as: UTF8.self)
        let existing = try secrets.read(settings.webhook.credentialID)
        let existingBundle = try? JSONDecoder().decode(Credentials.self, from: Data(existing.utf8))
        var savedSettings = settings
        savedSettings.webhook.needsSecretMigration = false
        if existingBundle == bundle {
            // Unrelated settings edits can reuse this verified immutable bundle.
            return SaveResult(settings: savedSettings, metadata: try JSONEncoder().encode(savedSettings))
        }
        // Changed credentials receive a fresh revision. An interrupted preference
        // commit or failed readback cannot invalidate the previously saved bundle.
        savedSettings.webhook.credentialID = UUID()
        let metadata = try JSONEncoder().encode(savedSettings)
        try secrets.write(encoded, savedSettings.webhook.credentialID)
        guard try secrets.read(savedSettings.webhook.credentialID) == encoded else {
            throw KeychainError.verificationFailed
        }
        return SaveResult(settings: savedSettings, metadata: metadata)
    }

    func load(data: Data?) -> LoadResult {
        guard let data else { return LoadResult(settings: IntegrationSettings()) }
        var settings: IntegrationSettings
        do {
            settings = try JSONDecoder().decode(IntegrationSettings.self, from: data)
        } catch {
            var unavailable = IntegrationSettings()
            unavailable.webhook.credentialsUnavailable = true
            return LoadResult(settings: unavailable,
                              errorMessage: "Integration settings could not be read. Saved settings have been retained.")
        }

        if settings.webhook.needsSecretMigration {
            do {
                let sanitized = try encodeForSaving(settings)
                return LoadResult(settings: sanitized.settings, sanitizedData: sanitized.metadata)
            } catch {
                // Do not replace the original preference blob until the entire
                // credential bundle has been written and independently verified.
                return LoadResult(settings: settings,
                                  errorMessage: "Webhook credentials could not be moved to Keychain. The original saved settings have been retained. Retry credential storage to finish migration.")
            }
        }

        do {
            let encoded = try secrets.read(settings.webhook.credentialID)
            let bundle = try JSONDecoder().decode(Credentials.self, from: Data(encoded.utf8))
            // Validate the whole bundle before hydrating any runtime fields.
            guard settings.webhook.headers.allSatisfy({ bundle.headerValues[$0.id.uuidString] != nil }) else {
                throw KeychainError.invalidStoredValue
            }
            settings.webhook.url = bundle.url
            for index in settings.webhook.headers.indices {
                settings.webhook.headers[index].value = bundle.headerValues[settings.webhook.headers[index].id.uuidString]!
            }
            return LoadResult(settings: settings)
        } catch {
            settings.webhook.credentialsUnavailable = true
            return LoadResult(settings: settings,
                              errorMessage: "Webhook credentials could not be read from Keychain. Settings cannot be saved until credential storage is retried successfully.")
        }
    }
}
