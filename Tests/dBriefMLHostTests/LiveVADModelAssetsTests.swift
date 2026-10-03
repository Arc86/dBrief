import CryptoKit
import Darwin
import Foundation
import Testing
import dBriefWire
@testable import dBriefMLHost

private struct VADAssetsFixture: Sendable {
    static let fingerprint = "31f96f6d309c03de46967788ec8fe00e2e2fc6a7afe576218711e475e99e3337"
    let root: URL
    let source: URL
    let staging: URL
    let files: [String: Data] = ["metadata.json":Data("{}".utf8),"model.mil":Data("fixture".utf8),
        "coremldata.bin":Data("core".utf8),"analytics/coremldata.bin":Data("analytics".utf8),"weights/weight.bin":Data([1,2,3])]
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/vad-assets-fixture-\(UUID())",isDirectory: true)
        source = root.appendingPathComponent("original.mlmodelc"); staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging,withIntermediateDirectories: true,attributes: [.posixPermissions:0o700])
        for (path,data) in files {
            let file = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),withIntermediateDirectories: true)
            try data.write(to: file)
        }
    }
    func configuration(fingerprint: String = Self.fingerprint, model: String = "silero-vad-unified-256ms-v6.2.1", path: String? = nil) -> LiveVADConfiguration {
        .init(identity: .init(modelRevision: model,modelFingerprint: fingerprint,runtimeRevision: LiveVADNativeConfiguration.runtimeRevision),
            modelPath: path ?? source.path)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    var staged: [String] { (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [] }
}

private final class VADAssetsWeakReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var storage: LiveVADModelAssets?
    func set(_ value: LiveVADModelAssets) { lock.withLock { storage = value } }
    var alive: Bool { lock.withLock { storage != nil } }
}

