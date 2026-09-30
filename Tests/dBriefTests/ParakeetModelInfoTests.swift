import Testing
import dBriefWire

struct ParakeetModelInfoTests {
    @Test func catalogListsEveryVariantWithV3AsDefault() {
        #expect(ParakeetModelInfo.variants.map(\.id) == ["v2", "v3", "ultra", "redux"])
        #expect(ParakeetModelInfo.defaultID == "v3")
        #expect(ParakeetModelInfo.variants.filter(\.isEnglishOnly).map(\.id) == ["v2"])
    }

    @Test func reduxNeedsMacOS15AndIsHiddenBelowIt() {
        #expect(ParakeetModelInfo.variants.first { $0.id == "redux" }?.minimumMacOSMajor == 15)
        #expect(ParakeetModelInfo.variants.filter { $0.minimumMacOSMajor > 14 }.map(\.id) == ["redux"])
        #expect(ParakeetModelInfo.available(macOSMajor: 14).map(\.id) == ["v2", "v3", "ultra"])
        #expect(ParakeetModelInfo.available(macOSMajor: 15).map(\.id) == ["v2", "v3", "ultra", "redux"])
    }

    @Test func unknownOrUnsupportedVariantsResolveToTheDefault() {
        #expect(ParakeetModelInfo.find("ultra", macOSMajor: 14).id == "ultra")
        #expect(ParakeetModelInfo.find("redux", macOSMajor: 15).id == "redux")
        #expect(ParakeetModelInfo.find("redux", macOSMajor: 14).id == "v3")
        #expect(ParakeetModelInfo.find("obsolete-variant", macOSMajor: 26).id == "v3")
        #expect(ParakeetModelInfo.find("", macOSMajor: 26).id == "v3")
    }
}
