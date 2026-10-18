import Testing
@testable import dBriefMLHost
import dBriefWire

@Suite struct EmbeddingTruncationTests {
    @Test func keepsFinalSpecialTokenWhenTruncating() {
        #expect(EmbeddingService.truncate([0, 10, 11, 12, 13, 2], to: 4) == [0, 10, 11, 2])
    }

    @Test func leavesShortEncodingsUntouched() {
        #expect(EmbeddingService.truncate([0, 10, 2], to: 4) == [0, 10, 2])
        #expect(EmbeddingService.truncate([0, 10, 11, 2], to: 4) == [0, 10, 11, 2])
    }

    /// XLM-R positions start at padTokenID + 1 (= 2), so a 514-position e5-small
    /// fits 512 tokens; 514 tokens would index position 515 (out of bounds).
    @Test func xlmRobertaLimitLeavesRoomForPaddingAwarePositions() {
        #expect(EmbeddingService.tokenLimit(spec: .multilingualE5Small, maxPositionEmbeddings: 514) == 512)
    }

    @Test func tokenLimitIsCappedBySpecAndModel() {
        #expect(EmbeddingService.tokenLimit(spec: .embeddingGemma300m4bit, maxPositionEmbeddings: 2048) == 1024)
        #expect(EmbeddingService.tokenLimit(spec: .embeddingGemma300m4bit, maxPositionEmbeddings: 512) == 512)
        #expect(EmbeddingService.tokenLimit(spec: .multilingualE5Small, maxPositionEmbeddings: nil) == 512)
    }
}