private struct VADTreeObservation: Equatable {
    let path: String
    let bytes: Data?
    let permissions: Int?
    let modified: Date?
    static func read(_ root: URL, files: [String: Data]) throws -> [Self] {
        try ([""] + ["analytics","weights"] + files.keys.sorted()).map { path in
            let url = path.isEmpty ? root : root.appendingPathComponent(path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return Self(path: path,bytes: files[path] == nil ? nil : try Data(contentsOf: url),
                permissions: attributes[.posixPermissions] as? Int,modified: attributes[.modificationDate] as? Date)
        }
    }
}

@Suite struct LiveVADModelAssetsTests {
    @Test func knownVersionedFingerprintIsPortableAndCopiesHaveIndependentReadOnlyOwnership() async throws {
        let a = try VADAssetsFixture(), b = try VADAssetsFixture()
        defer { a.cleanup(); b.cleanup() }
        try #require(a.configuration().isValid, "\(a.configuration())")
        let before = try a.files.keys.sorted().map { path -> (Data,Date,Int) in
            let url = a.source.appendingPathComponent(path), attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (try Data(contentsOf: url),try #require(attributes[.modificationDate] as? Date),try #require(attributes[.posixPermissions] as? Int))
        }
        var assets: LiveVADModelAssets? = try await .prepare(a.configuration(),testingStagingDirectory: a.staging)
        let other = try await LiveVADModelAssets.prepare(b.configuration(),testingStagingDirectory: b.staging)
        let copy = try #require(try assets?.modelDirectory)
        #expect(assets?.fingerprint == VADAssetsFixture.fingerprint && other.fingerprint == VADAssetsFixture.fingerprint)
        for (index,path) in a.files.keys.sorted().enumerated() {
            let source = a.source.appendingPathComponent(path), destination = copy.appendingPathComponent(path)
            #expect(try Data(contentsOf: destination) == a.files[path])
            #expect(try Data(contentsOf: source) == before[index].0)
            let after = try FileManager.default.attributesOfItem(atPath: source.path)
            #expect(after[.modificationDate] as? Date == before[index].1)
            #expect(after[.posixPermissions] as? Int == before[index].2)
            #expect(try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int == 0o444)
            var originalInfo = stat(), copyInfo = stat()
            #expect(lstat(source.path,&originalInfo) == 0 && lstat(destination.path,&copyInfo) == 0)
            #expect(originalInfo.st_ino != copyInfo.st_ino || originalInfo.st_dev != copyInfo.st_dev)
        }
        try Data("replacement".utf8).write(to: a.source.appendingPathComponent("model.mil"))
        #expect(try Data(contentsOf: copy.appendingPathComponent("model.mil")) == Data("fixture".utf8))
        assets = nil
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(a.staged.isEmpty)
        #expect(try Data(contentsOf: a.source.appendingPathComponent("model.mil")) == Data("replacement".utf8))
    }

    @Test(arguments: ["missing", "empty", "extra", "wrong-type", "fingerprint", "revision"])
    func invalidTreesFailWithoutTouchingCallerOrLeavingStaging(mode: String) async throws {
        let f = try VADAssetsFixture(); defer { f.cleanup() }
        let model = f.source.appendingPathComponent("model.mil")
        if mode == "missing" { try FileManager.default.removeItem(at: model) }
        if mode == "empty" { try Data().write(to: model) }
        if mode == "extra" { try Data([1]).write(to: f.source.appendingPathComponent("unexpected.bin")) }
        if mode == "wrong-type" { try FileManager.default.removeItem(at: model); try FileManager.default.createDirectory(at: model,withIntermediateDirectories: false) }
        let config = f.configuration(fingerprint: mode == "fingerprint" ? String(repeating: "b",count: 64) : VADAssetsFixture.fingerprint,
            model: mode == "revision" ? "other-model" : "silero-vad-unified-256ms-v6.2.1")
        await #expect(throws: LiveVADAssetError.self) { _ = try await LiveVADModelAssets.prepare(config,testingStagingDirectory: f.staging) }
        #expect(f.staged.isEmpty)
        #expect(try Data(contentsOf: f.source.appendingPathComponent("weights/weight.bin")) == f.files["weights/weight.bin"])
    }

    @Test(arguments: ["root", "directory", "file", "fifo", "swap-fifo", "swap-symlink"])
    func noFollowNonblockingOpensRefuseSpecialFilesAndSwaps(mode: String) async throws {
        let f = try VADAssetsFixture(); defer { f.cleanup() }
        let file = f.source.appendingPathComponent("model.mil")
        var config = f.configuration()
        if mode == "root" {
            let alias = f.root.appendingPathComponent("alias.mlmodelc")
            try FileManager.default.createSymbolicLink(at: alias,withDestinationURL: f.source)
            config = f.configuration(path: alias.path)
        }
        if mode == "directory" {
            let directory = f.source.appendingPathComponent("weights")
            let moved = f.root.appendingPathComponent("moved")
            try FileManager.default.moveItem(at: directory,to: moved)
            try FileManager.default.createSymbolicLink(at: directory,withDestinationURL: moved)
        }
        if mode == "file" || mode == "fifo" {
            try FileManager.default.removeItem(at: file)
            if mode == "file" { try FileManager.default.createSymbolicLink(at: file,withDestinationURL: f.source.appendingPathComponent("metadata.json")) }
            else { try #require(mkfifo(file.path,0o600) == 0) }
        }
        let probe: LiveVADModelAssets.Probe = { point,path in
            if point == .beforeOpenFile, path == "model.mil", mode.hasPrefix("swap-") {
                try FileManager.default.removeItem(at: file)
                if mode == "swap-fifo" { guard mkfifo(file.path,0o600) == 0 else { throw LiveVADAssetError.invalidAsset } }
                else { try FileManager.default.createSymbolicLink(at: file,withDestinationURL: f.source.appendingPathComponent("metadata.json")) }
            }
        }
        await #expect(throws: LiveVADAssetError.self) { _ = try await LiveVADModelAssets.prepare(config,testingStagingDirectory: f.staging,probe: probe) }
        #expect(f.staged.isEmpty)
    }

    @Test func fileAndTreeLimitsUseActualReadBytesIncludingGrowthAfterStat() async throws {
        let f = try VADAssetsFixture(); defer { f.cleanup() }
        var limits = LiveVADModelAssets.Limits(); limits.maximumFileBytes = 9; limits.maximumTotalBytes = 25
        let exact = try await LiveVADModelAssets.prepare(f.configuration(),testingStagingDirectory: f.staging,limits: limits)
        #expect(exact.fingerprint == VADAssetsFixture.fingerprint)
        limits.maximumFileBytes = 8
        await #expect(throws: LiveVADAssetError.oversized) { _ = try await LiveVADModelAssets.prepare(f.configuration(),testingStagingDirectory: f.staging,limits: limits) }
        limits.maximumFileBytes = 9; limits.maximumTotalBytes = 24
        await #expect(throws: LiveVADAssetError.oversized) { _ = try await LiveVADModelAssets.prepare(f.configuration(),testingStagingDirectory: f.staging,limits: limits) }
        limits.maximumTotalBytes = 25
        let file = f.source.appendingPathComponent("model.mil")
        let grow: LiveVADModelAssets.Probe = { point,path in
            if point == .afterOpenFile, path == "model.mil" {
                let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: Data([1,2,3]))
            }
        }
        await #expect(throws: LiveVADAssetError.oversized) { _ = try await LiveVADModelAssets.prepare(f.configuration(),testingStagingDirectory: f.staging,limits: limits,probe: grow) }
        #expect(f.staged.count == 1) // Only the retained successful owner's tree.
    }

    @Test(arguments: [false,true])
    func descriptorPinnedReplacementAllowsOnlyTheExactCopiedFingerprint(mutateOpenFile: Bool) async throws {
        let f = try VADAssetsFixture(); defer { f.cleanup() }
        let file = f.source.appendingPathComponent("model.mil")
        let probe: LiveVADModelAssets.Probe = { point,path in
            guard point == .afterOpenFile, path == "model.mil" else { return }
            if mutateOpenFile {
                let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
                try handle.write(contentsOf: Data("mutated".utf8))
            } else {
                try FileManager.default.removeItem(at: file)
                try Data("unqualified replacement".utf8).write(to: file)
            }
        }
        if mutateOpenFile {
            await #expect(throws: LiveVADAssetError.fingerprintMismatch) { _ = try await LiveVADModelAssets.prepare(f.configuration(),testingStagingDirectory: f.staging,probe: probe) }
            #expect(f.staged.isEmpty)
        } else {
            let assets = try await LiveVADModelAssets.prepare(f.configuration(),testingStagingDirectory: f.staging,probe: probe)
            #expect(try Data(contentsOf: assets.modelDirectory.appendingPathComponent("model.mil")) == Data("fixture".utf8))
        }
    }

    @Test func cancellationRemovesOnlyPrivateStagingAndCannotRetireAHeldOwner() async throws {
        let f = try VADAssetsFixture(); defer { f.cleanup() }
        let entered = LifetimeSignal(), release = LifetimeSignal()
        try #require(f.configuration().isValid, "\(f.configuration())")
        let copying = Task {
            do {
                return try await LiveVADModelAssets.prepare(f.configuration(),testingStagingDirectory: f.staging,probe: { point,path in
                    if point == .beforeOpenFile, path == "model.mil" { await entered.signal(); await release.wait() }
                })
            } catch { await entered.signal(); throw error }
        }
        await entered.wait(); copying.cancel()
        #expect(!f.staged.isEmpty)
        await release.signal()
        await #expect(throws: CancellationError.self) { _ = try await copying.value }
        #expect(f.staged.isEmpty)
        var assets: LiveVADModelAssets? = try await .prepare(f.configuration(),testingStagingDirectory: f.staging)
        let weak = VADAssetsWeakReference(); weak.set(try #require(assets))
        let loaded = LifetimeSignal(), loadRelease = LifetimeSignal()
        let held = Task<Void, Error> { [owner = try #require(assets)] in
            defer { withExtendedLifetime(owner) {} }
            await loaded.signal(); await loadRelease.wait()
            let model = try owner.modelDirectory
            #expect(FileManager.default.fileExists(atPath: model.path))
        }
        await loaded.wait(); assets = nil; held.cancel()
        #expect(weak.alive && f.staged.count == 1)
        await loadRelease.signal(); try await held.value
        #expect(!weak.alive && f.staged.isEmpty)
        #expect(try Data(contentsOf: f.source.appendingPathComponent("model.mil")) == Data("fixture".utf8))
    }

    @Test(arguments: [false,true])
    func substitutedRootIsNeverPublishedOrFollowedDuringFailureCleanup(cancel: Bool) async throws {
        let f = try VADAssetsFixture(); defer { f.cleanup() }
        let caller = f.root.appendingPathComponent("caller"), callerModel = caller.appendingPathComponent("model.mlmodelc")
        try FileManager.default.createDirectory(at: caller,withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: f.source,to: callerModel)
        for url in [callerModel,callerModel.appendingPathComponent("analytics"),callerModel.appendingPathComponent("weights")] {
            try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath: url.path)
        }
        let before = try VADTreeObservation.read(callerModel,files: f.files)
        let probe: LiveVADModelAssets.Probe = { point,path in
            if point == .beforeOpenFile, path == "model.mil" {
                let name = try #require(f.staged.first), root = f.staging.appendingPathComponent(name)
                try #require(rename(root.path,f.root.appendingPathComponent("orphan").path) == 0)
                try FileManager.default.createSymbolicLink(at: root,withDestinationURL: caller)
                if cancel { throw CancellationError() }
            }
        }
        if cancel {
            await #expect(throws: CancellationError.self) { _ = try await LiveVADModelAssets.prepare(f.configuration(),testingStagingDirectory: f.staging,probe: probe) }
        } else {
            await #expect(throws: LiveVADAssetError.invalidAsset) { _ = try await LiveVADModelAssets.prepare(f.configuration(),testingStagingDirectory: f.staging,probe: probe) }
        }
        #expect(try VADTreeObservation.read(callerModel,files: f.files) == before)
        let alias = try #require(f.staged.first)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.staging.appendingPathComponent(alias).path) == caller.path)
    }

    @Test(arguments: ["root-symlink","root-directory","model","analytics","weights","file"])
    func publishedOwnerRefusesReplacedNamesAndCleanupLeavesCallerObjectsUntouched(mode: String) async throws {
        let f = try VADAssetsFixture(); defer { f.cleanup() }
        var assets: LiveVADModelAssets? = try await .prepare(f.configuration(),testingStagingDirectory: f.staging)
        let model = try #require(try assets?.modelDirectory), root = model.deletingLastPathComponent()
        let target: URL
        if mode.hasPrefix("root-") { target = root }
        else if mode == "model" { target = model }
        else if mode == "file" { target = model.appendingPathComponent("model.mil") }
        else { target = model.appendingPathComponent(mode) }
        // The test is the only noncooperating namespace owner; production never
        // mutates the private parent while this asset owner exists.
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath: target.deletingLastPathComponent().path)
        if mode != "file" { try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath: target.path) }
        try #require(rename(target.path,f.root.appendingPathComponent("orphan").path) == 0)
        let caller = mode == "file" ? f.source.appendingPathComponent("model.mil") :
            (mode == "analytics" || mode == "weights" ? f.source.appendingPathComponent(mode) : f.source)
        if mode == "root-directory" { try FileManager.default.createDirectory(at: target,withIntermediateDirectories: false,attributes: [.posixPermissions:0o755]) }
        else { try FileManager.default.createSymbolicLink(at: target,withDestinationURL: caller) }
        let before = try VADTreeObservation.read(f.source,files: f.files)
        #expect(throws: LiveVADAssetError.invalidAsset) { _ = try assets?.modelDirectory }
        assets = nil
        #expect(try VADTreeObservation.read(f.source,files: f.files) == before)
        if mode == "root-directory" {
            #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
            #expect(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int == 0o755)
        } else {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == caller.path)
        }
    }

