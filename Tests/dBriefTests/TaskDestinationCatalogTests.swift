import Foundation
import Testing
@testable import dBrief

@MainActor
@Suite("Task destination catalog")
struct TaskDestinationCatalogTests {
    private final class Calls { var count = 0 }

    @Test func loadsOncePerCredentialAndReloadsOnRetryOrNewCredential() async {
        let catalog = TaskDestinationCatalog()
        let calls = Calls()
        let fetch: () async throws -> [TaskDestinationCatalog.Option] = {
            calls.count += 1
            return [.init(id: "w", name: "Work \(calls.count)")]
        }
        await catalog.load(.todoist, key: "token-a", fetch: fetch)
        await catalog.load(.todoist, key: "token-a", fetch: fetch)
        #expect(calls.count == 1)
        #expect(catalog.options(for: .todoist) == [.init(id: "w", name: "Work 1")])
        #expect(catalog.options(for: .tickTick).isEmpty)

        await catalog.load(.todoist, key: "token-a", force: true, fetch: fetch)
        #expect(calls.count == 2)
        await catalog.load(.todoist, key: "token-b", fetch: fetch)
        #expect(calls.count == 3)
        #expect(catalog.options(for: .todoist).first?.name == "Work 3")
    }

    @Test func failureIsReportedAndRetried() async {
        let catalog = TaskDestinationCatalog()
        await catalog.load(.tickTick, key: "k", fetch: { throw TickTickError.http(503) })
        #expect(catalog.error(for: .tickTick) == TickTickError.http(503).localizedDescription)
        #expect(catalog.options(for: .tickTick).isEmpty)
        await catalog.load(.tickTick, key: "k", fetch: { [.init(id: "a", name: "A")] })
        #expect(catalog.error(for: .tickTick) == nil)
        #expect(catalog.options(for: .tickTick).map(\.id) == ["a"])
    }

    @Test func clearingForgetsTheService() async {
        let catalog = TaskDestinationCatalog()
        await catalog.load(.todoist, key: "k", fetch: { [.init(id: "a", name: "A")] })
        catalog.clear(.todoist, message: "Paste a token")
        #expect(catalog.options(for: .todoist).isEmpty)
        #expect(catalog.error(for: .todoist) == "Paste a token")
    }

    @Test func notionTagsRoundTripTheKind() throws {
        let tag = TaskDestinationPicker.notionTag(.dataSource, "abc-123")
        let decoded = try #require(TaskDestinationPicker.notionDestination(fromTag: tag))
        #expect(decoded.type == .dataSource && decoded.id == "abc-123")
        #expect(TaskDestinationPicker.notionDestination(fromTag: "page:") == nil)
        #expect(TaskDestinationPicker.notionDestination(fromTag: "nonsense") == nil)
    }
}
