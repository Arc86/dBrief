import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite("Transcript chat actual frozen dispatch", .serialized)
@MainActor
struct TranscriptChatSnapshotTests {
    private func configureOwnedRoute(_ settings: AppSettings, local: Bool = false) {
        let profile = MeetingProfile(name: "Owned context dispatch fixture")
        settings.profiles = [profile]; settings.activeProfileId = profile.id; settings.automaticProfileId = nil
        settings.aiEngine = local ? .qwenLocal : .remoteEndpoint
        settings.aiEndpoints = [Endpoint(name: "Owned", baseURL: "https://freeze-chat.invalid", modelName: "fixture")]
        settings.defaultAIEndpointId = settings.aiEndpoints[0].id
    }
    private func ownedProvider(_ f: LiveArtifactFixture, registry: LiveRecordingSessionRegistry, final: Bool = false) throws -> TranscriptContextProvider {
        let entry = try registry.registerLegacy(f.identity)
        try entry.artifacts.appendLegacy([.init(start: 0, end: 1, text: "Owned exact committed evidence", speaker: "You")])
        if final {
            try registry.captureDidClose(f.identity)
            try entry.artifacts.publishFinal(.init(text: "Owned exact saved final"))
        }
        return .recording(recordingID: f.identity.recordingID, registry: registry,
            legacy: { .legacy(text: "Wrong fallback", recordingID: f.identity.recordingID, speakerLabels: []) })
    }
    private func prepared(_ provider: TranscriptContextProvider) async throws -> PreparedTranscriptChat {
        let snapshot = try await provider.freeze().snapshot()
        return try TranscriptContextBuilder.build(snapshot: snapshot,
            route: .init(engine: "fixture", endpointID: nil, provider: nil, origin: nil, model: nil),
            budget: .init(contextTokens: 8_192, outputTokens: 512, templateReserve: 256),
            language: .matchInput, question: "Evidence", history: [], answerID: UUID())
    }

    private func chatPrepared(_ provider: TranscriptContextProvider) async throws -> PreparedTranscriptChat {
        let frozen = try provider.freezeForChat(attachedOwner: nil)
        let snapshot = try await frozen.snapshot()
        return try TranscriptContextBuilder.build(snapshot: snapshot,
            route: .init(engine: "fixture", endpointID: nil, provider: nil, origin: nil, model: nil),
            budget: .init(contextTokens: 8_192, outputTokens: 512, templateReserve: 256),
            language: .matchInput, question: "Claimed evidence", history: [], answerID: UUID())
    }