    @Test func validationIsLexicalAndSnapshotSurvivesCallerCachePurge() async throws {
        let f = try VADAssetsFixture(); defer { f.cleanup() }
        let configuration = f.configuration()
        try #require(configuration.isValid)
        let assets = try await LiveVADModelAssets.prepare(configuration,testingStagingDirectory: f.staging)
        try FileManager.default.removeItem(at: f.source)
        #expect(configuration.isValid)
        #expect(try Data(contentsOf: assets.modelDirectory.appendingPathComponent("model.mil")) == Data("fixture".utf8))
    }

    @Test func productionTemporaryParentOwnsAndRemovesItsSnapshot() async throws {
        let f = try VADAssetsFixture(); defer { f.cleanup() }
        var assets: LiveVADModelAssets? = try await .prepare(f.configuration())
        let model = try #require(try assets?.modelDirectory)
        #expect(!model.path.hasPrefix(f.root.path))
        #expect(try Data(contentsOf: model.appendingPathComponent("model.mil")) == f.files["model.mil"])
        var info = stat()
        #expect(lstat(model.deletingLastPathComponent().path,&info) == 0 && info.st_uid == geteuid() && info.st_mode & 0o777 == 0o700)
        assets = nil
        #expect(!FileManager.default.fileExists(atPath: model.path))
        #expect(try Data(contentsOf: f.source.appendingPathComponent("model.mil")) == f.files["model.mil"])
    }

