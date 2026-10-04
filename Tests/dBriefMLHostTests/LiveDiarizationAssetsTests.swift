import CryptoKit
import Darwin
import Foundation
import Testing
@testable import dBriefWire
@testable import dBriefMLHost

actor DiarizationAssetGate {
    private(set) var entered = false
    private var waiter: CheckedContinuation<Void,Never>?
    private var released = false
    func hold() async {
        guard !released else { return }; entered = true
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
func diarAssetEventually(_ predicate: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    while ContinuousClock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await predicate()
}

struct DiarizationAssetsFixture: Sendable {
    let root: URL, source: URL, staging: URL
    let identity: LiveDiarizationIdentity
    let files: [String:Data]
    static func embedding(_ value: Float = 0.375) -> Data {
        var bits = value.bitPattern.littleEndian
        let bytes = withUnsafeBytes(of: &bits) { Data($0) }
        return (0..<512).reduce(into: Data()) { result,_ in result.append(bytes) }
    }
    init(preset: LiveDiarizationPreset = .low, embedding: Data? = nil, marker: Data? = nil, metadata: Data? = nil) throws {
        root = URL(fileURLWithPath: "/private/tmp/diarization-assets-\(UUID())")
        source = root.appendingPathComponent("source"); staging = root.appendingPathComponent("staging")
        let model = preset.modelFileName
        files = [model+"/metadata.json":metadata ?? Data("{}".utf8),model+"/model.mil":Data("fixture".utf8),
                 model+"/weights/weight.bin":Data([1,2,3]),"learnable_sil_emb.bin":embedding ?? Self.embedding(),
                 ".fluidaudio-nemotron3-weights":marker ?? Data(LiveDiarizationIdentity.currentModelRevision.utf8)]
        try FileManager.default.createDirectory(at: staging,withIntermediateDirectories: true,attributes: [.posixPermissions:0o700])
        for (path,data) in files {
            let file = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),withIntermediateDirectories: true)
            try data.write(to: file)
        }
        // Independent fixture manifest: production reads/hashes real descriptor bytes.
        var hash = SHA256(); hash.update(data: Data("dBrief.DiarizationAssets.v1\0".utf8))
        for path in (Array(files.keys)+[model,model+"/weights"]).sorted() {
            let data = files[path], encoded = Data(path.utf8)
            hash.update(data: Data([data == nil ? 0 : 1]))
            var length = UInt32(encoded.count).littleEndian, size = UInt64(data?.count ?? 0).littleEndian
            withUnsafeBytes(of: &length) { hash.update(bufferPointer: $0) }; hash.update(data: encoded)
            withUnsafeBytes(of: &size) { hash.update(bufferPointer: $0) }
            if let data { hash.update(data: Data(SHA256.hash(data: data))) }
        }
        identity = .init(modelFingerprint: hash.finalize().map { String(format: "%02x",$0) }.joined(),preset: preset,computeUnits: .cpuOnly)
    }
    func assets(budget: LiveASRStagingBudget = .init(), limits: LiveDiarizationModelAssets.Limits = .init(),
                probe: LiveDiarizationModelAssets.Probe? = nil) throws -> LiveDiarizationModelAssets {
        try .init(sourceDirectory: source,identity: identity,budget: budget,testingStagingDirectory: staging,limits: limits,probe: probe)
    }
    var staged: [String] { (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [] }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct LiveDiarizationAssetsTests {
    @Test func actualPublicOsCopyReopenAndCachePurgeRetainIndependentImmutableBytes() async throws {
        let f = try DiarizationAssetsFixture(); defer { f.remove() }
        let assets = try LiveDiarizationModelAssets(sourceDirectory: f.source,identity: f.identity), owner = UUID()
        let frozen = assets.configuration
        do {
            try #require(assets.bind(to: owner)); try await assets.prepare(owner: owner)
            let reader = try LiveDiarizationReadOnlySnapshot.open(frozen)
            let path = try reader.validateCurrentPath()
            #expect(reader.fingerprint == f.identity.modelFingerprint && reader.metadata.silenceEmbedding == Array(repeating: 0.375,count: 512))
            #expect(assets.configuration == frozen && path.deletingLastPathComponent() != f.staging)
            #expect(assets.retire(owner: UUID()) == nil)
            #expect(throws: LiveASRAssetError.self) { _ = try assets.snapshot(owner: UUID()) }
            for leaf in f.files.keys {
                var source = stat(), copy = stat()
                #expect(lstat(f.source.appendingPathComponent(leaf).path,&source) == 0)
                #expect(lstat(path.appendingPathComponent(leaf).path,&copy) == 0)
                #expect(source.st_ino != copy.st_ino || source.st_dev != copy.st_dev)
                #expect(copy.st_nlink == 1 && copy.st_mode & 0o777 == 0o444)
            }
            try FileManager.default.removeItem(at: f.source)
            _ = try reader.validateCurrentPath()
            await assets.retire(owner: owner)?.value
            #expect(throws: LiveASRAssetError.self) { _ = try reader.validateCurrentPath() }
        } catch { await assets.retire(owner: owner)?.value; throw error }
    }

    @Test(arguments: LiveDiarizationPreset.allCases)
    func eachFrozenPresetHasExactPortableAssetIdentity(preset: LiveDiarizationPreset) async throws {
        let f = try DiarizationAssetsFixture(preset: preset); defer { f.remove() }
        let a = try f.assets(), owner = UUID()
        try #require(a.bind(to: owner)); try await a.prepare(owner: owner)
        do {
            let c = try JSONDecoder().decode(LiveDiarizationConfiguration.self,from: JSONEncoder().encode(a.configuration))
            #expect(c == a.configuration && c.identity.isSupported)
            let reader = try LiveDiarizationReadOnlySnapshot.open(c,testingStagingDirectory: f.staging)
            #expect(reader.configuration == c && reader.metadata.silenceEmbedding.count == 512)
        } catch { await a.retire(owner: owner)?.value; throw error }
        await a.retire(owner: owner)?.value
        #expect(f.staged.isEmpty)
    }

    @Test(arguments: ["short","trailing","nan","infinity","marker","metadata-empty","metadata-large"])
    func witnessCannotCollectOversizedOrInvalidPinnedValues(mode: String) async throws {
        var embedding = DiarizationAssetsFixture.embedding()
        if mode == "short" { embedding.removeLast() }
        if mode == "trailing" { embedding.append(0) }
        if mode == "nan" { embedding = DiarizationAssetsFixture.embedding(.nan) }
        if mode == "infinity" { embedding = DiarizationAssetsFixture.embedding(.infinity) }
        let metadata = mode == "metadata-empty" ? Data() : mode == "metadata-large" ? Data(repeating: 32,count: 65_537) : Data("{}".utf8)
        let f = try DiarizationAssetsFixture(embedding: embedding,marker: mode == "marker" ? Data("foreign".utf8) : nil,metadata: metadata)
        defer { f.remove() }
        let budget = LiveASRStagingBudget(), a = try f.assets(budget: budget), owner = UUID()
        try #require(a.bind(to: owner))
        await #expect(throws: LiveASRAssetError.self) { try await a.prepare(owner: owner) }
        #expect(f.staged.isEmpty && budget.usage.roots == 0 && budget.usage.workers == 0)
        #expect(try Data(contentsOf: f.source.appendingPathComponent("learnable_sil_emb.bin")) == embedding)
    }

    @Test(arguments: ["unknown","package","symlink","fifo","growth","size","fingerprint"])
    func rejectedFilesystemInputsLeaveSourceAndNoOwnedRoots(mode: String) async throws {
        let f = try DiarizationAssetsFixture(); defer { f.remove() }
        let leaf = f.source.appendingPathComponent(f.identity.preset.modelFileName+"/model.mil")
        if mode == "unknown" { try Data([1]).write(to: f.source.appendingPathComponent("unknown")) }
        if mode == "package" { try FileManager.default.createDirectory(at: f.source.appendingPathComponent("model.mlpackage"),withIntermediateDirectories: false) }
        if mode == "symlink" || mode == "fifo" {
            try FileManager.default.removeItem(at: leaf)
            if mode == "symlink" { try FileManager.default.createSymbolicLink(at: leaf,withDestinationURL: f.source.appendingPathComponent("learnable_sil_emb.bin")) }
            else { try #require(mkfifo(leaf.path,0o600) == 0) }
        }
        if mode == "fingerprint" { try Data("changed".utf8).write(to: leaf) }
        var limits = LiveDiarizationModelAssets.Limits(); if mode == "size" { limits.maximumTotalBytes = 100 }
        let budget = LiveASRStagingBudget(), a = try f.assets(budget: budget,limits: limits,probe: { point,path in
            if mode == "growth", point == .beforeOpenFile, path.hasSuffix("/model.mil") { try Data("growth beyond admitted size".utf8).write(to: leaf) }
        }), owner = UUID()
        try #require(a.bind(to: owner))
        await #expect(throws: LiveASRAssetError.self) { try await a.prepare(owner: owner) }
        #expect(f.staged.isEmpty && budget.usage.roots == 0 && budget.usage.workers == 0)
        #expect(try Data(contentsOf: f.source.appendingPathComponent(f.identity.preset.modelFileName+"/weights/weight.bin")) == Data([1,2,3]))
    }

    @Test func canceledHeldCopyDoesNotRefundWorkerOrPublishLate() async throws {
        let f = try DiarizationAssetsFixture(); defer { f.remove() }
        let budget = LiveASRStagingBudget(), gate = DiarizationAssetGate(), owner = UUID()
        let a = try f.assets(budget: budget,probe: { point,_ in if point == .afterOpenFile { await gate.hold() } })
        try #require(a.bind(to: owner))
        let copy = Task { try await a.prepare(owner: owner) }
        guard await diarAssetEventually({ await gate.entered }) else {
            copy.cancel(); await gate.release(); _ = await copy.result; Issue.record("copy never entered"); return
        }
        copy.cancel()
        #expect(budget.usage.workers == 1 && budget.usage.roots == 1 && f.staged.count == 1)
        let other = try f.assets(budget: budget), otherOwner = UUID()
        try #require(other.bind(to: otherOwner))
        await #expect(throws: LiveASRAssetError.busy) { try await other.prepare(owner: otherOwner) }
        #expect(throws: LiveASRAssetError.self) { _ = try a.snapshot(owner: owner) }
        await gate.release()
        if case .success = await copy.result { Issue.record("canceled copy published") }
        #expect(budget.usage.roots == 0 && budget.usage.workers == 0 && f.staged.isEmpty)
    }

    @Test func twoMandatoryRootsAndOneOptionalRootShareTheSameFiniteBudget() async throws {
        let v = try VADLoadFixture(), f = try DiarizationAssetsFixture(); defer { v.cleanup(); f.remove() }
        let budget = LiveASRStagingBudget()
        let mandatory = try (0..<2).map { _ in try LiveVADAssetPreparation(source: v.configuration,budget: budget,testingStagingDirectory: v.staging) }
        let owners = [UUID(),UUID()], a = try f.assets(budget: budget), owner = UUID()
        do {
            for i in 0..<2 { try #require(mandatory[i].bind(to: owners[i])); try await mandatory[i].prepare(owner: owners[i]) }
            try #require(a.bind(to: owner)); try await a.prepare(owner: owner)
            #expect(budget.usage.roots == 3 && budget.usage.workers == 0)
            let third = try LiveVADAssetPreparation(source: v.configuration,budget: budget,testingStagingDirectory: v.staging), thirdOwner = UUID()
            try #require(third.bind(to: thirdOwner))
            await #expect(throws: LiveASRAssetError.busy) { try await third.prepare(owner: thirdOwner) }
            let extra = try f.assets(budget: budget), extraOwner = UUID()
            try #require(extra.bind(to: extraOwner))
            await #expect(throws: LiveASRAssetError.busy) { try await extra.prepare(owner: extraOwner) }
        } catch {
            await a.retire(owner: owner)?.value
            for i in 0..<2 { await mandatory[i].retire(owner: owners[i])?.value }; throw error
        }
        await a.retire(owner: owner)?.value
        for i in 0..<2 { await mandatory[i].retire(owner: owners[i])?.value }
        #expect(budget.usage.roots == 0 && budget.usage.bytes == 0)
    }

    @Test func replacedOwnedRootProtectsForeignFilesAndKeepsOptionalOrphanCharge() async throws {
        let f = try DiarizationAssetsFixture(); defer { f.remove() }
        let budget = LiveASRStagingBudget(), a = try f.assets(budget: budget), owner = UUID()
        try #require(a.bind(to: owner)); try await a.prepare(owner: owner)
        let directory = URL(fileURLWithPath: a.configuration.modelDirectory), moved = f.staging.appendingPathComponent("held-original")
        try FileManager.default.moveItem(at: directory,to: moved)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: false)
        let opaque = directory.appendingPathComponent("foreign"); try Data("foreign".utf8).write(to: opaque)
        #expect(throws: LiveASRAssetError.self) { _ = try a.snapshot(owner: owner).validateCurrentPath() }
        await a.retire(owner: owner)?.value
        #expect(try Data(contentsOf: opaque) == Data("foreign".utf8))
        #expect(budget.usage.roots == 1 && budget.usage.bytes > 0)
        let next = try f.assets(budget: budget), nextOwner = UUID(); try #require(next.bind(to: nextOwner))
        await #expect(throws: LiveASRAssetError.busy) { try await next.prepare(owner: nextOwner) }
    }
}
