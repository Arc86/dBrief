import Darwin
import Foundation
import Testing
@testable import dBriefWire

actor ASRCopyGate {
    private(set) var entered = false
    private var waiter: CheckedContinuation<Void,Never>?
    private var released = false
    func hold() async {
        guard !released else { return }
        entered = true
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

func asrEventually(_ predicate: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    while ContinuousClock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await predicate()
}

@Suite struct LiveASRAssetsTests {
    @Test func publicPreparationAndHelperReopenUseTheActualPrivateOsParent() async throws {
        let f = try ASRAssetsFixture(); defer { f.remove() }
        let assets = try LiveASRModelAssets(sourceDirectory: f.source,identity: ASRAssetsFixture.identity(),language: .auto,chunkMs: 1120)
        let owner = UUID(), directory = URL(fileURLWithPath: assets.configuration.modelDirectory)
        do {
            try #require(assets.bind(to: owner)); try await assets.prepare(owner: owner)
            let reader = try LiveASRReadOnlySnapshot.open(assets.configuration)
            #expect(reader.fingerprint == ASRAssetsFixture.fingerprint)
            #expect(try reader.validateCurrentPath().path == directory.path)
            #expect(directory.deletingLastPathComponent().path != f.staging.path)
            #expect(LiveASRStagingBudget.shared.usage.roots == 1 && LiveASRStagingBudget.shared.usage.bytes == 253087)
        } catch { await assets.retire(owner: owner)?.value; throw error }
        await assets.retire(owner: owner)?.value
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(LiveASRStagingBudget.shared.usage.roots == 0 && LiveASRStagingBudget.shared.usage.workers == 0)
    }

    @Test func frozenFuturePathBecomesAnIndependentReadOnlySnapshotAndCallerPurgeIsHarmless() async throws {
        let f = try ASRAssetsFixture(); defer { f.remove() }
        let owner = UUID(), budget = LiveASRStagingBudget(), assets = try f.assets(budget: budget)
        let frozen = assets.configuration
        #expect(f.staged.isEmpty)
        let source = f.source.appendingPathComponent("encoder.mlmodelc/model.mil")
        let before = try FileManager.default.attributesOfItem(atPath: source.path)
        try #require(assets.bind(to: owner))
        try await assets.prepare(owner: owner)
        #expect(assets.configuration == frozen)
        let snapshot = try assets.snapshot(owner: owner)
        #expect(snapshot.fingerprint == ASRAssetsFixture.fingerprint)
        let copy = URL(fileURLWithPath: frozen.modelDirectory).appendingPathComponent("encoder.mlmodelc/model.mil")
        #expect(try Data(contentsOf: copy) == Data("fixture-encoder".utf8))
        let after = try FileManager.default.attributesOfItem(atPath: source.path)
        #expect(after[.modificationDate] as? Date == before[.modificationDate] as? Date)
        #expect(after[.posixPermissions] as? Int == before[.posixPermissions] as? Int)
        var a = stat(), b = stat()
        #expect(lstat(source.path,&a) == 0 && lstat(copy.path,&b) == 0)
        #expect(a.st_ino != b.st_ino || a.st_dev != b.st_dev)
        #expect(b.st_nlink == 1 && b.st_mode & 0o777 == 0o444)
        try FileManager.default.removeItem(at: f.source)
        _ = try snapshot.validateCurrentPath()
        #expect(budget.usage.workers == 0 && budget.usage.roots == 1 && budget.usage.bytes == 253087)
        await assets.retire(owner: owner)?.value
        #expect(f.staged.isEmpty && budget.usage.roots == 0)
    }

    @Test(arguments: ["missing","package","unknown","no-decode","fingerprint","symlink","fifo","too-large","growth"])
    func invalidCopiesNeverMutateCallerOrLeaveOwnedRoots(mode: String) async throws {
        let f = try ASRAssetsFixture(); defer { f.remove() }
        let owner = UUID(), leaf = f.source.appendingPathComponent("encoder.mlmodelc/model.mil")
        if mode == "missing" { try FileManager.default.removeItem(at: f.source.appendingPathComponent("metadata.json")) }
        if mode == "package" { try FileManager.default.createDirectory(at: f.source.appendingPathComponent("encoder.mlpackage"),withIntermediateDirectories: false) }
        if mode == "unknown" { try Data([1]).write(to: f.source.appendingPathComponent("unknown.bin")) }
        if mode == "no-decode" { try FileManager.default.removeItem(at: f.source.appendingPathComponent("joint.mlmodelc")) }
        if mode == "symlink" || mode == "fifo" {
            try FileManager.default.removeItem(at: leaf)
            if mode == "symlink" { try FileManager.default.createSymbolicLink(at: leaf,withDestinationURL: f.source.appendingPathComponent("tokenizer.json")) }
            else { try #require(mkfifo(leaf.path,0o600) == 0) }
        }
        let budget = LiveASRStagingBudget()
        var limits = LiveASRModelAssets.Limits()
        if mode == "too-large" { limits.maximumTotalBytes = 100 }
        let probe: LiveASRModelAssets.Probe = { point,path in
            if mode == "growth", point == .beforeOpenFile, path == "encoder.mlmodelc/model.mil" {
                try Data("grew beyond original manifest size".utf8).write(to: leaf)
            }
        }
        let assets = try f.assets(budget: budget,limits: limits,probe: probe,
            identity: ASRAssetsFixture.identity(fingerprint: mode == "fingerprint" ? String(repeating: "a",count: 64) : ASRAssetsFixture.fingerprint))
        try #require(assets.bind(to: owner))
        await #expect(throws: LiveASRAssetError.self) { try await assets.prepare(owner: owner) }
        #expect(f.staged.isEmpty && budget.usage.workers == 0 && budget.usage.roots == 0)
        #expect(try Data(contentsOf: f.source.appendingPathComponent("encoder.mlmodelc/weights/weight.bin")) == Data([1,2,3]))
    }

    @Test func retiredHeldCopyKeepsItsPermitUntilActualReturnAndCannotPublishLate() async throws {
        let f = try ASRAssetsFixture(); defer { f.remove() }
        let budget = LiveASRStagingBudget(), gate = ASRCopyGate(), owner = UUID()
        let assets = try f.assets(budget: budget,probe: { point,_ in if point == .afterCreateDirectory { await gate.hold() } })
        try #require(assets.bind(to: owner))
        let copying = Task { try await assets.prepare(owner: owner) }
        guard await asrEventually({ await gate.entered }) else {
            copying.cancel(); assets.retire(owner: owner); await gate.release(); _ = await copying.result; Issue.record("copy did not enter"); return
        }
        assets.retire(owner: owner)
        do {
            for _ in 0..<6 {
                let other = try f.assets(budget: budget), otherOwner = UUID()
                try #require(other.bind(to: otherOwner))
                await #expect(throws: LiveASRAssetError.busy) { try await other.prepare(owner: otherOwner) }
            }
            #expect(budget.usage.workers == 1 && budget.usage.roots == 1 && f.staged.count == 1)
            await gate.release()
            if case .success = await copying.result { Issue.record("retired copy published") }
        } catch {
            copying.cancel(); await gate.release(); _ = await copying.result; await assets.retire(owner: owner)?.value; throw error
        }
        #expect(f.staged.isEmpty && budget.usage.workers == 0 && budget.usage.roots == 0)
        #expect(throws: LiveASRAssetError.self) { _ = try assets.snapshot(owner: owner) }
    }

    @Test func lowSpaceAndRetainedReadyRootsAreChargedBeforeWriting() async throws {
        let f = try ASRAssetsFixture(); defer { f.remove() }
        let headroom: UInt64 = 1 << 30
        let low = LiveASRStagingBudget(availableBytes: { _ in headroom + 253086 })
        let a = try f.assets(budget: low), owner = UUID()
        try #require(a.bind(to: owner))
        await #expect(throws: LiveASRAssetError.insufficientDisk) { try await a.prepare(owner: owner) }
        #expect(f.staged.isEmpty && low.usage.roots == 0)
        let budget = LiveASRStagingBudget(availableBytes: { _ in headroom + 253087 })
        let first = try f.assets(budget: budget), firstOwner = UUID()
        try #require(first.bind(to: firstOwner)); try await first.prepare(owner: firstOwner)
        let second = try f.assets(budget: budget), secondOwner = UUID()
        try #require(second.bind(to: secondOwner))
        await #expect(throws: LiveASRAssetError.insufficientDisk) { try await second.prepare(owner: secondOwner) }
        #expect(budget.usage.roots == 1 && budget.usage.bytes == 253087)
        await first.retire(owner: firstOwner)?.value
        #expect(budget.usage.roots == 0)
    }

    @Test func foreignRetirementAndReplacementNamesCannotAcquireCleanupAuthority() async throws {
        let f = try ASRAssetsFixture(); defer { f.remove() }
        let budget = LiveASRStagingBudget(), assets = try f.assets(budget: budget), owner = UUID()
        try #require(assets.bind(to: owner)); try await assets.prepare(owner: owner)
        #expect(!assets.bind(to: UUID()))
        #expect(assets.retire(owner: UUID()) == nil)
        let root = URL(fileURLWithPath: assets.configuration.modelDirectory)
        let old = f.staging.appendingPathComponent("moved-owned-root")
        try FileManager.default.moveItem(at: root,to: old)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: false)
        try Data("foreign".utf8).write(to: root.appendingPathComponent("foreign.bin"))
        #expect(throws: LiveASRAssetError.self) { _ = try assets.snapshot(owner: owner).validateCurrentPath() }
        await assets.retire(owner: owner)?.value
        #expect(try Data(contentsOf: root.appendingPathComponent("foreign.bin")) == Data("foreign".utf8))
        #expect(budget.usage.roots == 1 && budget.usage.bytes == 253087)
    }
}
