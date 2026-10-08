import Foundation
import Testing
@testable import dBrief

struct SettingsProviderListTests {
    private func endpoint(_ name: String, _ url: String, model: String = "m") -> Endpoint {
        Endpoint(name: name, baseURL: url, modelName: model)
    }

    @Test func removingTheDefaultClearsItSoTheFirstRemainingIsUsed() {
        let a = endpoint("A", "https://a.example"), b = endpoint("B", "https://b.example")
        let result = SettingsProviderListLogic.remove(a.id, from: [a, b], defaultID: a.id)
        #expect(result.endpoints.map(\.id) == [b.id])
        #expect(result.defaultID == nil)
        #expect(SettingsProviderListLogic.isDefault(b, in: result.endpoints, defaultID: result.defaultID))
    }

    @Test func removingAnotherEndpointKeepsTheDefault() {
        let a = endpoint("A", "https://a.example"), b = endpoint("B", "https://b.example")
        let result = SettingsProviderListLogic.remove(a.id, from: [a, b], defaultID: b.id)
        #expect(result.defaultID == b.id)
    }

    @Test func aDanglingDefaultFallsBackToTheFirstEndpoint() {
        let a = endpoint("A", "https://a.example"), b = endpoint("B", "https://b.example")
        #expect(SettingsProviderListLogic.isDefault(a, in: [a, b], defaultID: UUID()))
        #expect(!SettingsProviderListLogic.isDefault(b, in: [a, b], defaultID: UUID()))
    }

    @Test func subtitleShowsHostAndModel() {
        #expect(SettingsProviderListLogic.subtitle(for: endpoint("A", "https://api.openai.com/v1", model: "gpt-5-mini"))
                == "api.openai.com · gpt-5-mini")
        #expect(SettingsProviderListLogic.subtitle(for: endpoint("A", "http://10.2.10.155:11434", model: ""))
                == "10.2.10.155:11434")
    }
}
