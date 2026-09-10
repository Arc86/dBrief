import Testing
@testable import dBrief

struct SettingsErrorSanitizerTests {
    @Test func providerFailureKeepsUsefulStatusAndOmitsSecrets() {
        let result = SettingsErrorSanitizer.details(for: "Server error (401): Authorization: Bearer secret-key; https://user:password@example.test?token=private")
        #expect(result.contains("HTTP 401"))
        #expect(result.contains("API key"))
        for secret in ["secret-key", "password", "example.test", "token=private"] {
            #expect(!result.contains(secret))
        }
    }

    @Test func cliFailureOmitsAllCommandOutput() {
        let result = SettingsErrorSanitizer.details(for: "Local CLI command exited with code 127: --password secret-word\nMY_KEY=unknown-format\n{\"token\":\"abc123\"}")
        #expect(result.contains("code 127"))
        for secret in ["secret-word", "unknown-format", "abc123", "MY_KEY"] {
            #expect(!result.contains(secret))
        }
    }

    @Test func unstructuredAndEncodedSecretsAreWithheld() {
        for raw in ["a-secret-with-no-label", "key%3Dsecret", "eyJhbGciOiJIUzI1NiJ9.secret.signature", "", "Server error (999999): private-data"] {
            let result = SettingsErrorSanitizer.details(for: raw)
            #expect(result.contains("No additional diagnostic information"))
            if !raw.isEmpty { #expect(!result.contains(raw)) }
        }
    }

    @Test func knownFailuresRemainActionableWithoutEchoingText() {
        let invalidJSON = SettingsErrorSanitizer.details(for: "Local CLI output was not valid JSON. Output started with: private-transcript")
        #expect(invalidJSON.contains("invalid JSON"))
        #expect(!invalidJSON.contains("private-transcript"))
        let timeout = SettingsErrorSanitizer.details(for: "Request timed out at https://secret-token.example.test")
        #expect(timeout.contains("timeout"))
        #expect(!timeout.contains("secret-token"))
    }
}
