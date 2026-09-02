import Foundation
import Testing
@testable import dBrief

@Suite("Endpoint secret migration contract")
struct EndpointSecretMigrationContractTests {
    @Test
    func legacyPlaintextSecretRemainsDecodableForOneTimeMigration() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let data = Data("""
        [{
          "id": "\(id.uuidString)",
          "name": "Legacy endpoint",
          "baseURL": "https://example.test",
          "modelName": "model",
          "apiKey": "legacy-secret"
        }]
        """.utf8)

        let endpoints = try JSONDecoder().decode([Endpoint].self, from: data)

        #expect(endpoints.count == 1)
        #expect(endpoints[0].id == id)
        #expect(endpoints[0].apiKey == "legacy-secret")
        #expect(endpoints[0].provider == .openAICompatible)
    }

    @Test
    func endpointWithoutPersistedSecretDecodesAsEmpty() throws {
        let data = Data("""
        [{
          "id": "11111111-2222-3333-4444-555555555555",
          "name": "Keychain-backed endpoint",
          "baseURL": "https://example.test",
          "modelName": "model",
          "provider": "anthropic"
        }]
        """.utf8)

        let endpoint = try #require(JSONDecoder().decode([Endpoint].self, from: data).first)
        #expect(endpoint.apiKey.isEmpty)
        #expect(endpoint.provider == .anthropic)
    }

    @Test
    func encodedEndpointMetadataNeverContainsAPIKey() throws {
        let endpoint = Endpoint(
            name: "Remote",
            baseURL: "https://example.test",
            modelName: "model",
            apiKey: "must-stay-in-keychain",
            provider: .anthropic
        )

        let data = try JSONEncoder().encode(endpoint)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["apiKey"] == nil)
        #expect(object["id"] as? String == endpoint.id.uuidString)
        #expect(object["provider"] as? String == Endpoint.Provider.anthropic.rawValue)
    }

    @Test
    func migrationScrubsOnlySecretsVerifiedInKeychain() {
        let stored = Endpoint(
            id: UUID(),
            name: "Stored",
            baseURL: "https://stored.example.test",
            modelName: "model",
            apiKey: "stored-secret"
        )
        let failed = Endpoint(
            id: UUID(),
            name: "Failed",
            baseURL: "https://failed.example.test",
            modelName: "model",
            apiKey: "must-not-be-lost"
        )
        let noSecret = Endpoint(
            id: UUID(),
            name: "No secret",
            baseURL: "https://local.example.test",
            modelName: "model"
        )
        let plan = EndpointSecretMigrationPlan(legacyEndpoints: [stored, failed, noSecret])

        #expect(plan.candidates == [
            EndpointSecretMigrationCandidate(endpointID: stored.id, secret: "stored-secret"),
            EndpointSecretMigrationCandidate(endpointID: failed.id, secret: "must-not-be-lost"),
        ])

        let persisted = plan.endpointsAfterPersisting(successfulEndpointIDs: [stored.id])
        #expect(persisted[0].apiKey.isEmpty)
        #expect(persisted[1].apiKey == "must-not-be-lost")
        #expect(persisted[2].apiKey.isEmpty)
    }
}
