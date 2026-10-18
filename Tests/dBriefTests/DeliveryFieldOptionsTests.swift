import Testing
@testable import dBrief

/// Only the webhook uploads the audio file; the other destinations render text,
/// so their Send fields card must not offer an Audio toggle that does nothing.
struct DeliveryFieldOptionsTests {
    @Test func textDestinationsDoNotOfferAudio() {
        let options = DeliveryField.options(includingAudio: false)
        #expect(!options.contains(.audio))
        #expect(options == DeliveryField.allCases.filter { $0 != .audio })
    }

    @Test func webhookOffersEveryField() {
        #expect(DeliveryField.options(includingAudio: true) == DeliveryField.allCases)
    }
}
