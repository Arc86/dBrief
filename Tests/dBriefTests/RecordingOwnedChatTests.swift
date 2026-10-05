import Foundation
import Testing
import dBriefWire
@testable import dBrief

@MainActor @Suite("Recording-owned chat lifecycle", .serialized)
struct RecordingOwnedChatTests {
    @Test(arguments: ["recording", "value"])
    func unattachedOwnedRequestsShareAdmissionBeforeBuildAndThroughActualStoppedReturn(kind: String) async throws {
        try await withFixture { f in
            let gate = LiveArtifactGate(stage: .sourceChat), duplicateGate = LiveArtifactGate(stage: .sourceChat)
            let postStopGate = LiveArtifactGate(stage: .sourceChat), firstBuilds = OwnedChatCounter(), postStopReturned = OwnedChatCounter()
            f.cleanupGates += [gate, duplicateGate, postStopGate]
            let value = try f.entry.artifacts.legacyContext()
            let provider: TranscriptContextProvider = kind == "value" ? .value { value } :
                .recording(recordingID: f.files.identity.recordingID, registry: f.registry,
                    legacy: { .legacy(text: "Wrong fallback", recordingID: f.files.identity.recordingID, speakerLabels: []) })
            let firstService = TranscriptChatService(contextProvider: provider, appSettings: f.settings, localPlugin: nil,
                aiService: AIService(session: f.session), beforeContextBuild: {
                    firstBuilds.add()
                    _ = try? await (firstBuilds.count == 1 ? gate : postStopGate).enter(.sourceChat)
                })
            let built = OwnedChatCounter(), returned = OwnedChatCounter()
            let duplicate = TranscriptChatService(contextProvider: provider, appSettings: f.settings, localPlugin: nil,
                aiService: AIService(session: f.session), beforeContextBuild: {
                    built.add(); _ = try? await duplicateGate.enter(.sourceChat)
                })
            f.services += [firstService, duplicate]
            let first = f.send(firstService, "First held question")
            try await gate.waitForArrival()
            let second = Task { let result = await duplicate.send("Duplicate question"); returned.add(); return result }
            f.sends.append(second)
            try await f.files.eventually { built.count > 0 || returned.count > 0 }
            #expect(built.count == 0 && returned.count == 1)
            #expect(duplicate.messages.isEmpty && OwnedChatProtocol.requests.count == 0)
            do { let claim = try f.entry.artifacts.beginChatRequest(); claim.release(); Issue.record("Unattached owned build must occupy the original request") }
            catch { #expect(error as? LiveArtifactError == .queueFull) }
            firstService.stopGenerating()
            let postStopCheck = Task {
                #expect(await firstService.send("Before actual builder return") == .notAccepted)
                postStopReturned.add()
            }
            f.joins.append(postStopCheck)
            try await f.files.eventually { firstBuilds.count > 1 || postStopReturned.count == 1 }
            #expect(firstBuilds.count == 1 && postStopReturned.count == 1)
            firstService.stopGenerating()
            do { let claim = try f.entry.artifacts.beginChatRequest(); claim.release(); Issue.record("Stop must retain the request until actual builder return") }
            catch { #expect(error as? LiveArtifactError == .queueFull) }
            duplicate.stopGenerating()
            await duplicateGate.release(); await postStopGate.release(); await gate.release()
            await postStopCheck.value
            #expect(await first.value == .notAccepted)
            #expect(await second.value == .notAccepted)
            let claim = try f.entry.artifacts.beginChatRequest(); claim.release()
            #expect(OwnedChatProtocol.requests.count == 0)
        }
    }

    @Test(arguments: ["stop", "retire"], [false, true])
    func preAcceptanceStopOrRetirementPreservesHistoricalRowsAndSavedBytes(action: String, streamingHistory: Bool) async throws {
        try await withFixture { f in
            let gate = LiveArtifactGate(stage: .sourceChat); f.cleanupGates.append(gate)
            let snapshot = try f.entry.artifacts.legacyContext()
            let prepared = try TranscriptContextBuilder.build(snapshot: snapshot,
                route: .init(engine: "historical", endpointID: nil, provider: nil, origin: nil, model: nil),
                budget: .init(contextTokens: 8_192, outputTokens: 512, templateReserve: 256),
                language: .matchInput, question: "Historical question", history: [], answerID: UUID())
            let history = ChatHistory(messages: [.init(role: .user, content: "Historical question"),
                .init(role: .assistant, content: streamingHistory ? "Historical streaming-looking fact" : "",
                    basis: prepared.basis, outcome: streamingHistory ? .streaming : .completed)])
            let store = ChatStore(), url = f.files.root.appendingPathComponent("preserved-history.chat.json")
            try await store.save(history, to: url)
            let bytes = try Data(contentsOf: url)
            let provider = TranscriptContextProvider.value { snapshot }
            let service = TranscriptChatService(contextProvider: provider, appSettings: f.settings, localPlugin: nil,
                aiService: AIService(session: f.session), beforeContextBuild: { _ = try? await gate.enter(.sourceChat) })
            f.services.append(service)
            if streamingHistory {
                // Runtime history can contain this row; cold load normally normalizes it.
                service.startLoadingPersisted(load: { history })
            }
            service.enablePersistence(store: store, url: url)
            if streamingHistory { try await f.files.eventually { await MainActor.run { !service.isLoadingHistory } } }
            await service.loadPersisted()
            let oldRows = service.messages
            #expect(oldRows.last?.basis == prepared.basis)
            #expect(oldRows.last?.outcome == (streamingHistory ? .streaming : .completed))
            let send = f.send(service, "New question still before acceptance")
            try await gate.waitForArrival()
            #expect(service.messages == oldRows && service.isStreaming)
            if action == "stop" { service.stopGenerating() }
            else { try f.registry.retire(f.files.identity) }
            #expect(service.messages == oldRows)
            if action == "retire" { #expect(service.isInvalidatedForReprocessing && !service.isStreaming) }
            await gate.release(); #expect(await send.value == .notAccepted)
            await service.flushPendingSave()
            #expect(service.messages == oldRows)
            #expect(try Data(contentsOf: url) == bytes)
            #expect(OwnedChatProtocol.requests.count == 0)
        }
    }

    @Test func retiringOriginalEntryRevokesUncachedNilPrivacyChatAndOnlyItsAcceptedRow() async throws {
        try await withFixture { f in
            let returned = LiveArtifactGate(stage: .sourceChat); f.cleanupGates.append(returned)
            let provider = TranscriptContextProvider.recording(recordingID: f.files.identity.recordingID,
                registry: f.registry, legacy: { .legacy(text: "Wrong fallback", recordingID: f.files.identity.recordingID, speakerLabels: []) })
            let service = TranscriptChatService(contextProvider: provider, appSettings: f.settings, localPlugin: nil,
                aiService: AIService(session: f.session, beforeChatProducerReturn: { _ = try? await returned.enter(.sourceChat) }))
            let other = TranscriptChatService(contextProvider: .value {
                .legacy(text: "Unrelated evidence", recordingID: UUID(), speakerLabels: [])
            }, appSettings: f.settings, localPlugin: nil, aiService: AIService(session: f.session))
            f.services += [service, other]
            let send = f.send(service, "Accepted current question")
            try await f.files.eventually { await MainActor.run { service.messages.last?.content == "Partial answer." } }
            let basis = service.messages.last?.basis, answerID = service.messages.last?.id
            try f.registry.retire(f.files.identity)
            #expect(service.isInvalidatedForReprocessing && !service.isStreaming)
            #expect(service.messages.last?.id == answerID && service.messages.last?.basis == basis)
            #expect(service.messages.last?.outcome == .interrupted)
            #expect(!other.isInvalidatedForReprocessing)
            service.stopGenerating(); send.cancel()
            try await returned.waitForArrival()
            #expect(f.registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            await returned.release(); _ = await send.value
        }
    }

    @Test(arguments: ["builder", "producer"])
    func hintlessUnownedCustomSnapshotRetiresThroughActualValidatedSource(stage: String) async throws {
        try await withFixture { f in
            let gate = LiveArtifactGate(stage: .sourceChat); f.cleanupGates.append(gate)
            let snapshot = TranscriptContextSnapshot.legacy(text: "Conventional custom source", recordingID: f.files.identity.recordingID, speakerLabels: [])
            let prepared = try TranscriptContextBuilder.build(snapshot: snapshot,
                route: .init(engine: "historical", endpointID: nil, provider: nil, origin: nil, model: nil),
                budget: .init(contextTokens: 8_192, outputTokens: 512, templateReserve: 256),
                language: .matchInput, question: "Historical question", history: [], answerID: UUID())
            let historical = ChatHistory(messages: [.init(role: .user, content: "Historical question"),
                .init(role: .assistant, content: "Historical confirmed answer", basis: prepared.basis, outcome: .completed)])
            let store = ChatStore(), url = f.files.root.appendingPathComponent("hintless-history.chat.json")
            try await store.save(historical, to: url)
            let provider = TranscriptContextProvider { .init(snapshot: { snapshot }) }
            let service = TranscriptChatService(contextProvider: provider, appSettings: f.settings, localPlugin: nil,
                aiService: AIService(session: f.session, beforeChatProducerReturn: {
                    if stage == "producer" { _ = try? await gate.enter(.sourceChat) }
                }), beforeContextBuild: { if stage == "builder" { _ = try? await gate.enter(.sourceChat) } })
            f.services.append(service)
            service.enablePersistence(store: store, url: url); await service.loadPersisted()
            let oldRows = service.messages
            #expect(oldRows == historical.messages)
            let send = f.send(service, "Validated conventional source")
            if stage == "builder" {
                try await gate.waitForArrival()
                #expect(service.messages == oldRows && OwnedChatProtocol.requests.count == 0)
            } else {
                try await f.files.eventually { await MainActor.run { service.messages.last?.content == "Partial answer." } }
                #expect(OwnedChatProtocol.requests.count == 1)
                #expect(service.messages.last?.basis?.source.recordingID == f.files.identity.recordingID)
                await service.flushPendingSave()
            }
            let savedBytes = try Data(contentsOf: url), current = service.messages.last
            try f.registry.retire(f.files.identity)
            #expect(service.isInvalidatedForReprocessing && !service.isStreaming)
            #expect(Array(service.messages.prefix(oldRows.count)) == oldRows)
            if stage == "producer" {
                #expect(service.messages.last?.id == current?.id && service.messages.last?.basis == current?.basis)
                #expect(service.messages.last?.outcome == .interrupted)
            } else { #expect(service.messages == oldRows) }
            // Wrongly admitted controls stop before releasing the held build.
            service.stopGenerating(); send.cancel()
            if stage == "producer" { try await gate.waitForArrival() }
            await gate.release()
            #expect(await send.value == (stage == "producer" ? .accepted : .notAccepted))
            await service.flushPendingSave()
            #expect(try Data(contentsOf: url) == savedBytes)
            #expect(OwnedChatProtocol.requests.count == (stage == "producer" ? 1 : 0))
        }
    }

    @Test func stoppedHintlessSnapshotCannotReplaceNewerSendSourceMetadata() async throws {
        try await withFixture { f in
            let oldGate = LiveArtifactGate(stage: .sourceChat), currentGate = LiveArtifactGate(stage: .sourceChat)
            f.cleanupGates += [oldGate, currentGate]
            let nextIdentity = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
            _ = try f.registry.registerLegacy(nextIdentity)
            let old = TranscriptContextSnapshot.legacy(text: "Old source", recordingID: f.files.identity.recordingID, speakerLabels: [])
            let next = TranscriptContextSnapshot.legacy(text: "Current source", recordingID: nextIdentity.recordingID, speakerLabels: [])
            let captured = OwnedChatCounter()
            let provider = TranscriptContextProvider {
                captured.add(); let value = captured.count == 1 ? old : next
                return .init(snapshot: {
                    if value.source.recordingID == old.source.recordingID { _ = try? await oldGate.enter(.sourceChat) }
                    return value
                })
            }
            let service = TranscriptChatService(contextProvider: provider, appSettings: f.settings, localPlugin: nil,
                aiService: AIService(session: f.session), beforeContextBuild: { _ = try? await currentGate.enter(.sourceChat) })
            f.services.append(service)
            let obsolete = f.send(service, "Old held snapshot")
            try await oldGate.waitForArrival(); service.stopGenerating()
            let current = f.send(service, "Current held build")
            try await currentGate.waitForArrival()
            await oldGate.release(); #expect(await obsolete.value == .notAccepted)
            try f.registry.retire(f.files.identity)
            #expect(!service.isInvalidatedForReprocessing && service.isStreaming)
            try f.registry.retire(nextIdentity)
            #expect(service.isInvalidatedForReprocessing && !service.isStreaming)
            #expect(service.messages.isEmpty && OwnedChatProtocol.requests.count == 0)
            service.stopGenerating(); current.cancel()
            await currentGate.release(); #expect(await current.value == .notAccepted)
        }
    }

    @Test(arguments: ["oversized-line", "flood"])
    func directOwnedRemoteDefaultFlagStillBoundsInputBeforeHeldConsumer(mode: String) async throws {
        try await withFixture { f in
            let gate = LiveArtifactGate(stage: .sourceChat); f.cleanupGates.append(gate)
            OwnedChatProtocol.responses.set(mode)
            let value = try f.entry.artifacts.legacyContext()
            let run = AIService(session: f.session, beforeChatProducerReturn: { _ = try? await gate.enter(.sourceChat) })
                .startChat(systemPrompt: "Owned direct input", userMessage: "Default flag",
                    endpoint: f.settings.aiEndpoints[0], ownership: value.contextOwnership)
            f.trackRun(run)
            // Both fixtures keep HTTP open; overflow must reach the real return gate.
            try await gate.waitForArrival()
            var received = 0
            do { for try await chunk in run.stream {
                #expect(chunk.utf8.count <= ChatStreamBuffer.chunkLimit); received += chunk.utf8.count
            }; Issue.record("Owned overflow must report an incomplete result") }
            catch { #expect(ChatStreamEndError.classify(error) == .limited) }
            #expect(received <= ChatStreamBuffer.textLimit)
            if mode == "oversized-line" { #expect(received == 0) }
            await gate.release(); await run.waitForReturn()
        }
    }

    @Test(arguments: ["oversized-finite", "flood-finite"])
    func directOwnedFiniteRemoteDefaultFlagBoundsRawLineAndAggregate(mode: String) async throws {
        try await withFixture { f in
            let gate = LiveArtifactGate(stage: .sourceChat); f.cleanupGates.append(gate)
            OwnedChatProtocol.responses.set(mode)
            let value = try f.entry.artifacts.legacyContext()
            let run = AIService(session: f.session, beforeChatProducerReturn: { _ = try? await gate.enter(.sourceChat) })
                .startChat(systemPrompt: "Owned direct input", userMessage: "Default flag",
                    endpoint: f.settings.aiEndpoints[0], ownership: value.contextOwnership)
            f.trackRun(run)
            // Finite real HTTP responses also reach this gate in the unbounded causal control.
            try await gate.waitForArrival()
            var received = 0
            do { for try await chunk in run.stream {
                #expect(chunk.utf8.count <= ChatStreamBuffer.chunkLimit); received += chunk.utf8.count
            }; Issue.record("Owned overflow must report an incomplete result") }
            catch { #expect(ChatStreamEndError.classify(error) == .limited) }
            #expect(received <= ChatStreamBuffer.textLimit)
            if mode == "oversized-finite" { #expect(received == 0) }
            await gate.release(); await run.waitForReturn()
        }
    }

    @Test func directOwnedPrivacyDefaultFlagBoundsAggregateAndRetainsActualProducer() async throws {
        try await withFixture { f in
            let gate = LiveArtifactGate(stage: .sourceChat); f.cleanupGates.append(gate)
            let value = try f.entry.artifacts.legacyContext(), processed = OwnedChatCounter()
            let run = PrivacyTrace.streamRun(.init(stage: .chat, data: [.text], destination: .local(provider: .localModel)),
                ownership: value.contextOwnership) {
                let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
                let task = Task {
                    continuation.yield(String(repeating: "x", count: ChatStreamBuffer.textLimit + 1)); continuation.finish()
                    _ = try? await gate.enter(.sourceChat)
                }
                return .init(stream: stream, cancel: { processed.add(); task.cancel() }, join: { await task.value })
            }
            f.trackRun(run)
            try await gate.waitForArrival()
            try await f.files.eventually { processed.count > 0 }
            try f.registry.retire(f.files.identity)
            #expect(f.registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            await gate.release()
            do { for try await _ in run.stream {}; Issue.record("Owned oversized chunk must fail") }
            catch { #expect(ChatStreamEndError.classify(error) == .limited) }
            await run.waitForReturn()
        }
    }

    @Test func unattachedStoppedActualRemoteProducerKeepsOriginalRequestUntilReturn() async throws {
        try await withFixture { f in
            let gate = LiveArtifactGate(stage: .sourceChat); f.cleanupGates.append(gate)
            let provider = TranscriptContextProvider.recording(recordingID: f.files.identity.recordingID, registry: f.registry,
                legacy: { .legacy(text: "Wrong fallback", recordingID: f.files.identity.recordingID, speakerLabels: []) })
            let service = TranscriptChatService(contextProvider: provider, appSettings: f.settings, localPlugin: nil,
                aiService: AIService(session: f.session, beforeChatProducerReturn: { _ = try? await gate.enter(.sourceChat) }))
            f.services.append(service)
            let send = f.send(service, "Unattached owned question")
            try await f.files.eventually { await MainActor.run { service.messages.last?.content == "Partial answer." } }
            let basis = service.messages.last?.basis
            service.stopGenerating(); try await gate.waitForArrival()
            try f.registry.captureDidClose(f.files.identity)
            #expect(!f.entry.artifacts.persistenceStarted && !f.entry.artifacts.canExpire)
            #expect(service.messages.last?.outcome == .interrupted && service.messages.last?.basis == basis)
            #expect(await service.send("Before actual producer return") == .notAccepted)
            let duplicate = TranscriptChatService(contextProvider: provider, appSettings: f.settings, localPlugin: nil,
                aiService: AIService(session: f.session)); f.services.append(duplicate)
            #expect(await duplicate.send("Uncached duplicate") == .notAccepted)
            #expect(OwnedChatProtocol.requests.count == 1)
            await gate.release(); #expect(await send.value == .accepted)
            // Actual delegate completion can follow producer return. Observe
            // the original request/Pin refund within the existing deadline.
            try await f.files.eventually { await MainActor.run { f.entry.artifacts.canExpire } }
            #expect(f.entry.artifacts.canExpire)
            let next = f.send(service, "After actual producer return")
            try await f.files.eventually { await MainActor.run { service.messages.count == 4 && service.messages.last?.content == "Partial answer." } }
            service.stopGenerating(); _ = await next.value
        }
    }

    @Test(arguments: ["undeclared", "declared", "wrongID", "wrongAuthority", "declaredUnowned"])
    func customOwnedProviderRequiresOriginalSynchronousAuthorityBeforeBuild(mode: String) async throws {
        try await withFixture { f in
            let value = try f.entry.artifacts.legacyContext(), built = OwnedChatCounter()
            let actual: TranscriptContextSnapshot
            if mode == "wrongID" {
                actual = .init(source: .legacy(recordingID: UUID(), live: true), segments: value.segments, ownership: value.contextOwnership)
            } else if mode == "wrongAuthority" {
                let other = try f.registry.registerLegacy(.init(recordingID: UUID(), captureSessionID: UUID()))
                try other.artifacts.appendLegacy([.init(start: 0, end: 1, text: "Different owner's evidence")])
                actual = try other.artifacts.legacyContext()
            } else if mode == "declaredUnowned" {
                actual = .init(source: value.source, segments: value.segments)
            } else { actual = value }
            let provider = TranscriptContextProvider {
                .init(ownership: mode == "undeclared" ? nil : value.contextOwnership, snapshot: { actual })
            }
            let service = TranscriptChatService(contextProvider: provider, appSettings: f.settings, localPlugin: nil,
                aiService: AIService(session: f.session), beforeContextBuild: { built.add() }); f.services.append(service)
            let send = Task { await service.send("Check declared source", onAccepted: {
                // A wrongly admitted causal control must stop before transport dispatch.
                if mode == "declaredUnowned" { service.stopGenerating() }
            }) }; f.sends.append(send)
            if mode == "declared" {
                try await f.files.eventually { await MainActor.run { service.messages.last?.content == "Partial answer." } }
                service.stopGenerating(); #expect(await send.value == .accepted)
                #expect(built.count == 1 && OwnedChatProtocol.requests.count == 1)
            } else {
                #expect(await send.value == .notAccepted)
                #expect(built.count == 0 && OwnedChatProtocol.requests.count == 0 && service.messages.isEmpty)
            }
            let claim = try f.entry.artifacts.beginChatRequest(); claim.release()
            // Pure freeze remains a fact operation, with no transient claim.
            #expect(try await provider.freeze().snapshot() == actual)
        }
    }

    @Test(arguments: ["value", "custom"])
    func attachedOriginalAuthorityRejectsNilReturnedOwnershipBeforeBuild(kind: String) async throws {
        try await withFixture { f in
            let value = TranscriptContextSnapshot.legacy(text: "Unowned same-ID custom facts",
                recordingID: f.files.identity.recordingID, speakerLabels: [])
            let provider: TranscriptContextProvider = kind == "value" ? .value { value } :
                .init { .init(snapshot: { value }) }
            let built = OwnedChatCounter()
            let service = TranscriptChatService(contextProvider: provider, appSettings: f.settings, localPlugin: nil,
                aiService: AIService(session: f.session), beforeContextBuild: { built.add() })
            f.services.append(service); f.registry.startPersistence(f.files.identity)
            service.enableRecordingPersistence(owner: f.entry.artifacts)
            let send = Task { await service.send("Require actual attached ownership", onAccepted: {
                // A wrongly accepted causal control stops before network dispatch.
                service.stopGenerating()
            }) }; f.sends.append(send)
            #expect(await send.value == .notAccepted)
            #expect(built.count == 0 && OwnedChatProtocol.requests.count == 0 && service.messages.isEmpty)
            let claim = try f.entry.artifacts.beginChatRequest(); claim.release()
            #expect(try await provider.freeze().snapshot() == value)
        }
    }

    @Test func retirementMetadataReachesIdleStandardProviderButPreservesFreshValidityWithSameRecordingID() async throws {
        try await withFixture { f in
            let oldProvider = TranscriptContextProvider.recording(recordingID: f.files.identity.recordingID, registry: f.registry,
                legacy: { .legacy(text: "Wrong fallback", recordingID: f.files.identity.recordingID, speakerLabels: []) })
            let old = TranscriptChatService(contextProvider: oldProvider, appSettings: f.settings, localPlugin: nil)
            let replacement = LiveRecordingSessionRegistry(artifactRoot: f.files.root.appendingPathComponent("fresh-generation"))
            let entry = try replacement.registerLegacy(.init(recordingID: f.files.identity.recordingID, captureSessionID: UUID()))
            try entry.artifacts.appendLegacy([.init(start: 0, end: 1, text: "Fresh generation")])
            let freshProvider = TranscriptContextProvider.recording(recordingID: f.files.identity.recordingID, registry: replacement,
                legacy: { .legacy(text: "Wrong fallback", recordingID: f.files.identity.recordingID, speakerLabels: []) })
            let fresh = TranscriptChatService(contextProvider: freshProvider, appSettings: f.settings, localPlugin: nil)
            f.services += [old, fresh]
            #expect(old.recordingIdentity == f.files.identity.recordingID && fresh.recordingIdentity == f.files.identity.recordingID)
            try f.registry.retire(f.files.identity)
            #expect(old.isInvalidatedForReprocessing && !fresh.isInvalidatedForReprocessing && entry.isValid)
            #expect(try await freshProvider.freeze().snapshot().segments.map(\.text) == ["Fresh generation"])
            try replacement.retire(entry.identity)
            #expect(fresh.isInvalidatedForReprocessing)
        }
    }

    @Test(arguments: ["unicode", "error"])
    func unattachedOwnedResponseAndErrorUseFiniteEnvelope(mode: String) async throws {
        try await withFixture { f in
            OwnedChatProtocol.responses.set(mode)
            let provider = TranscriptContextProvider.recording(recordingID: f.files.identity.recordingID, registry: f.registry,
                legacy: { .legacy(text: "Wrong fallback", recordingID: f.files.identity.recordingID, speakerLabels: []) })
            let service = TranscriptChatService(contextProvider: provider, appSettings: f.settings, localPlugin: nil,
                aiService: AIService(session: f.session)); f.services.append(service)
            #expect(!service.usesRecordingPersistence)
            #expect(await service.send("Owned unattached envelope") == .accepted)
            let answer = try #require(service.messages.last)
            #expect(answer.basis != nil && answer.content.utf8.count <= ChatStreamBuffer.textLimit)
            #expect((service.streamingError?.utf8.count ?? 0) <= 4_096)
            if mode == "error" { #expect(answer.outcome == .failed && answer.content.isEmpty) }
            else { #expect(answer.outcome == .limited && answer.content.isEmpty) }
            #expect(!f.entry.artifacts.persistenceStarted)
        }
    }

    @Test func quitFreezesAnInterruptedAnswerWithoutWaitingForItsHeldProducerReturn() async throws {
        let returned = LiveArtifactGate(stage: .sourceChat)
        try await withFixture(gates: []) { f in
            f.cleanupGates.append(returned)
            let service = f.service(returnGate: returned), send = f.send(service, "Question before Quit")
            try await f.files.eventually { await MainActor.run { service.messages.last?.content == "Partial answer." } }
            let basis = try #require(service.messages.last?.basis)
            try f.registry.captureDidClose(f.files.identity)
            #expect(await LiveArtifactTerminationDrain.run(registry: f.registry, deadline: .seconds(3)) == .complete)
            try await returned.waitForArrival()
            #expect(!service.isStreaming && !f.entry.artifacts.canEvict)
            let saved = try await f.recover()
            #expect(saved.chat?.messages.last?.outcome == .interrupted && saved.chat?.messages.last?.basis == basis)
            let target = f.entry.artifacts.acceptedChatRevision
            await returned.release(); _ = await send.value
            try await f.files.eventually { await MainActor.run { f.entry.artifacts.canEvict } }
            #expect(f.entry.artifacts.acceptedChatRevision == target)
        }
    }

    @Test func quitCacheFlushSkipsHeldOwnedWriterAndStillSavesLegacyHistory() async throws {
        let gate = LiveArtifactGate(stage: .sourceChat)
        try await withFixture(gates: [gate]) { f in
            let owned = f.service(), send = f.send(owned, "Owned question")
            try await gate.waitForArrival()
            let cache = TranscriptChatStore()
            cache.set(owned, for: f.files.identity.recordingID, url: f.files.audio)
            let legacyURL = f.files.root.appendingPathComponent("legacy.chat.json")
            let legacy = f.legacyService()
            legacy.enablePersistence(store: ChatStore(), url: legacyURL)
            let legacySend = f.send(legacy, "Legacy pending history")
            try await f.files.eventually { await MainActor.run { legacy.messages.last?.content == "Partial answer." } }
            legacy.stopGenerating(); _ = await legacySend.value
            cache.set(legacy, for: legacyURL)
            await cache.flushAll(includeRecordingOwned: false)
            #expect(try await ChatStore().load(from: legacyURL)?.messages.first?.content == "Legacy pending history")
            #expect(!f.entry.artifacts.isDurable)
            owned.stopGenerating(); _ = await send.value
            await gate.release(); try await f.entry.artifacts.flush()
        }
    }

    @Test func fastSendWaitsForOriginalHistoryAndRestoresItsRevision() async throws {
        let gate = LiveArtifactGate(stage: .historyLoad)
        try await withFixture(gates: [gate]) { f in
            try await LiveSessionArtifactStore(identity: f.files.identity, rootURL: f.files.root)
                .saveChat(f.files.history("Original conversation"), revision: 7)
            let service = f.service()
            try await gate.waitForArrival()
            let send = f.send(service, "New question")
            for _ in 0..<100 { await Task.yield() }
            #expect(service.messages.isEmpty && OwnedChatProtocol.requests.count == 0)
            await gate.release()
            try await f.files.eventually { await MainActor.run { service.messages.last?.content == "Partial answer." } }
            service.stopGenerating(); _ = await send.value
            try await f.entry.artifacts.flush()
            let restored = try await f.recover()
            #expect(restored.chat?.messages.first?.content == "Original conversation")
            #expect(restored.chat?.messages.count == 3)
            #expect((restored.chat?.revision ?? 0) > 7)
            #expect(restored.chat?.messages.first?.basis == nil)
        }
    }

    @Test func partialAnswerIsDurableBeforeStopAndKeepsItsOriginalOwnerAcrossBinding() async throws {
        try await withFixture { f in
            let service = f.service(), send = f.send(service, "Question during capture")
            try await f.files.eventually {
                let saved = try? await f.recover().chat
                return saved?.messages.last?.content == "Partial answer."
            }
            #expect(service.isStreaming)
            let basis = try #require(service.messages.last?.basis)
            #expect(basis.source.recordingID == f.files.identity.recordingID)
            try f.registry.captureDidClose(f.files.identity)
            try f.entry.artifacts.bind(to: f.files.audio)
            service.stopGenerating(); _ = await send.value
            try await f.entry.artifacts.flush()
            let saved = try await f.recover()
            #expect(saved.audioURL == f.files.audio)
            #expect(saved.chat?.messages.last?.outcome == .interrupted)
            #expect(saved.chat?.messages.last?.basis == basis)
            #expect(saved.chat?.identity == f.files.identity)
            #expect(!FileManager.default.fileExists(atPath: f.files.session.appendingPathComponent("chat.json").path))
        }
    }

    @Test func clearThenImmediateSendAndBindStayOrderedBehindHeldChatIO() async throws {
        let gate = LiveArtifactGate(stage: .sourceChat)
        try await withFixture(gates: [gate]) { f in
            let service = f.service(), first = f.send(service, "Before Clear")
            try await gate.waitForArrival()
            try await f.files.eventually { await MainActor.run { service.messages.last?.content == "Partial answer." } }
            service.stopGenerating(); _ = await first.value
            #expect(service.clearMessages())
            #expect(service.messages.isEmpty)
            let second = f.send(service, "After Clear")
            try await f.files.eventually { await MainActor.run { service.messages.last?.content == "Partial answer." } }
            service.stopGenerating(); _ = await second.value
            try f.registry.captureDidClose(f.files.identity)
            try f.entry.artifacts.bind(to: f.files.audio)
            #expect(!f.entry.artifacts.isDurable)
            await gate.release(); try await f.entry.artifacts.flush()
            let restored = try await f.recover()
            #expect(restored.chat?.messages.count == 2)
            #expect(restored.chat?.messages.first?.content == "After Clear")
            #expect(restored.chat?.messages.last?.basis == service.messages.last?.basis)
            #expect(restored.audioURL == f.files.audio)
            #expect(f.entry.artifacts.acceptedChatRevision == f.entry.artifacts.durableChatRevision)
        }
    }

    @Test(arguments: ["corrupt", "unsupported", "foreign", "oversized"])
    func unreadableOwnedHistoryBlocksSendAndClearWithoutOverwriting(mode: String) async throws {
        try await withFixture { f in
            try FileManager.default.createDirectory(at: f.files.session, withIntermediateDirectories: true)
            let url = f.files.session.appendingPathComponent("chat.json")
            var history = f.files.history("Keep this unknown conversation")
            history.identity = mode == "foreign" ? .init(recordingID: UUID(), captureSessionID: UUID()) : f.files.identity
            history.revision = 9
            if mode == "unsupported" { history.version = ChatHistory.currentVersion + 1 }
            if mode == "oversized" { history.messages = [.init(role: .user, content: String(repeating: "x", count: 600_000))] }
            let bytes = mode == "corrupt" ? Data("{".utf8) : try JSONEncoder().encode(history)
            try bytes.write(to: url)
            let service = f.service()
            #expect(await service.send("Cannot overwrite") == .notAccepted)
            #expect(!service.clearMessages())
            #expect(service.historySaveNotice != nil)
            #expect(OwnedChatProtocol.requests.count == 0 && service.messages.isEmpty)
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func failedSaveStaysDirtyUntilExplicitRetryDurablySavesTheNewestConversation() async throws {
        let fault = LiveArtifactFault(stage: .sourceChat)
        try await withFixture(fault: fault) { f in
            let service = f.service(), send = f.send(service, "Question")
            try await f.files.eventually { await MainActor.run { f.entry.artifacts.failure != nil } }
            try await f.files.eventually { await MainActor.run { service.messages.last?.content == "Partial answer." } }
            service.stopGenerating(); _ = await send.value
            #expect(!f.entry.artifacts.isDurable && service.historySaveNotice != nil)
            #expect(!service.canEvictFromCache)
            await service.retryHistorySave()
            try await f.entry.artifacts.flush()
            #expect(try await f.recover().chat?.messages == service.messages)
            #expect(f.entry.artifacts.acceptedChatRevision == f.entry.artifacts.durableChatRevision)
            #expect(service.historySaveNotice == nil)
        }
    }

    @Test func stoppedCancellationIgnoringProviderRetainsOnlyOneProducerUntilActualReturn() async throws {
        let gate = LiveArtifactGate(stage: .sourceChat)
        try await withFixture { f in
            f.cleanupGates.append(gate)
            // Attached requests use actual original ownership; the held
            // custom provider declares that authority before its first await.
            let snapshot = try f.entry.artifacts.legacyContext()
            let provider = TranscriptContextProvider {
                .init(ownership: snapshot.contextOwnership, snapshot: { try await gate.enter(.sourceChat); return snapshot })
            }
            let service = f.service(provider: provider), first = f.send(service, "Held question")
            try await gate.waitForArrival()
            service.stopGenerating()
            for _ in 0..<50 {
                #expect(await service.send("Repeated Send") == .notAccepted)
                service.stopGenerating()
            }
            #expect(OwnedChatProtocol.requests.count == 0 && service.messages.isEmpty)
            await gate.release(); _ = await first.value
            let second = f.send(service, "After actual return")
            try await f.files.eventually { await MainActor.run { service.messages.last?.content == "Partial answer." } }
            service.stopGenerating(); _ = await second.value
            try await f.entry.artifacts.flush()
        }
    }

    @Test func recordingIdentityAndBothAudioAliasesReuseOneCachedChat() async throws {
        try await withFixture { f in
            let service = f.service(), cache = TranscriptChatStore()
            let original = f.files.root.appendingPathComponent("capture.caf")
            cache.set(service, for: f.files.identity.recordingID, url: original)
            cache.set(service, for: f.files.identity.recordingID, url: f.files.audio)
            #expect(cache.session(for: original) === service)
            #expect(cache.session(for: f.files.audio) === service)
            #expect(cache.session(for: f.files.identity.recordingID, url: f.files.audio) === service)
            cache.remove(for: f.files.identity.recordingID)
            #expect(cache.session(for: original) == nil && cache.session(for: f.files.audio) == nil)
        }
    }

    @Test func aStoppedActualRemoteProducerAndASecondServiceCannotReuseTheOwnerBeforeReturn() async throws {
        try await withFixture { f in
            let gate = LiveArtifactGate(stage: .sourceChat); f.cleanupGates.append(gate)
            let service = f.service(returnGate: gate), first = f.send(service, "First answer")
            try await f.files.eventually { await MainActor.run { service.messages.last?.content == "Partial answer." } }
            service.stopGenerating(); try await gate.waitForArrival()
            try f.registry.captureDidClose(f.files.identity)
            try await f.entry.artifacts.flush()
            #expect(!f.entry.artifacts.canEvict)
            for _ in 0..<10 { #expect(await service.send("Still returning") == .notAccepted) }
            let duplicate = f.service()
            #expect(await duplicate.send("Foreign service") == .notAccepted)
            #expect(!duplicate.clearMessages())
            #expect(OwnedChatProtocol.requests.count == 1)
            let saved = try await f.recover().chat
            #expect(saved?.messages.last?.outcome == .interrupted)
            await gate.release(); _ = await first.value
            let second = f.send(service, "After producer return")
            try await f.files.eventually { await MainActor.run { service.messages.count == 4 && service.messages.last?.content == "Partial answer." } }
            service.stopGenerating(); _ = await second.value
        }
    }

    @Test func clearRetiresAnIdlePartialTimerAndTheNextStreamingPartialSavesBeforeStop() async throws {
        try await withFixture { f in
            let service = f.service(), first = f.send(service, "Before idle timer")
            try await f.files.eventually { await MainActor.run { service.messages.last?.content == "Partial answer." } }
            service.stopGenerating(); _ = await first.value
            service.persistNow()
            #expect(service.clearMessages())
            let second = f.send(service, "After idle timer Clear")
            try await f.files.eventually {
                let saved = try? await f.recover().chat
                return saved?.messages.first?.content == "After idle timer Clear" && saved?.messages.last?.content == "Partial answer."
            }
            #expect(service.isStreaming)
            service.stopGenerating(); _ = await second.value
        }
    }

    @Test func stoppedLocalHelperAndPrivacyForwarderKeepTheOwnerUntilTheActualTerminalFrame() async throws {
        try await withFixture { f in
            let flag = f.files.root.appendingPathComponent("helper-return")
            f.cleanupFiles.append(flag)
            let connection = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                supportBase: f.files.root, environment: ["STUB_MODE": "chat-across-live-stop", "STUB_FLAG_1": flag.path])
            f.connections.append(connection)
            f.settings.aiEngine = .qwenLocal
            let service = f.service(plugin: LocalAIPluginService(connection: connection))
            let send = f.send(service, "Local held answer")
            try await f.files.eventually { await MainActor.run { service.messages.last?.content == "Fixture started" } }
            service.stopGenerating()
            try f.registry.captureDidClose(f.files.identity); try await f.entry.artifacts.flush()
            #expect(!f.entry.artifacts.canEvict)
            for _ in 0..<10 { #expect(await service.send("Still in helper") == .notAccepted) }
            #expect(try await f.recover().chat?.messages.last?.outcome == .interrupted)
            try Data().write(to: flag); _ = await send.value
            #expect(await service.send("After actual helper return") == .accepted)
            #expect(service.messages.first?.content == "Local held answer")
        }
    }

    @Test func aCapacityRejectedPartialStopsConsumptionAndRetriesItsLimitedPrefixAfterBinding() async throws {
        let gate = LiveArtifactGate(stage: .sourceChat)
        try await withFixture(gates: [gate]) { f in
            let service = f.service(), send = f.send(service, "Question")
            try await gate.waitForArrival()
            try await f.files.eventually { await MainActor.run { service.messages.last?.content == "Partial answer." } }
            try f.entry.artifacts.appendLegacy([.init(start: 1, end: 2, text: String(repeating: "x", count: 50_000))])
            try f.registry.captureDidClose(f.files.identity)
            try f.entry.artifacts.bind(to: f.files.audio)
            let flush = Task { try? await f.entry.artifacts.flush() }; f.operations.append(flush)
            try await f.files.eventually { await MainActor.run { !service.isStreaming && service.historySaveNotice != nil } }
            _ = await send.value
            #expect(service.messages.last?.content == "Partial answer." && service.messages.last?.outcome == .limited)
            try await f.files.eventually { await MainActor.run { f.cancelledRequestCount == 1 } }
            #expect(f.cancelledRequestCount == 1)
            #expect(!f.entry.artifacts.isDurable)
            await gate.release(); _ = await flush.value
            let preserved = service.messages, beforeRetry = f.send(service, "Send before Retry")
            for _ in 0..<1_000 { await Task.yield() }
            #expect(service.messages == preserved)
            service.stopGenerating()
            #expect(await beforeRetry.value == .notAccepted)
            await service.retryHistorySave()
            let restored = try await f.recover()
            #expect(restored.audioURL == f.files.audio)
            #expect(restored.chat?.messages == service.messages)
            #expect(restored.chat?.messages.last?.outcome == .limited)
        }
    }

    @Test(arguments: ["crlf", "cr", "invalid-utf8"])
    func boundedRemoteSSEPreservesLineEndingsAndRejectsInvalidText(mode: String) async throws {
        try await withFixture { f in
            OwnedChatProtocol.responses.set(mode)
            let service = f.service()
            #expect(await service.send("SSE terminal framing") == .accepted)
            try await f.entry.artifacts.flush()
            let answer = try #require(try await f.recover().chat?.messages.last)
            if mode == "invalid-utf8" {
                #expect(answer.outcome == .unconfirmed)
                #expect(answer.content.isEmpty)
            } else {
                #expect(answer.outcome == .completed)
                #expect(answer.content == "Partial answer.")
            }
        }
    }

    @Test(arguments: ["chat-prefix-bound", "chat-pipe-flood"])
    func ownedLocalPipeRejectsRawOverflowBeforeDecodeAndJoinsExitAndIngestion(mode: String) async throws {
        try await withFixture { f in
            let flag = f.files.root.appendingPathComponent("raw-helper-exit")
            let gate = LiveArtifactGate(stage: .sourceChat)
            f.cleanupFiles.append(flag); f.cleanupGates.append(gate)
            let connection = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                supportBase: f.files.root, environment: ["STUB_MODE": mode, "STUB_FLAG_1": flag.path],
                boundedIngestDelivery: { if mode == "chat-pipe-flood" { _ = try? await gate.enter(.sourceChat) } })
            f.connections.append(connection)
            let run = await connection.startStream(.chatStream(systemPrompt: "Fixture", userMessage: "Raw pipe bound"), bounded: true)
            f.trackRun(run)
            if mode == "chat-pipe-flood" { try await gate.waitForArrival() }
            var received = 0
            do {
                for try await chunk in run.stream { received += chunk.utf8.count }
                Issue.record("Raw helper overflow must report an incomplete result")
            } catch { #expect(ChatStreamEndError.classify(error) == .limited) }
            #expect(received == 0)
            let returned = OwnedChatCounter()
            let join = Task { await run.waitForReturn(); returned.add() }; f.joins.append(join)
            for _ in 0..<1_000 { await Task.yield() }
            #expect(returned.count == 0)
            try Data().write(to: flag)
            await gate.release(); await join.value
            #expect(returned.count == 1)
        }
    }

    @Test(arguments: ["chat-prefix-bound", "chat-pipe-flood"])
    func directOwnedLocalDefaultFlagRejectsRawOverflowAndJoinsActualExit(mode: String) async throws {
        try await withFixture { f in
            let flag = f.files.root.appendingPathComponent("raw-helper-exit")
            let gate = LiveArtifactGate(stage: .sourceChat)
            f.cleanupFiles.append(flag); f.cleanupGates.append(gate)
            let connection = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                supportBase: f.files.root, environment: ["STUB_MODE": mode, "STUB_FLAG_1": flag.path],
                boundedIngestDelivery: { if mode == "chat-pipe-flood" { _ = try? await gate.enter(.sourceChat) } })
            f.connections.append(connection)
            let value = try f.entry.artifacts.legacyContext()
            let run = await connection.startStream(.chatStream(systemPrompt: "Fixture", userMessage: "Raw pipe bound"), ownership: value.contextOwnership)
            f.trackRun(run)
            if mode == "chat-pipe-flood" { try await gate.waitForArrival() }
            var received = 0
            do {
                for try await chunk in run.stream { received += chunk.utf8.count }
                Issue.record("Raw helper overflow must report an incomplete result")
            } catch { #expect(ChatStreamEndError.classify(error) == .limited) }
            #expect(received == 0)
            let returned = OwnedChatCounter()
            let join = Task { await run.waitForReturn(); returned.add() }; f.joins.append(join)
            for _ in 0..<1_000 { await Task.yield() }
            #expect(returned.count == 0)
            try Data().write(to: flag)
            await gate.release(); await join.value
            #expect(returned.count == 1)
        }
    }

    @Test func ownedPipeModeChangesOnlyAfterIdleRetirementAndPreservesLargeLegacyResults() async throws {
        try await withFixture { f in
            let connection = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                supportBase: f.files.root, environment: ["STUB_MODE": "chat-transport-compatibility"])
            f.connections.append(connection)
            let request = MLRequest.transcribe(path: "/fixture.caf", initialPrompt: nil, config: .default, safeMode: false, unloadAfter: true)
            let before = try await connection.call(request)
            if case .transcriptionResult(let value) = before { #expect(value.text.utf8.count == 70_000) }
            else { Issue.record("Expected a large legacy result") }
            let run = await connection.startStream(.chatStream(systemPrompt: "Fixture", userMessage: "Bounded chat"), bounded: true)
            f.trackRun(run)
            var answer = ""
            for try await chunk in run.stream { answer += chunk }
            await run.waitForReturn(); #expect(answer == "Bounded answer")
            let after = try await connection.call(request)
            if case .transcriptionResult(let value) = after { #expect(value.text.utf8.count == 70_000) }
            else { Issue.record("Expected preserved legacy framing after owned chat") }
        }
    }

    @Test(arguments: [false, true])
    func backgroundTranscriptionWaitsAcrossOwnedChatStopAndRemainsCancellable(cancel: Bool) async throws {
        try await withFixture { f in
            let flag = f.files.root.appendingPathComponent("background-chat-return"); f.cleanupFiles.append(flag)
            let connection = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                supportBase: f.files.root, environment: ["STUB_MODE": "chat-background-serialization", "STUB_FLAG_1": flag.path])
            f.connections.append(connection); f.settings.aiEngine = .qwenLocal
            let service = f.service(plugin: LocalAIPluginService(connection: connection)), send = f.send(service, "Held chat")
            try await f.files.eventually { await MainActor.run { service.messages.last?.content == "Fixture started" } }
            service.stopGenerating()
            let completed = OwnedChatCounter()
            let background = Task { () -> Result<MLEvent, any Error> in
                defer { completed.add() }
                do { return .success(try await connection.call(.transcribe(path: "/fixture.caf", initialPrompt: nil,
                    config: .default, safeMode: false, unloadAfter: true))) }
                catch { return .failure(error) }
            }
            f.joins.append(Task { _ = await background.value })
            for _ in 0..<1_000 { await Task.yield() }
            #expect(completed.count == 0)
            if cancel {
                background.cancel()
                if case .failure(let error) = await background.value { #expect(error is CancellationError) }
                else { Issue.record("A cancelled background waiter must not dispatch") }
            }
            try Data().write(to: flag); _ = await send.value
            if !cancel {
                if case .success(.transcriptionResult(let value)) = await background.value {
                    #expect(value.text == "Background finalized transcript")
                } else { Issue.record("Background transcription should resume after owned chat returns") }
            }
        }
    }

    @Test func naturalHelperExitCannotReplaceAHeldOldReaderWithAnotherFramingMode() async throws {
        try await withFixture { f in
            let flag = f.files.root.appendingPathComponent("natural-helper-launches")
            let gate = LiveArtifactGate(stage: .sourceChat), exited = OwnedChatCounter(), completed = OwnedChatCounter()
            f.cleanupFiles.append(flag); f.cleanupGates.append(gate)
            let connection = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                supportBase: f.files.root, environment: ["STUB_MODE": "chat-natural-exit-reader", "STUB_FLAG_1": flag.path],
                terminationDelivery: { exited.add() }, boundedIngestDelivery: { _ = try? await gate.enter(.sourceChat) })
            f.connections.append(connection)
            let run = await connection.startStream(.chatStream(systemPrompt: "Fixture", userMessage: "Natural exit"), bounded: true)
            f.trackRun(run); try await gate.waitForArrival()
            try await f.files.eventually { exited.count == 1 }
            let background = Task { () -> Result<MLEvent, any Error> in
                defer { completed.add() }
                do { return .success(try await connection.call(.transcribe(path: "/fixture.caf", initialPrompt: nil,
                    config: .default, safeMode: false, unloadAfter: true))) }
                catch { return .failure(error) }
            }
            f.joins.append(Task { _ = await background.value })
            for _ in 0..<1_000 { await Task.yield() }
            #expect(completed.count == 0)
            #expect(try String(contentsOf: flag, encoding: .utf8) == "1")
            await gate.release(); await run.waitForReturn()
            if case .success(.transcriptionResult(let value)) = await background.value { #expect(value.text == "Legacy replacement") }
            else { Issue.record("Replacement should dispatch after the old reader actually returns") }
        }
    }

    @Test func backgroundModeWaitersHaveAFiniteLimitAndCancellationRestoresAdmission() async throws {
        try await withFixture { f in
            let flag = f.files.root.appendingPathComponent("bounded-background-return"); f.cleanupFiles.append(flag)
            let connection = MLHostConnection(binaryURL: URL(fileURLWithPath: ".build/debug/dBriefMLHostStub"),
                supportBase: f.files.root, environment: ["STUB_MODE": "chat-background-serialization", "STUB_FLAG_1": flag.path])
            f.connections.append(connection)
            let run = await connection.startStream(.chatStream(systemPrompt: "Fixture", userMessage: "Hold bounded mode"), bounded: true)
            f.trackRun(run)
            var iterator = run.stream.makeAsyncIterator()
            #expect(try await iterator.next() == "Fixture started")
            let request = MLRequest.transcribe(path: "/fixture.caf", initialPrompt: nil, config: .default, safeMode: false, unloadAfter: true)
            func start() -> Task<Result<MLEvent, any Error>, Never> {
                Task { do { return .success(try await connection.call(request)) } catch { return .failure(error) } }
            }
            let accepted = (0..<128).map { _ in start() }
            f.joins.append(Task { for task in accepted { _ = await task.value } })
            try await f.files.eventually { await connection.ordinaryModeWaiterCount == 128 }
            let extra = start(); f.joins.append(Task { _ = await extra.value })
            for _ in 0..<1_000 { await Task.yield() }
            #expect(await connection.ordinaryModeWaiterCount == 128)
            extra.cancel()
            if case .failure(let error) = await extra.value { #expect(error as? MLHostError == .resourceDeferred) }
            else { Issue.record("Excess background waiter should defer before retention") }
            for task in accepted.dropFirst() { task.cancel() }
            for task in accepted.dropFirst() {
                if case .failure(let error) = await task.value { #expect(error is CancellationError) }
                else { Issue.record("Cancelled mode waiter must not dispatch") }
            }
            #expect(await connection.ordinaryModeWaiterCount == 1)
            let replacement = start(); f.joins.append(Task { _ = await replacement.value })
            try await f.files.eventually { await connection.ordinaryModeWaiterCount == 2 }
            replacement.cancel(); _ = await replacement.value
            try Data().write(to: flag); await run.waitForReturn()
            if case .success(.transcriptionResult(let value)) = await accepted[0].value { #expect(value.text == "Background finalized transcript") }
            else { Issue.record("Admitted background work should still resume") }
            #expect(await connection.ordinaryModeWaiterCount == 0)
        }
    }

    @Test func stopDuringFailureHandlingStillJoinsTheActualProducerReturn() async throws {
        try await withFixture { f in
            let failureGate = LiveArtifactGate(stage: .sourceChat), returnGate = LiveArtifactGate(stage: .sourceChat)
            f.cleanupGates += [failureGate, returnGate]
            OwnedChatProtocol.responses.set("error")
            let service = f.service(returnGate: returnGate, failureGate: failureGate)
            let first = f.send(service, "Failure during Stop")
            try await failureGate.waitForArrival(); try await returnGate.waitForArrival()
            service.stopGenerating()
            try f.registry.captureDidClose(f.files.identity); try await f.entry.artifacts.flush()
            await failureGate.release()
            let second = f.send(service, "Before actual failed producer return")
            for _ in 0..<1_000 { await Task.yield() }
            #expect(OwnedChatProtocol.requests.count == 1)
            #expect(!f.entry.artifacts.canEvict)
            await returnGate.release()
            #expect(await first.value == .accepted)
            #expect(await second.value == .notAccepted)
            #expect(f.entry.artifacts.canEvict)
        }
    }

    @Test(arguments: ["oversized-line", "flood"])
    func ownedRemoteInputIsBoundedBeforeAHeldConsumerReceivesText(mode: String) async throws {
        try await withFixture { f in
            let gate = LiveArtifactGate(stage: .sourceChat); f.cleanupGates.append(gate)
            OwnedChatProtocol.responses.set(mode)
            let run = f.startBoundedStream(returnGate: gate)
            try await gate.waitForArrival()
            try await f.files.eventually { await MainActor.run { f.cancelledRequestCount == 1 } }
            var received = 0
            do {
                for try await chunk in run.stream {
                    #expect(chunk.utf8.count <= ChatStreamBuffer.chunkLimit)
                    received += chunk.utf8.count
                }
                Issue.record("Provider overflow must report an incomplete result")
            } catch { #expect(ChatStreamEndError.classify(error) == .limited) }
            #expect(received <= ChatStreamBuffer.textLimit)
            if mode == "oversized-line" { #expect(received == 0) }
            else { #expect(received > 0) }
            await gate.release(); await run.waitForReturn()
        }
    }

    @Test(arguments: ["references", "unicode", "error"])
    func terminalMetadataAndMultibyteResponsesStayWithinTheAdmittedHistory(mode: String) async throws {
        try await withFixture { f in
            try await LiveSessionArtifactStore(identity: f.files.identity, rootURL: f.files.root)
                .saveChat(f.files.history(String(repeating: "x", count: 65_000)), revision: 7)
            OwnedChatProtocol.responses.set(mode)
            let service = f.service()
            #expect(await service.send("Question") == .accepted)
            try await f.entry.artifacts.flush()
            let history = try #require(try await f.recover().chat)
            _ = try LiveArtifactEncoding.estimatedBytes(history, limit: LiveRecordingArtifactOwner.chatHistoryLimit)
            #expect(history.messages.first?.content.utf8.count == 65_000)
            #expect(history.messages.last?.basis != nil)
            if mode == "error" {
                #expect(history.messages.last?.content.isEmpty == true)
                #expect(history.messages.last?.outcome == .failed)
                #expect((service.streamingError?.utf8.count ?? 0) <= 4_096)
            } else {
                #expect(history.messages.last?.outcome == .limited)
                #expect((history.messages.last?.content.utf8.count ?? 0) < 60_000)
                if mode == "references" { #expect(history.messages.last?.referenceResolution?.references.count == 1) }
            }
        }
    }

    private func withFixture(gates: [LiveArtifactGate] = [], fault: LiveArtifactFault? = nil,
        body: @MainActor (OwnedChatFixture) async throws -> Void) async throws {
        let fixture = try OwnedChatFixture(gates: gates, fault: fault)
        do { try await body(fixture); await fixture.finish() }
        catch { await fixture.finish(); throw error }
    }
}

@MainActor private final class OwnedChatFixture {
    let files: LiveArtifactFixture
    let registry: LiveRecordingSessionRegistry
    let entry: LiveRecordingSessionRegistry.Entry
    let settings = AppSettings()
    private let saved: OwnedChatSettings
    fileprivate let session: URLSession
    fileprivate var services: [TranscriptChatService] = []
    fileprivate var sends: [Task<TranscriptChatSendResult, Never>] = []
    private var runs: [ChatStreamRun] = []
    var joins: [Task<Void, Never>] = []
    private let requestID = UUID().uuidString
    var cancelledRequestCount: Int { OwnedChatProtocol.stops.count(for: requestID) }
    var operations: [Task<Void?, Never>] = []
    var cleanupFiles: [URL] = []
    var connections: [MLHostConnection] = []
    var cleanupGates: [LiveArtifactGate]
    init(gates: [LiveArtifactGate], fault: LiveArtifactFault?) throws {
        files = try LiveArtifactFixture(); saved = OwnedChatSettings(settings); cleanupGates = gates
        registry = LiveRecordingSessionRegistry(artifactRoot: files.root, beforeStage: { stage in
            for gate in gates { try await gate.enter(stage) }
            try await fault?.check(stage)
        })
        entry = try registry.registerLegacy(files.identity)
        try entry.artifacts.appendLegacy([.init(start: 0, end: 1, text: "Original committed evidence")])
        settings.aiEngine = .remoteEndpoint
        settings.aiEndpoints = [.init(name: "Owned chat fixture", baseURL: "https://owned-chat.invalid/\(requestID)", modelName: "fixture")]
        settings.defaultAIEndpointId = settings.aiEndpoints[0].id
        for index in settings.profiles.indices {
            settings.profiles[index].overrides.aiEngine = nil; settings.profiles[index].overrides.aiEndpointId = nil
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OwnedChatProtocol.self]
        session = URLSession(configuration: configuration); OwnedChatProtocol.requests.reset()
        OwnedChatProtocol.responses.set("partial")
    }
    func service(provider: TranscriptContextProvider? = nil, returnGate: LiveArtifactGate? = nil,
        failureGate: LiveArtifactGate? = nil, plugin: LocalAIPluginService? = nil) -> TranscriptChatService {
        registry.startPersistence(files.identity)
        let service = TranscriptChatService(contextProvider: provider ?? .recording(recordingID: files.identity.recordingID,
            registry: registry, legacy: { .legacy(text: "Unexpected fallback", recordingID: self.files.identity.recordingID, speakerLabels: []) }),
            appSettings: settings, localPlugin: plugin, aiService: AIService(session: session,
                beforeChatProducerReturn: { _ = try? await returnGate?.enter(.sourceChat) }),
            beforeStreamFailureHandling: { _ = try? await failureGate?.enter(.sourceChat) })
        service.enableRecordingPersistence(owner: entry.artifacts)
        services.append(service); return service
    }
    func legacyService() -> TranscriptChatService {
        let service = TranscriptChatService(transcriptText: "Legacy source", speakerLabels: [], appSettings: settings,
            localPlugin: nil, aiService: AIService(session: session))
        services.append(service); return service
    }
    func startBoundedStream(returnGate: LiveArtifactGate) -> ChatStreamRun {
        let run = AIService(session: session, beforeChatProducerReturn: { _ = try? await returnGate.enter(.sourceChat) })
            .startChat(systemPrompt: "Fixture", userMessage: "Bounded input", endpoint: settings.aiEndpoints[0], bounded: true)
        runs.append(run); return run
    }
    func trackRun(_ run: ChatStreamRun) { runs.append(run) }
    func send(_ service: TranscriptChatService, _ question: String) -> Task<TranscriptChatSendResult, Never> {
        let task = Task { await service.send(question) }; sends.append(task); return task
    }
    func recover() async throws -> LiveSessionArtifactStore.Restored {
        try await LiveSessionArtifactStore(identity: files.identity, rootURL: files.root).recover()
    }
    func finish() async {
        for service in services { service.stopGenerating(); service.invalidateForReprocessing() }
        for gate in cleanupGates { await gate.release() }
        for file in cleanupFiles { try? Data().write(to: file) }
        for send in sends { send.cancel(); _ = await send.value }
        for run in runs { run.cancel(); await run.waitForReturn() }
        for join in joins { await join.value }
        for operation in operations { _ = await operation.value }
        for connection in connections { await connection.shutdown(); await connection.waitForShutdown() }
        try? registry.retire(files.identity); await entry.artifacts.waitForSubmittedWrites()
        session.invalidateAndCancel(); saved.restore(settings); files.remove()
    }
}

private struct OwnedChatSettings {
    let engine: AppSettings.AIEngine, endpoints: [Endpoint], endpoint: UUID?, profiles: [MeetingProfile]
    @MainActor init(_ settings: AppSettings) {
        engine = settings.aiEngine; endpoints = settings.aiEndpoints
        endpoint = settings.defaultAIEndpointId; profiles = settings.profiles
    }
    @MainActor func restore(_ settings: AppSettings) {
        settings.aiEngine = engine; settings.aiEndpoints = endpoints
        settings.defaultAIEndpointId = endpoint; settings.profiles = profiles
    }
}
private final class OwnedChatProtocol: URLProtocol, @unchecked Sendable {
    static let requests = OwnedChatCounter()
    static let stops = OwnedChatStops()
    static let responses = OwnedChatResponses()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "owned-chat.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.add()
        let mode = Self.responses.value
        if mode == "error" {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "OwnedChatFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(repeating: "e", count: 600_000)]))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        if mode == "flood" || mode == "flood-finite" {
            let payload = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": String(repeating: "x", count: 8_192)]]]])
            let frame = Data("data: ".utf8) + payload + Data("\n\n".utf8)
            for _ in 0..<64 { client?.urlProtocol(self, didLoad: frame) }
            if mode == "flood-finite" {
                client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        if mode == "invalid-utf8" {
            client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"".utf8)
                + Data([0xFF]) + Data("\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
            client?.urlProtocolDidFinishLoading(self); return
        }
        var content = "Partial answer."
        if mode == "oversized-line" || mode == "oversized-finite" { content = String(repeating: "x", count: ChatStreamBuffer.lineLimit + 1) }
        if mode == "unicode" { content = String(repeating: "e\u{301}", count: 70_000) }
        if mode == "references" {
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; bytes.append(buffer, count: count)
                }
            }
            let body = String(decoding: bytes, as: UTF8.self)
            let pattern = try! NSRegularExpression(pattern: #"\[EVIDENCE ([^\]]+)\]"#)
            if let match = pattern.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
               let range = Range(match.range(at: 1), in: body) { content = "[[ref:\(body[range])]] " }
            content += String(repeating: "x", count: 60_000)
        }
        let payload = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": content]]]])
        let newline = mode == "crlf" ? "\r\n" : mode == "cr" ? "\r" : "\n"
        client?.urlProtocol(self, didLoad: Data("data: ".utf8) + payload + Data((newline + newline).utf8))
        if mode != "partial" && mode != "oversized-line" {
            client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\(newline)\(newline)data: [DONE]\(newline)\(newline)".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        if let id = request.url?.pathComponents.dropFirst().first { Self.stops.add(id) }
    }
}
private final class OwnedChatStops: @unchecked Sendable {
    private let lock = NSLock(); private var counts: [String: Int] = [:]
    func count(for id: String) -> Int { lock.withLock { counts[id, default: 0] } }
    func add(_ id: String) { lock.withLock { counts[id, default: 0] += 1 } }
}
private final class OwnedChatResponses: @unchecked Sendable {
    private let lock = NSLock(); private var mode = "partial"
    var value: String { lock.withLock { mode } }
    func set(_ mode: String) { lock.withLock { self.mode = mode } }
}
private final class OwnedChatCounter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
    func reset() { lock.withLock { value = 0 } }
}