    @Test(arguments: ["delegate", "receipt", "redirect"])
    func originalChatClaimSurvivesReturnedContextThroughActualHTTPCompletion(path: String) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        let provider = try ownedProvider(f, registry: registry)
        let entry = try #require(registry.entry(recordingID: f.identity.recordingID))
        try registry.captureDidClose(f.identity)
        var value: PreparedTranscriptChat? = try await chatPrepared(provider)
        let context = PrivacyTrace.Context(receiptURL: f.root.appendingPathComponent("claimed-http.json"),
            store: PrivacyReceiptStore(gapDirectoryURL: f.root.appendingPathComponent("gaps"), pendingDirectoryURL: f.root.appendingPathComponent("pending")))
        let url = URL(string: "https://freeze-chat.invalid/claimed")!
        let trace = path == "delegate" ? nil : PrivacyHTTPTrace(operation: .init(stage: .chat, data: [.text, .metadata],
            destination: .remote(url: url, provider: .custom)), context: context, ownership: value?.contextOwnership)
        let delegate = PrivacyHTTPTaskDelegate(trace: trace, ownership: path == "receipt" ? nil : value?.contextOwnership)
        value = nil
        func requireBusy() {
            do { let request = try entry.artifacts.beginChatRequest(); request.release(); Issue.record("Actual owned HTTP work must keep the original request occupied") }
            catch { #expect(error as? LiveArtifactError == .queueFull) }
        }
        requireBusy()
        await trace?.start()
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url); defer { task.cancel() }
        let response = try #require(HTTPURLResponse(url: url, statusCode: path == "redirect" ? 307 : 200, httpVersion: nil, headerFields: nil))
        if path == "delegate" {
            #expect(!entry.artifacts.canExpire)
            delegate.urlSession(session, task: task, didCompleteWithError: nil)
        } else {
            let hold = ContextReceiptHold()
            let holder = Task.detached { await context.store.holdForContextOwnershipTest(hold) }
            var finish: Task<Void, Never>?
            do {
                try await hold.waitForArrival()
                if path == "receipt" {
                    finish = Task { await trace?.finish(response: response) }
                } else {
                    let result = ContextRedirectProbe()
                    var request = URLRequest(url: URL(string: "https://freeze-chat.invalid/claimed-redirect")!)
                    request.httpMethod = "POST"; request.httpBody = Data("Exact claimed prompt".utf8)
                    delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request,
                        completionHandler: { result.complete($0) })
                    // The admitted redirect callback must retain the claim after the delegate slot clears.
                    delegate.urlSession(session, task: task, didCompleteWithError: nil)
                    finish = Task { try? await result.waitForReturn(); await trace?.finish(error: CancellationError()) }
                }
                for _ in 0..<100 { await Task.yield() }
                requireBusy(); #expect(!entry.artifacts.canExpire)
                hold.release(); await holder.value; await finish?.value
                #expect(!hold.timedOut)
            } catch { hold.release(); await holder.value; await finish?.value; throw error }
        }
        try await f.eventually { @MainActor in
            do { let request = try entry.artifacts.beginChatRequest(); request.release(); return true }
            catch { return false }
        }
        #expect(entry.artifacts.canExpire)
        // Holding the completed trace/delegate alive cannot retain a spent claim.
        withExtendedLifetime(trace) {}; withExtendedLifetime(delegate) {}
        try registry.retire(f.identity)
    }

    @Test func retiredOldFailureCannotAlterActualReloadedHistoricalAnswer() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        let provider = try ownedProvider(f, registry: registry)
        let settings = AppSettings(), saved = ChatSettingsRestore(settings); defer { saved.restore(settings) }
        configureOwnedRoute(settings)
        settings.aiEndpoints = [Endpoint(name: "Historical callback", baseURL: "https://error-completion-chat.invalid", modelName: "fixture")]
        settings.defaultAIEndpointId = settings.aiEndpoints[0].id
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FrozenChatProtocol.self]
        let transportCompletion = ContextSessionCompletion()
        let session = URLSession(configuration: config, delegate: transportCompletion, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let gate = ChatSnapshotGate()
        let service = TranscriptChatService(contextProvider: provider, appSettings: settings, localPlugin: nil,
            aiService: AIService(session: session), beforeStreamFailureHandling: { await gate.hold() })
        let send = Task { await service.send("Historical question") }
        do {
            try await gate.waitForArrival()
            var messages = service.messages
            let index = try #require(messages.indices.last)
            let oldAnswer = try #require(messages.last)
            #expect(oldAnswer.content == "Partial proof" && oldAnswer.outcome == .streaming)
            try #require(oldAnswer.basis != nil)
            messages[index].content = "Historical confirmed answer"
            messages[index].outcome = .completed
            let historical = ChatHistory(messages: messages, engine: oldAnswer.basis?.route.engine)
            service.stopGenerating()
            #expect(service.clearMessages())
            #expect(service.messages.isEmpty && service.streamingNotice == nil)
            let store = ChatStore(), url = f.root.appendingPathComponent("reloaded-history.chat.json")
            try await store.save(historical, to: url)
            let savedBytes = try Data(contentsOf: url)
            service.enablePersistence(store: store, url: url)
            await service.loadPersisted()
            #expect(service.messages == historical.messages)
            #expect(service.messages.last?.id == oldAnswer.id && service.messages.last?.basis == oldAnswer.basis)
            try registry.retire(f.identity)
            #expect(service.isInvalidatedForReprocessing)
            await gate.release()
            #expect(await send.value == .accepted)
            #expect(service.messages == historical.messages)
            #expect(service.messages.last?.outcome == .completed && service.streamingNotice == nil)
            #expect(try Data(contentsOf: url) == savedBytes)
            // Producer return can precede Cocoa's per-task completion. Join
            // actual session invalidation before asserting the delegate refund.
            session.finishTasksAndInvalidate()
            try await transportCompletion.waitForInvalidation()
            #expect(registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes)
        } catch {
            send.cancel(); await gate.release(); _ = await send.value
            service.invalidateForReprocessing(); throw error
        }
        service.invalidateForReprocessing()
    }

    @Test(arguments: [false, true], [false, true])
    func uncachedOwnedSendHeldInsideActualDetachedBuilderRejectsRetirement(cancel: Bool, final: Bool) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        let provider = try ownedProvider(f, registry: registry, final: final)
        let settings = AppSettings(), saved = ChatSettingsRestore(settings); defer { saved.restore(settings) }
        configureOwnedRoute(settings)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FrozenChatProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        FrozenChatProtocol.requests.reset()
        let gate = ChatSnapshotGate()
        let service = TranscriptChatService(contextProvider: provider, appSettings: settings, localPlugin: nil,
            aiService: AIService(session: session), beforeContextBuild: { await gate.hold() })
        // No cache or artifact history attachment participates in invalidation.
        #expect(!service.isPersistenceEnabled)
        let send = Task { await service.send("What happened?") }
        do {
            try await gate.waitForArrival(); try registry.retire(f.identity)
            if cancel { send.cancel() }
            #expect(service.isInvalidatedForReprocessing)
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            #expect(service.messages.isEmpty && FrozenChatProtocol.requests.values.isEmpty)
            await gate.release()
            #expect(await send.value == .notAccepted)
            #expect(service.messages.isEmpty && FrozenChatProtocol.requests.values.isEmpty && !service.isStreaming)
            #expect(registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes)
        } catch { send.cancel(); await gate.release(); _ = await send.value; service.invalidateForReprocessing(); throw error }
        service.invalidateForReprocessing()
    }

    @Test(arguments: [false, true], [false, true])
    func ownedSourceRetiredOnlyByAcceptanceCallbackCannotDispatch(local: Bool, final: Bool) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        let provider = try ownedProvider(f, registry: registry, final: final)
        let settings = AppSettings(), saved = ChatSettingsRestore(settings); defer { saved.restore(settings) }
        configureOwnedRoute(settings, local: local)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FrozenChatProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        FrozenChatProtocol.requests.reset()
        let policy = LiveModelResourcePolicy(profiles: []), probe = RetiredChatAdmissionProbe()
        let connection = MLHostConnection(binaryURL: URL(fileURLWithPath: "/private/tmp/never-launch-owned-chat-\(UUID())"),
            supportBase: f.root, resourceAdmission: .init(policy: policy, measurement: {
                await probe.record(); throw MLHostError.resourceDeferred
            }))
        let service = TranscriptChatService(contextProvider: provider, appSettings: settings,
            localPlugin: LocalAIPluginService(connection: connection), aiService: AIService(session: session))
        #expect(await service.send("Evidence", onAccepted: {
            do { try registry.retire(f.identity) } catch { Issue.record(error) }
        }) == .accepted)
        #expect(service.isInvalidatedForReprocessing && !service.isStreaming)
        #expect(service.messages.last?.outcome == .interrupted)
        #expect(service.messages.last?.content.isEmpty == true && service.messages.last?.basis?.evidence.isEmpty == false)
        #expect(FrozenChatProtocol.requests.values.isEmpty)
        #expect(await probe.calls == 0)
        #expect(await policy.jobCount == 0)
        #expect(registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes)
        await connection.shutdown(); await connection.waitForShutdown(); service.invalidateForReprocessing()
    }

    @Test func actualRemotePrivacyBeginHeldOnReceiptActorRejectsRetirementBeforeURLSessionAdmission() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var value: PreparedTranscriptChat? = try await prepared(ownedProvider(f, registry: registry))
        let context = PrivacyTrace.Context(receiptURL: f.root.appendingPathComponent("privacy-begin.json"),
            store: PrivacyReceiptStore(gapDirectoryURL: f.root.appendingPathComponent("gaps"), pendingDirectoryURL: f.root.appendingPathComponent("pending")))
        let hold = ContextReceiptHold(), marker = ContextRequestProbe()
        let receiptWork = Task.detached { await context.store.holdForContextOwnershipTest(hold) }
        defer { hold.release() }
        try await hold.waitForArrival()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FrozenChatProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        FrozenChatProtocol.requests.reset()
        let ai = AIService(session: session)
        func start(_ value: PreparedTranscriptChat) -> Task<Void, Never> {
            Task {
                marker.enter()
                let run = PrivacyTrace.$context.withValue(context) {
                    ai.startChat(systemPrompt: value.systemPrompt, userMessage: value.userMessage,
                        endpoint: .init(name: "Fixture", baseURL: "https://freeze-chat.invalid", modelName: "fixture"),
                        ownership: value.contextOwnership)
                }
                await #expect(throws: CancellationError.self) { for try await _ in run.stream {} }
                await run.waitForReturn()
            }
        }
        let work = start(try #require(value)); value = nil
        do {
            try await marker.waitForArrival()
            for _ in 0..<100 { await Task.yield() }
            try registry.retire(f.identity)
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            hold.release(); await receiptWork.value; await work.value
            let receipt = try #require(try await context.store.load(from: context.receiptURL))
            // A real cancelled receipt proves the initial check preceded retirement
            // and actual begin completed before the post-await rejection.
            #expect(receipt.attempts.map(\.outcome) == [.cancelled])
            #expect(FrozenChatProtocol.requests.values.isEmpty && !hold.timedOut)
            #expect(registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes)
        } catch { hold.release(); work.cancel(); await receiptWork.value; await work.value; throw error }
    }

    @Test(arguments: [307, 308], ["retired", "completedRetired", "completedValid"])
    func actualCocoaPromptPreservingRedirectRejectsRetirementAfterHeldReceipt(status: Int, scenario: String) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var value: PreparedTranscriptChat? = try await prepared(ownedProvider(f, registry: registry))
        let context = PrivacyTrace.Context(receiptURL: f.root.appendingPathComponent("privacy-redirect.json"),
            store: PrivacyReceiptStore(gapDirectoryURL: f.root.appendingPathComponent("gaps"), pendingDirectoryURL: f.root.appendingPathComponent("pending")))
        let url = URL(string: "https://freeze-chat.invalid/start")!
        var trace: PrivacyHTTPTrace? = PrivacyHTTPTrace(operation: .init(stage: .chat, data: [.text, .metadata],
            destination: .remote(url: url, provider: .openAICompatible)), context: context, ownership: value?.contextOwnership)
        await trace?.start()
        let hold = ContextReceiptHold(), result = ContextRedirectProbe()
        let receiptWork = Task.detached { await context.store.holdForContextOwnershipTest(hold) }
        defer { hold.release() }
        try await hold.waitForArrival()
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url) // Never resumed; real delegate callback boundary only.
        defer { task.cancel() }
        var request = URLRequest(url: URL(string: "https://freeze-chat.invalid/redirect")!)
        request.httpMethod = "POST"; request.httpBody = Data("Owned prompt body".utf8)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        var delegate: PrivacyHTTPTaskDelegate? = .init(trace: trace, ownership: value?.contextOwnership)
        delegate?.urlSession(session, task: task, willPerformHTTPRedirection: response,
            newRequest: request, completionHandler: { result.complete($0) })
        if scenario != "retired" { delegate?.urlSession(session, task: task, didCompleteWithError: nil) }
        delegate = nil; trace = nil; value = nil
        do {
            for _ in 0..<100 { await Task.yield() }
            if scenario != "completedValid" { try registry.retire(f.identity) }
            else { #expect(!registry.isRetired(recordingID: f.identity.recordingID)) }
            #expect(!result.returned)
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            hold.release(); await receiptWork.value
            try await result.waitForReturn()
            #expect(!result.accepted)
            guard !result.accepted else { return }
            try await f.eventually {
                let receipt = try? await context.store.load(from: context.receiptURL)
                return receipt?.attempts.map(\.outcome) == [.redirected, .cancelled]
            }
            let receipt = try #require(try await context.store.load(from: context.receiptURL))
            #expect(receipt.attempts.allSatisfy { $0.operation.data.contains(.text) })
            #expect(!hold.timedOut)
            if scenario == "completedValid" { try registry.retire(f.identity) }
            try await f.eventually { @MainActor in registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes }
        } catch { hold.release(); await receiptWork.value; throw error }
    }

    @Test func completedOwnedDelegateReleasesItsSlotAndLateCallbackCannotGainUnownedAuthority() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var value: PreparedTranscriptChat? = try await prepared(ownedProvider(f, registry: registry))
        let delegate = PrivacyHTTPTaskDelegate(trace: nil, ownership: value?.contextOwnership)
        value = nil; try registry.retire(f.identity)
        #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let url = URL(string: "https://freeze-chat.invalid/start")!, task = session.dataTask(with: URL(string: "https://freeze-chat.invalid/start")!)
        defer { task.cancel() }
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        #expect(registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes)
        let result = ContextRedirectProbe()
        var request = URLRequest(url: URL(string: "https://freeze-chat.invalid/late")!)
        request.httpMethod = "POST"; request.httpBody = Data("Owned stale prompt".utf8)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil))
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
            newRequest: request, completionHandler: { result.complete($0) })
        #expect(result.returned && !result.accepted)
        withExtendedLifetime(delegate) {}
    }

    @Test(arguments: ["completion", "failure"])
    func completedTraceAndDelegateHeldAliveReleaseSlotsAndPreserveFirstFinalFact(path: String) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var value: PreparedTranscriptChat? = try await prepared(ownedProvider(f, registry: registry))
        let context = PrivacyTrace.Context(receiptURL: f.root.appendingPathComponent("privacy-slot.json"),
            store: PrivacyReceiptStore(gapDirectoryURL: f.root.appendingPathComponent("gaps"), pendingDirectoryURL: f.root.appendingPathComponent("pending")))
        let url = URL(string: "https://freeze-chat.invalid/slot")!
        let trace = PrivacyHTTPTrace(operation: .init(stage: .chat, data: [.text, .metadata], destination: .remote(url: url, provider: .custom)),
            context: context, ownership: value?.contextOwnership)
        let delegate = PrivacyHTTPTaskDelegate(trace: trace, ownership: value?.contextOwnership)
        value = nil; await trace.start(); try registry.retire(f.identity)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        if path == "completion" { await trace.finish(response: response) }
        else { await trace.finish(error: URLError(.badServerResponse)) }
        #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url); defer { task.cancel() }
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        #expect(registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes)
        await trace.finish(error: CancellationError()); await trace.finish(response: response)
        let receipt = try #require(try await context.store.load(from: context.receiptURL))
        #expect(receipt.attempts.map(\.outcome) == [path == "completion" ? .succeeded : .failed])
        withExtendedLifetime(trace) {}; withExtendedLifetime(delegate) {}
    }

    @Test func alreadyCompletedTraceCannotAdmitNewRedirectWithStillValidOwnedSource() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var value: PreparedTranscriptChat? = try await prepared(ownedProvider(f, registry: registry))
        let context = PrivacyTrace.Context(receiptURL: f.root.appendingPathComponent("privacy-closed-hop.json"),
            store: PrivacyReceiptStore(gapDirectoryURL: f.root.appendingPathComponent("gaps"), pendingDirectoryURL: f.root.appendingPathComponent("pending")))
        let url = URL(string: "https://freeze-chat.invalid/start")!
        let trace = PrivacyHTTPTrace(operation: .init(stage: .chat, data: [.text, .metadata], destination: .remote(url: url, provider: .custom)),
            context: context, ownership: value?.contextOwnership)
        await trace.start(); await trace.finish(error: CancellationError())
        let delegate = PrivacyHTTPTaskDelegate(trace: trace, ownership: value?.contextOwnership)
        value = nil
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url); defer { task.cancel() }
        let result = ContextRedirectProbe()
        var request = URLRequest(url: URL(string: "https://freeze-chat.invalid/closed")!)
        request.httpMethod = "POST"; request.httpBody = Data("Valid owned prompt".utf8)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil))
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
            newRequest: request, completionHandler: { result.complete($0) })
        try await result.waitForReturn()
        #expect(!result.accepted && !registry.isRetired(recordingID: f.identity.recordingID))
        let receipt = try #require(try await context.store.load(from: context.receiptURL))
        #expect(receipt.attempts.map(\.outcome) == [.cancelled])
        delegate.urlSession(session, task: task, didCompleteWithError: nil); try registry.retire(f.identity)
        try await f.eventually { @MainActor in registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes }
    }

    @Test(arguments: [false, true])
    func directRemoteProducerKeepsLeaseThroughHeldActualReturnAfterCancellation(traced: Bool) async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var value: PreparedTranscriptChat? = try await prepared(ownedProvider(f, registry: registry))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FrozenChatProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        FrozenChatProtocol.requests.reset()
        let gate = ChatSnapshotGate(), ai = AIService(session: session, beforeChatProducerReturn: { await gate.hold() })
        func start(_ value: PreparedTranscriptChat) -> ChatStreamRun {
            ai.startChat(systemPrompt: value.systemPrompt, userMessage: value.userMessage,
                endpoint: .init(name: "Fixture", baseURL: "https://freeze-chat.invalid", modelName: "fixture"), ownership: value.contextOwnership)
        }
        let context: PrivacyTrace.Context? = traced ? .init(receiptURL: f.root.appendingPathComponent("privacy-producer.json"),
            store: PrivacyReceiptStore(gapDirectoryURL: f.root.appendingPathComponent("gaps"), pendingDirectoryURL: f.root.appendingPathComponent("pending"))) : nil
        let run = try PrivacyTrace.$context.withValue(context) { start(try #require(value)) }; value = nil
        do {
            var answer = ""; for try await token in run.stream { answer += token }
            #expect(answer == "Answer" && FrozenChatProtocol.requests.values.count == 1)
            try await gate.waitForArrival(); run.cancel(); try registry.retire(f.identity)
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            await gate.release(); await run.waitForReturn()
            // The actual URLSession completion callback may follow body EOF.
            try await f.eventually { @MainActor in registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes }
            if let context {
                let receipt = try #require(try await context.store.load(from: context.receiptURL))
                #expect(receipt.attempts.map(\.outcome) == [.succeeded])
            }
        } catch { run.cancel(); await gate.release(); await run.waitForReturn(); throw error }
    }

    @Test func directPrivacyStreamRunKeepsLeaseThroughActualUpstreamReturnAndFinalReceiptWrite() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var value: PreparedTranscriptChat? = try await prepared(ownedProvider(f, registry: registry))
        let context = PrivacyTrace.Context(receiptURL: f.root.appendingPathComponent("privacy-stream-return.json"),
            store: PrivacyReceiptStore(gapDirectoryURL: f.root.appendingPathComponent("gaps"), pendingDirectoryURL: f.root.appendingPathComponent("pending")))
        let gate = ChatSnapshotGate(), actualReturn = ContextRequestProbe()
        let run = PrivacyTrace.$context.withValue(context) {
            PrivacyTrace.streamRun(.init(stage: .chat, data: [.text, .metadata], destination: .local(provider: .localModel)),
                ownership: value?.contextOwnership) {
                let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
                let task = Task {
                    await gate.hold() // Actual producer intentionally ignores cancellation while held.
                    continuation.finish(); actualReturn.enter()
                }
                return .init(stream: stream, producer: task)
            }
        }
        value = nil
        let hold = ContextReceiptHold(); var receiptWork: Task<Void, Never>?
        defer { hold.release() }
        do {
            try await gate.waitForArrival() // Actual privacy begin completed before makeStream.
            receiptWork = Task.detached { await context.store.holdForContextOwnershipTest(hold) }
            try await hold.waitForArrival()
            run.cancel(); try registry.retire(f.identity)
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            await gate.release(); try await actualReturn.waitForArrival()
            for _ in 0..<100 { await Task.yield() }
            // Upstream actually returned; the wrapper's final receipt still cannot.
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            hold.release(); await receiptWork?.value; await run.waitForReturn()
            let receipt = try #require(try await context.store.load(from: context.receiptURL))
            #expect(receipt.attempts.map(\.outcome) == [.cancelled] && !hold.timedOut)
            #expect(registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes)
        } catch { run.cancel(); await gate.release(); hold.release(); await receiptWork?.value; await run.waitForReturn(); throw error }
    }

    @Test func actualLocalResourceMeasurementReturnsPermitBeforeOwnedRetirementRejectionWithoutHelperLaunch() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ownerLimit: 1)
        var value: PreparedTranscriptChat? = try await prepared(ownedProvider(f, registry: registry))
        let gate = ChatSnapshotGate(), policy = LiveModelResourcePolicy(profiles: [])
        let token = await policy.measurementToken(), flag = f.root.appendingPathComponent("helper-launched")
        let connection = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"), supportBase: f.root,
            environment: ["STUB_MODE": "chat-natural-exit-reader", "STUB_FLAG_1": flag.path],
            resourceAdmission: .init(policy: policy, measurement: {
                await gate.hold(); return .init(availableBytes: 2_000, pressure: .normal)
            }))
        func start(_ value: PreparedTranscriptChat) -> Task<ChatStreamRun, Never> {
            Task { await connection.startStream(.chatStream(systemPrompt: value.systemPrompt, userMessage: value.userMessage), ownership: value.contextOwnership) }
        }
        let work = start(try #require(value)); value = nil
        do {
            try await gate.waitForArrival(); try registry.retire(f.identity)
            #expect(registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            #expect(await policy.jobCount == 0)
            await gate.release()
            let run = await work.value
            await #expect(throws: CancellationError.self) { for try await _ in run.stream {} }
            await run.waitForReturn()
            #expect(await policy.jobCount == 0)
            #expect(await policy.measurementToken() != token) // Acquisition and exact refund actually returned.
            #expect(!FileManager.default.fileExists(atPath: flag.path))
            #expect(await connection.livePendingCount == 0)
            #expect(registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes)
            await connection.shutdown(); await connection.waitForShutdown()
        } catch { work.cancel(); await gate.release(); (await work.value).cancel(); await connection.shutdown(); await connection.waitForShutdown(); throw error }
    }

    @Test(arguments: ["stop", "invalidate"], ["remote", "local"])
    func acceptanceCallbackRetirementCannotDispatchEvidence(action: String, route: String) async throws {
        let settings = AppSettings(), saved = ChatSettingsRestore(settings)
        defer { saved.restore(settings) }
        let profile = MeetingProfile(name: "Retired acceptance fixture")
        settings.profiles = [profile]; settings.activeProfileId = profile.id; settings.automaticProfileId = nil
        settings.aiEngine = route == "remote" ? .remoteEndpoint : .qwenLocal
        settings.aiEndpoints = [Endpoint(name: "Retired", baseURL: "https://freeze-chat.invalid", modelName: "fixture")]
        settings.defaultAIEndpointId = settings.aiEndpoints[0].id
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FrozenChatProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        FrozenChatProtocol.requests.reset()
        let policy = LiveModelResourcePolicy(profiles: []), probe = RetiredChatAdmissionProbe()
        let connection = MLHostConnection(binaryURL: URL(fileURLWithPath: "/private/tmp/never-launch-retired-chat-\(UUID())"),
            supportBase: FileManager.default.temporaryDirectory, resourceAdmission: .init(policy: policy, measurement: {
                await probe.record()
                throw MLHostError.resourceDeferred
            }))
        let service = TranscriptChatService(transcriptText: "Private committed evidence", speakerLabels: [], appSettings: settings,
            localPlugin: LocalAIPluginService(connection: connection), aiService: AIService(session: session))
        var accepted = false
        #expect(await service.send("Question", onAccepted: {
            accepted = true
            if action == "stop" { service.stopGenerating() }
            else { service.invalidateForReprocessing() }
        }) == .accepted)
        for _ in 0..<100 { await Task.yield() }
        #expect(accepted && !service.isStreaming)
        #expect(FrozenChatProtocol.requests.values.isEmpty)
        #expect(await probe.calls == 0)
        #expect(await policy.jobCount == 0)
        await connection.shutdown()
        service.invalidateForReprocessing()
    }

    @Test(arguments: ["length", "missing", "malformed", "error"])
    func actualRemoteIncompleteAnswersNeverEnterLaterConversation(mode: String) async throws {
        let settings = AppSettings(), saved = ChatSettingsRestore(settings)
        defer { saved.restore(settings) }
        let profile = MeetingProfile(name: "Incomplete chat fixture")
        settings.profiles = [profile]; settings.activeProfileId = profile.id; settings.automaticProfileId = nil
        settings.aiEngine = .remoteEndpoint
        settings.aiEndpoints = [Endpoint(name: "Incomplete", baseURL: "https://\(mode)-completion-chat.invalid", modelName: "fixture")]
        settings.defaultAIEndpointId = settings.aiEndpoints[0].id
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FrozenChatProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        FrozenChatProtocol.requests.reset()
        let service = TranscriptChatService(transcriptText: "Evidence", speakerLabels: [], appSettings: settings,
            localPlugin: nil, aiService: AIService(session: session))
        await service.send("First question")
        let first = try #require(service.messages.last)
        #expect(first.outcome == (mode == "length" ? .truncated : mode == "error" ? .failed : .unconfirmed))
        #expect(first.content == "Partial proof")
        await service.send("Second question")
        let request = try #require(FrozenChatProtocol.requests.values.last)
        let body = String(decoding: request.body, as: UTF8.self)
        #expect(!body.contains("Partial proof"))
        #expect(body.components(separatedBy: "Second question").count == 2)
    }

    @Test func routeLanguageProviderAndHistoryAreFrozenBeforeSnapshotAwait() async throws {
        let settings = AppSettings(), saved = ChatSettingsRestore(settings)
        defer { saved.restore(settings) }
        let profile = MeetingProfile(name: "Frozen chat fixture")
        settings.profiles = [profile]; settings.automaticProfileId = nil; settings.activeProfileId = profile.id
        settings.aiEngine = .localCLI; settings.chatFallbackEngine = .remoteEndpoint; settings.outputLanguage = .english
        let endpoint = Endpoint(name: "Frozen", baseURL: "https://freeze-chat.invalid", modelName: "original", apiKey: "fixture-secret", maxOutputTokens: 20_000)
        settings.aiEndpoints = [endpoint]; settings.defaultAIEndpointId = endpoint.id
        let gate = ChatSnapshotGate()
        let original = TranscriptContextSnapshot.legacy(text: "Original committed evidence", recordingID: UUID(), speakerLabels: [])
        let provider = TranscriptContextProvider { .init(snapshot: { await gate.hold(); return original }) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FrozenChatProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        FrozenChatProtocol.requests.reset()
        let service = TranscriptChatService(contextProvider: provider, appSettings: settings, localPlugin: nil, aiService: AIService(session: session))
        service.startLoadingPersisted(load: { ChatHistory(messages: [ChatMessage(role: .assistant, content: "Loaded history", outcome: .completed)]) })
        let send = Task { await service.send("Question") }
        do { try await gate.waitForArrival() }
        catch {
            send.cancel()
            await gate.release()
            _ = await send.value
            service.invalidateForReprocessing()
            throw error
        }
        settings.aiEngine = .appleIntelligence; settings.chatFallbackEngine = .qwenLocal; settings.outputLanguage = .dutch
        settings.aiEndpoints = [Endpoint(name: "Changed", baseURL: "https://other.invalid", modelName: "changed")]
        service.rebindTranscript(text: "Changed source", speakerLabels: [])
        await gate.release()
        #expect(await send.value == .accepted)
        let request = try #require(FrozenChatProtocol.requests.values.first)
        let object = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(request.host == "freeze-chat.invalid" && object["model"] as? String == "original")
        #expect(object["max_tokens"] as? Int == 4_096)
        let body = String(decoding: request.body, as: UTF8.self)
        #expect(body.contains("Original committed evidence") && body.contains("Loaded history") && body.contains("English"))
        #expect(!body.contains("Changed source") && !body.contains("Dutch"))
        let answer = try #require(service.messages.last)
        #expect(answer.outcome == .completed && answer.basis?.route.endpointID == endpoint.id)
        let encoded = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
        #expect(!encoded.contains("fixture-secret"))
        #expect(answer.basis?.budget.outputTokens == 4_096)
    }

    @Test func emptyCommittedContextRetainsDraftAndNeverDispatches() async {
        let settings = AppSettings()
        let service = TranscriptChatService(transcriptText: "", speakerLabels: [], appSettings: settings, localPlugin: nil)
        var accepted = false
        #expect(await service.send("Keep my question", onAccepted: { accepted = true }) == .waitingForTranscript)
        #expect(!accepted && service.messages.isEmpty && !service.isStreaming)
        #expect(service.streamingNotice == "Waiting for transcript")
    }

    @Test func clearedConversationRejectsHeldOldHistoryLoad() async throws {
        let settings = AppSettings(), gate = ChatSnapshotGate()
        let service = TranscriptChatService(transcriptText: "Evidence", speakerLabels: [], appSettings: settings, localPlugin: nil)
        service.startLoadingPersisted(load: {
            await gate.hold()
            return ChatHistory(messages: [ChatMessage(role: .assistant, content: "Must not resurrect")])
        })
        do { try await gate.waitForArrival() }
        catch {
            service.invalidateForReprocessing()
            await gate.release()
            throw error
        }
        service.clearMessages()
        await gate.release()
        for _ in 0..<10 { await Task.yield() }
        #expect(service.messages.isEmpty)
    }
}

