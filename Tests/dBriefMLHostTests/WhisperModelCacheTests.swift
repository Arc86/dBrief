import Foundation
import Testing
@testable import dBriefMLHost
import dBriefWire

@Suite("WhisperKit model cache path")
struct WhisperModelCacheTests {

    @Test("cached model folder matches WhisperKit's HF snapshot layout (models/<repo>/<variant>)")
    func cachedModelFolderPath() {
        let base = URL(fileURLWithPath: "/tmp/wk", isDirectory: true)
        let url = WhisperKitTranscriptionService.cachedModelFolder(
            name: "openai_whisper-large-v3_turbo",
            downloadBase: base,
            repo: "argmaxinc/whisperkit-coreml")
        #expect(url.path == "/tmp/wk/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo")
    }
}
