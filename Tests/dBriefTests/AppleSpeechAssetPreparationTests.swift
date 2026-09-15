import Foundation
import Testing
@testable import dBrief

@Suite("Apple speech asset preparation")
struct AppleSpeechAssetPreparationTests {
    private actor Inventory {
        var states: [AppleSpeechAssetPreparation.State]
        var failures: Int
        var installs = 0
        init(_ states: [AppleSpeechAssetPreparation.State], failures: Int = 0) {
            self.states = states
            self.failures = failures
        }
        func state() -> AppleSpeechAssetPreparation.State {
            if states.count > 1 { return states.removeFirst() }
            return states[0]
        }
        func install() throws {
            installs += 1
            if failures > 0 {
                failures -= 1
                throw NSError(domain: "SFSpeechErrorDomain", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "asset unavailable"])
            }
        }
        func run() async throws {
            try await AppleSpeechAssetPreparation.ensureInstalled(
                locale: "nl-NL", state: { await self.state() }, install: { try await self.install() },
                pause: {}, report: { _ in })
        }
    }

    @Test func unavailableDutchDoesNotAttemptDownload() async throws {
        let inventory = Inventory([.unsupported])
        do {
            try await inventory.run()
            Issue.record("An unavailable asset must not be accepted")
        } catch let error as AppleSpeechAssetPreparation.Failure {
            #expect(error.state == .unsupported)
            #expect(error.locale == "nl-NL")
            #expect(error.localizedDescription.contains("Dutch"))
        }
        #expect(await inventory.installs == 0)
    }

    @Test func installedDoesNotDownload() async throws {
        let inventory = Inventory([.installed])
        try await inventory.run()
        #expect(await inventory.installs == 0)
    }

    @Test func downloadsAndVerifiesInstallation() async throws {
        let inventory = Inventory([.supported, .installed])
        try await inventory.run()
        #expect(await inventory.installs == 1)
    }

    @Test func retriesTemporaryFailureOnce() async throws {
        let inventory = Inventory([.supported, .downloading, .installed], failures: 1)
        try await inventory.run()
        #expect(await inventory.installs == 2)
    }

    @Test func installedDespiteDownloadErrorIsAccepted() async throws {
        let inventory = Inventory([.supported, .installed], failures: 1)
        try await inventory.run()
        #expect(await inventory.installs == 1)
    }

    @Test func unavailableAfterAttemptDoesNotRetryAndRetainsDiagnostic() async throws {
        let inventory = Inventory([.supported, .unsupported], failures: 1)
        do {
            try await inventory.run()
            Issue.record("An unavailable asset must not be accepted")
        } catch let error as AppleSpeechAssetPreparation.Failure {
            #expect(error.state == .unsupported)
            #expect(error.diagnostic.contains("SFSpeechErrorDomain"))
            #expect(error.diagnostic.contains("nl-NL"))
        }
        #expect(await inventory.installs == 1)
    }

    @Test func successfulRequestWithoutInstalledAssetIsNotSuccess() async throws {
        let inventory = Inventory([.supported])
        await #expect(throws: AppleSpeechAssetPreparation.Failure.self) { try await inventory.run() }
        #expect(await inventory.installs == 2)
    }

    @Test func cancellationIsNotRetriedOrWrapped() async throws {
        await #expect(throws: CancellationError.self) {
            try await AppleSpeechAssetPreparation.ensureInstalled(
                locale: "nl-NL", state: { .supported }, install: { throw CancellationError() },
                pause: { Issue.record("Cancellation must not retry") }, report: { _ in })
        }
    }
}