    @Test func finalCopiedBytesAreFingerprintedAfterAllSourceCopies() async throws {
        let f = try VADAssetsFixture(); defer { f.cleanup() }
        let before = try VADTreeObservation.read(f.source,files: f.files)
        let probe: LiveVADModelAssets.Probe = { point,path in
            if point == .beforeOpenFile, path == "model.mil" {
                let name = try #require(f.staged.first)
                let copied = f.staging.appendingPathComponent(name).appendingPathComponent("model.mlmodelc/coremldata.bin")
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath: copied.path)
                let handle = try FileHandle(forWritingTo: copied); defer { try? handle.close() }
                try handle.write(contentsOf: Data("XXXX".utf8))
                try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath: copied.path)
            }
        }
        await #expect(throws: LiveVADAssetError.fingerprintMismatch) { _ = try await LiveVADModelAssets.prepare(f.configuration(),testingStagingDirectory: f.staging,probe: probe) }
        #expect(f.staged.isEmpty)
        #expect(try VADTreeObservation.read(f.source,files: f.files) == before)
    }

    @Test(arguments: ["root","model.mlmodelc","analytics","weights"])
    func directoryOpenFailureAfterCreationStillCleansOwnedEmptyEntries(failAt: String) async throws {
        let f = try VADAssetsFixture(); defer { f.cleanup() }
        let before = try VADTreeObservation.read(f.source,files: f.files)
        let probe: LiveVADModelAssets.Probe = { point,path in
            if point == .afterCreateDirectory, path == failAt || (failAt == "root" && path.hasPrefix("dbrief-vad-")) {
                throw POSIXError(.EMFILE)
            }
        }
        await #expect(throws: POSIXError(.EMFILE)) { _ = try await LiveVADModelAssets.prepare(f.configuration(),testingStagingDirectory: f.staging,probe: probe) }
        #expect(f.staged.isEmpty)
        #expect(try VADTreeObservation.read(f.source,files: f.files) == before)
    }

    @Test(arguments: ["source","within-source","symlink","shared","missing"])
    func stagingRejectsAliasesCacheDescendantsAndNonprivateParents(mode: String) async throws {
        let f = try VADAssetsFixture(); defer { f.cleanup() }
        var staging = f.staging
        if mode == "source" { staging = f.source }
        if mode == "within-source" { staging = f.source.appendingPathComponent("analytics") }
        if mode == "shared" { try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath: staging.path) }
        if mode == "missing" { staging = f.root.appendingPathComponent("missing") }
        if mode == "symlink" {
            staging = f.root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: staging,withDestinationURL: f.staging)
        }
        let before = try VADTreeObservation.read(f.source,files: f.files)
        await #expect(throws: LiveVADAssetError.invalidAsset) { _ = try await LiveVADModelAssets.prepare(f.configuration(),testingStagingDirectory: staging) }
        #expect(f.staged.isEmpty)
        #expect(try VADTreeObservation.read(f.source,files: f.files) == before)
    }

    @Test(arguments: ["zero-file","large-file","zero-tree","large-tree"])
    func callersCannotDisableProductionReadLimits(mode: String) async throws {
        let f = try VADAssetsFixture(); defer { f.cleanup() }
        var limits = LiveVADModelAssets.Limits()
        if mode == "zero-file" { limits.maximumFileBytes = 0 }
        if mode == "large-file" { limits.maximumFileBytes += 1 }
        if mode == "zero-tree" { limits.maximumTotalBytes = 0 }
        if mode == "large-tree" { limits.maximumTotalBytes += 1 }
        await #expect(throws: LiveVADAssetError.invalidConfiguration) { _ = try await LiveVADModelAssets.prepare(f.configuration(),testingStagingDirectory: f.staging,limits: limits) }
        #expect(f.staged.isEmpty)
    }
}
