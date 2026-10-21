import Foundation
import Testing
@testable import dBrief

@MainActor
struct ViewerAssistantSubtitleTests {
    @Test
    func onDeviceEnginesSayOnDevice() {
        #expect(ViewerAssistantSubtitle.text(for: .qwenLocal, remoteName: "Ignored") == "This recording · Gemma, on-device")
        #expect(ViewerAssistantSubtitle.text(for: .appleIntelligence, remoteName: nil)
            == "This recording · Apple Intelligence, on-device")
    }

    @Test
    func remoteEndpointShowsItsName() {
        #expect(ViewerAssistantSubtitle.text(for: .remoteEndpoint, remoteName: " Groq ") == "This recording · Groq")
    }

    @Test
    func unnamedOrMissingRemoteFallsBackToPlainSubtitle() {
        #expect(ViewerAssistantSubtitle.text(for: .remoteEndpoint, remoteName: nil) == "This recording")
        #expect(ViewerAssistantSubtitle.text(for: .remoteEndpoint, remoteName: "  ") == "This recording")
    }
}
