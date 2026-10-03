import CoreML
import CryptoKit
import Darwin
import Foundation
import Testing
import dBriefWire
@testable import dBriefMLHost

struct VADLoadFixture: Sendable {
    static let inputs = ["audio_input":[1,4160],"hidden_state":[1,128],"cell_state":[1,128]]
    static let outputs = ["vad_output":[1,1,1],"new_hidden_state":[1,128],"new_cell_state":[1,128]]
    let root: URL
    let source: URL
    let staging: URL
    let metadata: Data
    let configuration: LiveVADConfiguration
    static var description: LiveVADModelContract.Description {
        .init(inputs: inputs.map { .init(name: $0.key,shape: $0.value) },outputs: outputs.map { .init(name: $0.key,shape: $0.value) })
    }
    init(metadata supplied: Data? = nil, compute: LiveVADIdentity.ComputeUnits = .cpuOnly) throws {
        func features(_ map: [String: [Int]]) -> [[String: Any]] {
            map.keys.sorted().map { ["name":$0,"type":"MultiArray","dataType":"Float32","isOptional":"0","hasShapeFlexibility":"0",
                "shape":String(data: try! JSONEncoder().encode(map[$0]!),encoding: .utf8)!] }
        }
        metadata = try supplied ?? JSONSerialization.data(withJSONObject: [["metadataOutputVersion":"3.0","version":"6.2.1",
            "modelType":["name":"MLModelType_mlProgram"],"method":"predict","isUpdatable":"0","stateSchema":[],
            "inputSchema":features(Self.inputs),"outputSchema":features(Self.outputs)]],options: [.sortedKeys])
        root = URL(fileURLWithPath: "/private/tmp/vad-load-fixture-\(UUID())",isDirectory: true)
        source = root.appendingPathComponent("original.mlmodelc"); staging = root.appendingPathComponent("staging")
        let files = ["metadata.json":metadata,"model.mil":Data("fixture".utf8),"coremldata.bin":Data("core".utf8),
            "analytics/coremldata.bin":Data("analytics".utf8),"weights/weight.bin":Data([1,2,3])]
        try FileManager.default.createDirectory(at: staging,withIntermediateDirectories: true,attributes: [.posixPermissions:0o700])
        for (path,data) in files {
            let file = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),withIntermediateDirectories: true)
            try data.write(to: file)
        }
        // Fixture manifest only; production must verify copied bytes itself.
        var hash = SHA256(); hash.update(data: Data("dBrief.VADAssets.v1\0".utf8))
        for path in (Array(files.keys)+["analytics","weights"]).sorted() {
            let data = files[path], encodedPath = Data(path.utf8)
            hash.update(data: Data([data == nil ? 0 : 1]))
            var length = UInt32(encodedPath.count).littleEndian, size = UInt64(data?.count ?? 0).littleEndian
            withUnsafeBytes(of: &length) { hash.update(bufferPointer: $0) }; hash.update(data: encodedPath)
            withUnsafeBytes(of: &size) { hash.update(bufferPointer: $0) }
            if let data { hash.update(data: Data(SHA256.hash(data: data))) }
        }
        configuration = .init(identity: .init(modelRevision: "silero-vad-unified-256ms-v6.2.1",
            modelFingerprint: hash.finalize().map { String(format: "%02x",$0) }.joined(),
            runtimeRevision: LiveVADNativeConfiguration.runtimeRevision,computeUnits: compute),modelPath: source.path)
    }
    func assets() async throws -> LiveVADModelAssets { try await .prepare(configuration,testingStagingDirectory: staging) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    var staged: [String] { (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [] }
}

private final class VADLoadAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    private weak var weakAsset: LiveVADModelAssets?
    private weak var weakHandle: VADLoadHandle?
    private var releaseWasOwned = false
    func call() -> Int { lock.withLock { stored += 1; return stored } }
    var calls: Int { lock.withLock { stored } }
    func observe(_ asset: LiveVADModelAssets) { lock.withLock { weakAsset = asset } }
    func observe(_ handle: VADLoadHandle) { lock.withLock { weakHandle = handle } }
    var assetAlive: Bool { lock.withLock { weakAsset != nil } }
    var handleAlive: Bool { lock.withLock { weakHandle != nil } }
    func released(path: URL) { lock.withLock { releaseWasOwned = weakAsset != nil && FileManager.default.fileExists(atPath: path.path) } }
    var releasedWhileOwned: Bool { lock.withLock { releaseWasOwned } }
}
private final class VADLoadModel: LiveVADModelObject, Sendable {
    let assets: LiveVADModelAssets
    let audit: VADLoadAudit
    let path: URL
    init(assets: LiveVADModelAssets, audit: VADLoadAudit, path: URL) { self.assets = assets; self.audit = audit; self.path = path }
    func validate(_ contract: LiveVADModelContract) throws { try contract.validate(VADLoadFixture.description) }
    func predict(_ input: LiveVADNativeInput) throws -> LiveVADNativeOutput { throw LiveVADModelError.invalidModel }
    deinit { audit.released(path: path) }
}
private final class VADLoadHandle: LiveVADModelHandle, Sendable {
    let assets: LiveVADModelAssets
    let description: LiveVADModelContract.Description
    let entered: LifetimeSignal?
    let release: LifetimeSignal?
    init(_ assets: LiveVADModelAssets, description: LiveVADModelContract.Description = VADLoadFixture.description,
         entered: LifetimeSignal? = nil, release: LifetimeSignal? = nil) {
        self.assets = assets; self.description = description; self.entered = entered; self.release = release
    }
    func validate(_ contract: LiveVADModelContract) async throws {
        await entered?.signal(); await release?.wait()
        try contract.validate(description)
    }
    func predict(_ input: LiveVADNativeInput) async throws -> LiveVADNativeOutput { throw LiveVADModelError.invalidModel }
}

