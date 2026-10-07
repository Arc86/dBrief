import Testing
@testable import dBriefMLHost

@Suite struct EmbeddingTruncationTests {
    @Test func keepsFinalSpecialTokenWhenTruncating() {
        #expect(EmbeddingService.truncate([0, 10, 11, 12, 13, 2], to: 4) == [0, 10, 11, 2])
    }

    @Test func leavesShortEncodingsUntouched() {
        #expect(EmbeddingService.truncate([0, 10, 2], to: 4) == [0, 10, 2])
        #expect(EmbeddingService.truncate([0, 10, 11, 2], to: 4) == [0, 10, 11, 2])
    }
}
