import Foundation
import Testing

@Suite("Permission prompt strings")
struct InfoPlistStringsTests {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/dBrief/Resources")

    @Test("Every usage description in Info.plist is in InfoPlist.xcstrings with the same English text")
    func catalogMatchesInfoPlist() throws {
        let plistData = try Data(contentsOf: Self.resources.appendingPathComponent("Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        let catalogData = try Data(contentsOf: Self.resources.appendingPathComponent("InfoPlist.xcstrings"))
        let catalog = try #require(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])

        let usageKeys = plist.keys.filter { $0.hasSuffix("UsageDescription") }.sorted()
        #expect(!usageKeys.isEmpty)
        #expect(Set(strings.keys) == Set(usageKeys))
        for key in usageKeys {
            let localizations = strings[key]?["localizations"] as? [String: [String: Any]]
            let english = (localizations?["en"]?["stringUnit"] as? [String: Any])?["value"] as? String
            #expect(english == plist[key] as? String, "\(key) differs from Info.plist")
        }
    }
}