@Suite struct LiveVADModelFactoryTests {
    @Test func copiedMetadataAndCompleteFrozenConfigurationAreRetained() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let assets = try await f.assets()
        #expect(assets.configuration == f.configuration)
        #expect(try assets.readMetadata() == f.metadata)
        try FileManager.default.removeItem(at: f.source)
        #expect(try assets.readMetadata() == f.metadata)
    }

    @Test(arguments: ["oversized","invalid-schema"])
    func invalidCopiedMetadataNeverInvokesALoader(mode: String) async throws {
        let f = try VADLoadFixture(metadata: mode == "oversized" ? Data(repeating: 0x20,count: 65_537) : Data("{}".utf8))
        defer { f.cleanup() }
        let assets = try await f.assets(), audit = VADLoadAudit()
        await #expect(throws: LiveVADModelError.invalidModel) {
            _ = try await LiveVADModelFactory.load(configuration: f.configuration,sources: [.microphone],assets: assets,loader: { owner,_ in
                _ = audit.call(); return VADLoadHandle(owner)
            })
        }
        #expect(audit.calls == 0)
    }

    @Test func sameInodeMetadataMutationCannotReplaceTheVerifiedWitness() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let assets = try await f.assets(), path = try assets.modelDirectory.appendingPathComponent("metadata.json").path
        #expect(chmod(path,0o600) == 0)
        let fd = open(path,O_WRONLY | O_TRUNC); try #require(fd >= 0)
        let altered = Data(repeating: 0x20,count: f.metadata.count)
        #expect(altered.withUnsafeBytes { write(fd,$0.baseAddress!, $0.count) } == altered.count)
        #expect(fchmod(fd,0o444) == 0); close(fd)
        #expect(throws: LiveVADAssetError.fingerprintMismatch) { _ = try assets.readMetadata() }
    }

    @Test func exactMetadataLimitSucceedsButGrowthAfterStatIsBounded() async throws {
        let baseline = try VADLoadFixture(); defer { baseline.cleanup() }
        var metadata = baseline.metadata
        metadata.append(Data(repeating: 0x20,count: 65_536-metadata.count))
        let f = try VADLoadFixture(metadata: metadata); defer { f.cleanup() }
        let assets = try await f.assets()
        #expect(try assets.readMetadata() == metadata)
        let audit = VADLoadAudit()
        _ = try await LiveVADModelFactory.load(configuration: f.configuration,sources: [.microphone],assets: assets,loader: { owner,_ in
            _ = audit.call(); return VADLoadHandle(owner)
        })
        #expect(audit.calls == 1)
        let path = try assets.modelDirectory.appendingPathComponent("metadata.json").path
        #expect(throws: LiveVADModelError.invalidModel) {
            _ = try assets.readMetadata(testingAfterOpen: {
                #expect(chmod(path,0o600) == 0)
                let fd = open(path,O_WRONLY | O_APPEND); try #require(fd >= 0)
                defer { _ = fchmod(fd,0o444); close(fd) }
                var byte: UInt8 = 0x20
                #expect(write(fd,&byte,1) == 1)
            })
        }
    }

    @Test(arguments: ["path","compute","policy","empty","duplicate","final-mix","too-many"])
    func configurationAndSourceMismatchNeverLoads(mode: String) async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let assets = try await f.assets(), audit = VADLoadAudit()
        var config = f.configuration, sources: [LiveSource] = [.microphone]
        if mode == "path" { config = .init(identity: config.identity,modelPath: "/elsewhere/model.mlmodelc") }
        if mode == "compute" || mode == "policy" {
            let original = config.identity
            config = .init(identity: .init(modelRevision: original.modelRevision,modelFingerprint: original.modelFingerprint,
                runtimeRevision: original.runtimeRevision,computeUnits: mode == "compute" ? .all : original.computeUnits,
                minSilenceSamples: mode == "policy" ? 4096 : original.minSilenceSamples),modelPath: config.modelPath)
        }
        if mode == "empty" { sources = [] }
        if mode == "duplicate" { sources = [.microphone,.microphone] }
        if mode == "final-mix" { sources = [.finalMix] }
        if mode == "too-many" { sources = [.microphone,.system,.finalMix] }
        await #expect(throws: LiveProtocolError.invalidConfiguration) {
            _ = try await LiveVADModelFactory.load(configuration: config,sources: sources,assets: assets,loader: { owner,_ in
                _ = audit.call(); return VADLoadHandle(owner)
            })
        }
        #expect(audit.calls == 0)
    }

    @Test func serialSourceLoadsUseFrozenComputeAndDistinctOwnedHandles() async throws {
        let f = try VADLoadFixture(compute: .all); defer { f.cleanup() }
        let assets = try await f.assets(), audit = VADLoadAudit(), entered = LifetimeSignal(), release = LifetimeSignal()
        let task = Task {
            try await LiveVADModelFactory.load(configuration: f.configuration,sources: [.microphone,.system],assets: assets,loader: { owner,config in
                #expect(owner === assets); #expect(config.vad.computeUnits == .all)
                if audit.call() == 1 { await entered.signal(); await release.wait() }
                return VADLoadHandle(owner)
            })
        }
        await entered.wait(); #expect(audit.calls == 1); await release.signal()
        let factory = try await task.value
        #expect(audit.calls == 2); #expect(Set(factory.handles.keys) == Set([.microphone,.system]))
        let microphone = try #require(factory.handles[.microphone]), system = try #require(factory.handles[.system])
        #expect(ObjectIdentifier(microphone) != ObjectIdentifier(system))
        #expect(microphone.assets === assets && system.assets === assets)
    }

    @Test func reusedHandleCannotRepresentTwoSourceModels() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let assets = try await f.assets(), handle = VADLoadHandle(assets)
        await #expect(throws: LiveVADModelError.invalidModel) {
            _ = try await LiveVADModelFactory.load(configuration: f.configuration,sources: [.microphone,.system],assets: assets,loader: { _,_ in handle })
        }
    }

    @Test func foreignSnapshotHandleIsRefused() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let assets = try await f.assets(), other = try await f.assets()
        await #expect(throws: LiveVADModelError.invalidModel) {
            _ = try await LiveVADModelFactory.load(configuration: f.configuration,sources: [.microphone],assets: assets,loader: { _,_ in VADLoadHandle(other) })
        }
    }

    @Test func canceledBeforeLoadInvokesNothing() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let assets = try await f.assets(), audit = VADLoadAudit(), start = LifetimeSignal()
        let task = Task {
            await start.wait()
            return try await LiveVADModelFactory.load(configuration: f.configuration,sources: [.microphone],assets: assets,loader: { owner,_ in
                _ = audit.call(); return VADLoadHandle(owner)
            })
        }
        task.cancel(); await start.signal()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(audit.calls == 0)
    }

    @Test func canceledIgnoringLoadRetainsSnapshotUntilRealUnwindAndNeverPublishes() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let audit = VADLoadAudit(), entered = LifetimeSignal(), release = LifetimeSignal()
        var assets: LiveVADModelAssets? = try await f.assets()
        let path = try #require(try assets?.modelDirectory); audit.observe(try #require(assets))
        let task = Task { [owner = try #require(assets)] in
            try await LiveVADModelFactory.load(configuration: f.configuration,sources: [.microphone,.system],assets: owner,loader: { held,_ in
                _ = audit.call(); await entered.signal(); await release.wait()
                return VADLoadHandle(held)
            })
        }
        assets = nil; await entered.wait(); task.cancel()
        #expect(audit.assetAlive && FileManager.default.fileExists(atPath: path.path))
        await release.signal()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(audit.calls == 1); #expect(!audit.assetAlive && f.staged.isEmpty)
    }

    @Test func cancellationDuringDescriptionValidationRejectsOneSourceFactory() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let assets = try await f.assets(), entered = LifetimeSignal(), release = LifetimeSignal()
        let task = Task {
            try await LiveVADModelFactory.load(configuration: f.configuration,sources: [.microphone],assets: assets,loader: { owner,_ in
                VADLoadHandle(owner,entered: entered,release: release)
            })
        }
        await entered.wait(); task.cancel(); await release.signal()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func ownedHandleDestroysItsModelBeforeCleaningSnapshotFiles() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let audit = VADLoadAudit()
        var assets: LiveVADModelAssets? = try await f.assets()
        let path = try #require(try assets?.modelDirectory); audit.observe(try #require(assets))
        var handle: LiveVADOwnedModelHandle? = LiveVADOwnedModelHandle(assets: try #require(assets),model: VADLoadModel(assets: try #require(assets),audit: audit,path: path))
        assets = nil
        #expect(handle != nil && audit.assetAlive)
        handle = nil
        #expect(audit.releasedWhileOwned && !audit.assetAlive && f.staged.isEmpty)
    }

    @Test func canceledQueuedDetachedLoadSkipsConstructorAndRetainsOwnerThroughProbeUnwind() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let audit = VADLoadAudit(), entered = LifetimeSignal(), release = LifetimeSignal()
        var assets: LiveVADModelAssets? = try await f.assets()
        let path = try #require(try assets?.modelDirectory); audit.observe(try #require(assets))
        let native = try LiveVADNativeConfiguration(f.configuration)
        let task = Task { [owner = try #require(assets)] in
            try await LiveVADOwnedModelHandle.load(assets: owner,configuration: native,testingBeforeConstruction: {
                await entered.signal(); await release.wait()
            },testingConstructor: { url,config in
                _ = audit.call(); #expect(config.vad.computeUnits == .cpuOnly)
                return VADLoadModel(assets: owner,audit: audit,path: url)
            })
        }
        assets = nil; await entered.wait(); task.cancel()
        #expect(audit.assetAlive && FileManager.default.fileExists(atPath: path.path))
        await release.signal()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(audit.calls == 0 && !audit.assetAlive && f.staged.isEmpty)
    }

    @Test func retainedNativeObjectKeepsSnapshotAliveAfterHandleDisposal() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let audit = VADLoadAudit()
        var assets: LiveVADModelAssets? = try await f.assets()
        let path = try #require(try assets?.modelDirectory); audit.observe(try #require(assets))
        var model: VADLoadModel? = VADLoadModel(assets: try #require(assets),audit: audit,path: path)
        var handle: LiveVADOwnedModelHandle? = LiveVADOwnedModelHandle(assets: try #require(assets),model: try #require(model))
        #expect(handle != nil)
        assets = nil; handle = nil
        withExtendedLifetime(model) {
            #expect(audit.assetAlive && !audit.releasedWhileOwned && FileManager.default.fileExists(atPath: path.path))
        }
        model = nil
        #expect(audit.releasedWhileOwned && !audit.assetAlive && f.staged.isEmpty)
    }

    @Test func canceledStartedDetachedLoadDisposesLateModelBeforeReleasingAssets() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let audit = VADLoadAudit(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var assets: LiveVADModelAssets? = try await f.assets()
        audit.observe(try #require(assets)); let path = try #require(try assets?.modelDirectory)
        let native = try LiveVADNativeConfiguration(f.configuration)
        let task = Task { [owner = try #require(assets)] in
            try await LiveVADOwnedModelHandle.load(assets: owner,configuration: native,testingConstructor: { url,_ in
                _ = audit.call(); entered.signal(); release.wait()
                return VADLoadModel(assets: owner,audit: audit,path: url)
            })
        }
        assets = nil
        defer { release.signal() }
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success) }
        }
        if !started {
            task.cancel(); release.signal()
            _ = try? await task.value
        }
        try #require(started)
        task.cancel(); #expect(audit.assetAlive && FileManager.default.fileExists(atPath: path.path))
        release.signal()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(audit.calls == 1 && audit.releasedWhileOwned && !audit.assetAlive && f.staged.isEmpty)
    }

    @Test func detachedConstructorCannotReturnAnObjectOwningAnotherSnapshot() async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let assets = try await f.assets(), other = try await f.assets(), audit = VADLoadAudit()
        await #expect(throws: LiveVADModelError.invalidModel) {
            _ = try await LiveVADOwnedModelHandle.load(assets: assets,configuration: LiveVADNativeConfiguration(f.configuration),
                testingConstructor: { url,_ in VADLoadModel(assets: other,audit: audit,path: url) })
        }
    }

    @Test(arguments: ["second-load","description"])
    func failedPartialFactoryDisposesPreviouslyLoadedHandles(mode: String) async throws {
        let f = try VADLoadFixture(); defer { f.cleanup() }
        let assets = try await f.assets(), audit = VADLoadAudit()
        await #expect(throws: LiveVADModelError.invalidModel) {
            _ = try await LiveVADModelFactory.load(configuration: f.configuration,sources: [.microphone,.system],assets: assets,loader: { owner,_ in
                let call = audit.call()
                if mode == "second-load" && call == 2 { throw LiveVADModelError.invalidModel }
                var description = VADLoadFixture.description
                if mode == "description" { description.outputs.removeLast() }
                let handle = VADLoadHandle(owner,description: description); audit.observe(handle); return handle
            })
        }
        #expect(!audit.handleAlive); #expect(audit.calls == (mode == "second-load" ? 2 : 1))
    }
}
