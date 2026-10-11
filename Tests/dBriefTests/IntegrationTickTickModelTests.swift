import Foundation
import Testing
@testable import dBrief

@Suite("TickTick destination model")
struct IntegrationTickTickModelTests {
    @Test func tickTickIsOfferedOnlyWithCredentials() {
        #expect(IntegrationDestination.available(tickTickConfigured: false)
            == [.obsidian, .appleNotes, .appleReminders, .webhook, .todoist, .notion])
        #expect(IntegrationDestination.available(tickTickConfigured: true)
            == [.obsidian, .appleNotes, .appleReminders, .webhook, .todoist, .notion, .tickTick])
        #expect(IntegrationDestination.tickTick.displayName == "TickTick")
    }

    @Test func settingsSavedBeforeTickTickStillDecode() throws {
        var saved = IntegrationSettings()
        saved.webhook.enabled = true
        saved.appleReminders.listName = "Work"
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        object["tickTick"] = nil
        object["todoist"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(IntegrationSettings.self, from: legacy)
        #expect(decoded.webhook.enabled)
        #expect(decoded.appleReminders.listName == "Work")
        #expect(decoded.tickTick == TickTickConfig())
        #expect(decoded.todoist == TodoistConfig())
    }

    @Test func tickTickSettingsRoundTrip() throws {
        var settings = IntegrationSettings()
        settings.tickTick = TickTickConfig(enabled: true, projectID: "p1", projectName: "Work")
        let decoded = try JSONDecoder().decode(IntegrationSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test func digestCoversTheChosenListOnlyWhenOffered() throws {
        var settings = IntegrationSettings()
        settings.tickTick.enabled = true
        let offered = IntegrationDestination.available(tickTickConfigured: true)
        #expect(try IntegrationDeliveryBatch.configurationDigests(settings,
            available: IntegrationDestination.available(tickTickConfigured: false))[.tickTick] == nil)
        let inbox = try #require(try IntegrationDeliveryBatch.configurationDigests(settings, available: offered)[.tickTick])
        settings.tickTick.projectName = "Renamed"
        #expect(try IntegrationDeliveryBatch.configurationDigests(settings, available: offered)[.tickTick] == inbox)
        settings.tickTick.projectID = "p2"
        #expect(try IntegrationDeliveryBatch.configurationDigests(settings, available: offered)[.tickTick] != inbox)
        settings.tickTick.enabled = false
        #expect(try IntegrationDeliveryBatch.configurationDigests(settings, available: offered)[.tickTick] == nil)
    }

    @Test func deliveryRecordsWithoutCreatedItemsStillDecode() throws {
        let delivery = IntegrationDeliveryBatch.Delivery(id: UUID(), destination: .webhook, configurationDigest: "d")
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(delivery)) as? [String: Any])
        object["createdItems"] = nil
        let decoded = try JSONDecoder().decode(IntegrationDeliveryBatch.Delivery.self,
                                               from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.createdItems == nil)
        var withItems = delivery
        withItems.createdItems = [0: "t1", 3: "t4"]
        let roundTrip = try JSONDecoder().decode(IntegrationDeliveryBatch.Delivery.self,
                                                 from: JSONEncoder().encode(withItems))
        #expect(roundTrip.createdItems == [0: "t1", 3: "t4"])
    }
}
