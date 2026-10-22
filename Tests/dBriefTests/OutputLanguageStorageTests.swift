import Foundation
import Testing
@testable import dBrief
import dBriefWire

struct OutputLanguageStorageTests {
    @Test(arguments: [OutputLanguage.matchInput, .english, .dutch, .german, .french, .spanish])
    func storageValueIsStableAndDistinct(language: OutputLanguage) {
        let all: [OutputLanguage] = [.matchInput, .english, .dutch, .german, .french, .spanish, .custom("PT")]
        #expect(all.filter { $0.modeStorageValue == language.modeStorageValue } == [language])
    }

    @Test
    func newLanguagesRoundTripThroughCodable() throws {
        for language in [OutputLanguage.german, .french, .spanish, .custom("PT")] {
            let data = try JSONEncoder().encode(language)
            #expect(try JSONDecoder().decode(OutputLanguage.self, from: data) == language)
        }
    }
}
