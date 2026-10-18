import Foundation
import Testing
import dBriefWire

@Suite struct LocalAIPluginStateCodingTests {
    @Test func analyzingPartRoundTrips() throws {
        let state = LocalAIPluginState.analyzingPart(index: 2, total: 5)
        let decoded = try JSONDecoder().decode(LocalAIPluginState.self, from: JSONEncoder().encode(state))
        guard case let .analyzingPart(index, total) = decoded else { Issue.record("wrong case"); return }
        #expect(index == 2 && total == 5)
    }
}