private actor RetiredChatAdmissionProbe {
    private(set) var calls = 0
    func record() { calls += 1 }
}

private actor ChatSnapshotGate {
    private var arrived = false, released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async { arrived = true; if !released { await withCheckedContinuation { waiter = $0 } } }
    func waitForArrival() async throws {
        let deadline = ContinuousClock.now + TestTiming.asyncDeadline
        while !arrived, ContinuousClock.now < deadline { await Task.yield() }
        try #require(arrived)
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

@MainActor
private struct ChatSettingsRestore {
    let engine: AppSettings.AIEngine, fallback: AppSettings.AIEngine, endpoints: [Endpoint], endpoint: UUID?, profiles: [MeetingProfile], active: UUID, automatic: UUID?, automaticOwner: UUID?, language: OutputLanguage
    init(_ settings: AppSettings) {
        engine = settings.aiEngine; fallback = settings.chatFallbackEngine; endpoints = settings.aiEndpoints
        endpoint = settings.defaultAIEndpointId; profiles = settings.profiles; active = settings.activeProfileId
        automatic = settings.automaticProfileId; automaticOwner = settings.automaticProfileRecordingID; language = settings.outputLanguage
    }
    func restore(_ settings: AppSettings) {
        settings.aiEngine = engine; settings.chatFallbackEngine = fallback; settings.aiEndpoints = endpoints
        settings.defaultAIEndpointId = endpoint; settings.profiles = profiles; settings.activeProfileId = active
        settings.automaticProfileId = automatic; settings.automaticProfileRecordingID = automaticOwner; settings.outputLanguage = language
    }
}

private final class FrozenChatProtocol: URLProtocol, @unchecked Sendable {
    struct Request: Sendable { let host: String; let body: Data }
    final class Requests: @unchecked Sendable {
        private let lock = NSLock(); private var storage: [Request] = []
        var values: [Request] { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ value: Request) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
        func reset() { lock.lock(); defer { lock.unlock() }; storage = [] }
    }
    static let requests = Requests()
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "freeze-chat.invalid" || request.url?.host?.hasSuffix("-completion-chat.invalid") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
        }
        Self.requests.append(.init(host: request.url!.host!, body: body))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        let host = request.url!.host!
        let payload: String
        if host.hasSuffix("-completion-chat.invalid") {
            let partial = "data: {\"choices\":[{\"delta\":{\"content\":\"Partial proof\"}}]}\n\n"
            if host.hasPrefix("length-") { payload = partial + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n" }
            else if host.hasPrefix("missing-") { payload = partial + "data: [DONE]\n\n" }
            else if host.hasPrefix("malformed-") { payload = partial + "data: {broken\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n" }
            else { payload = partial + "data: {\"error\":{\"message\":\"fixture failed\"}}\n\n" }
        } else {
            payload = "data: {\"choices\":[{\"delta\":{\"content\":\"Answer\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        }
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}


/// Occupies the actual receipt actor with a bounded synchronous wait. Production
/// begin/finish calls queue on this actor; tests release and join the holder.
private final class ContextReceiptHold: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var arrived = false, released = false, timeout = false
    var timedOut: Bool { lock.withLock { timeout } }
    func enterAndWait() {
        lock.withLock { arrived = true }
        let result = semaphore.wait(timeout: .now() + TestTiming.asyncDeadlineSeconds)
        lock.withLock { timeout = result == .timedOut }
    }
    func release() {
        let signal = lock.withLock { if released { return false }; released = true; return true }
        if signal { semaphore.signal() }
    }
    func waitForArrival() async throws {
        let deadline = ContinuousClock.now + TestTiming.asyncDeadline
        while !lock.withLock({ arrived }), ContinuousClock.now < deadline { await Task.yield() }
        try #require(lock.withLock { arrived })
    }
}
private extension PrivacyReceiptStore {
    func holdForContextOwnershipTest(_ hold: ContextReceiptHold) { hold.enterAndWait() }
}
private final class ContextRequestProbe: @unchecked Sendable {
    private let lock = NSLock(); private var arrived = false
    func enter() { lock.withLock { arrived = true } }
    func waitForArrival() async throws {
        let deadline = ContinuousClock.now + TestTiming.asyncDeadline
        while !lock.withLock({ arrived }), ContinuousClock.now < deadline { await Task.yield() }
        try #require(lock.withLock { arrived })
    }
}
private final class ContextRedirectProbe: @unchecked Sendable {
    private let lock = NSLock(); private var result: (returned: Bool, accepted: Bool) = (false, false)
    var returned: Bool { lock.withLock { result.returned } }
    var accepted: Bool { lock.withLock { result.accepted } }
    func complete(_ request: URLRequest?) { lock.withLock { result = (true, request != nil) } }
    func waitForReturn() async throws {
        let deadline = ContinuousClock.now + TestTiming.asyncDeadline
        while !returned, ContinuousClock.now < deadline { await Task.yield() }
        try #require(returned)
    }
}

private final class ContextSessionCompletion: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let completion = ContextRequestProbe()
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) { completion.enter() }
    func waitForInvalidation() async throws { try await completion.waitForArrival() }
}
