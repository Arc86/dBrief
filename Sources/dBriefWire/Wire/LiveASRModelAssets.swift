import CryptoKit
import Darwin
import Foundation

private struct ASRFileIdentity: Sendable, Equatable {
    let device: dev_t; let inode: ino_t; let type: mode_t
    init(_ value: stat) { device = value.st_dev; inode = value.st_ino; type = value.st_mode & S_IFMT }
}
private final class ASRDirectory: Sendable {
    let fd: Int32; let identity: ASRFileIdentity
    init(taking fd: Int32) throws {
        var value = stat()
        guard fd >= 0, fstat(fd,&value) == 0, value.st_mode & S_IFMT == S_IFDIR else {
            if fd >= 0 { close(fd) }; throw LiveASRAssetError.invalidAsset
        }
        self.fd = fd; identity = .init(value)
    }
    deinit { close(fd) }
}
private struct ASRTreeEntry: Sendable {
    let path: String; let parent: ASRDirectory; let name: String
    let identity: ASRFileIdentity; let size: UInt64; let directory: ASRDirectory?
}

private enum OwnedModelIdentity: Sendable {
    case asr(LiveASRIdentity,LiveASRConfiguration.Language,Int)
    case diarization(LiveDiarizationIdentity)
    var supported: Bool {
        switch self {
        case .asr(let identity,_,let chunk): identity.isSupported && [560,1120,2240].contains(chunk)
        case .diarization(let identity): identity.isSupported
        }
    }
    var namespace: String { switch self { case .asr: "dbrief-asr-"; case .diarization: "dbrief-diar-" } }
    func configuration(path: String) -> OwnedModelConfiguration {
        switch self {
        case .asr(let identity,let language,let chunk): .asr(.init(language: language,chunkMs: chunk,modelDirectory: path,identity: identity))
        case .diarization(let identity): .diarization(.init(identity: identity,modelDirectory: path))
        }
    }
}
private enum OwnedModelConfiguration: Sendable {
    case asr(LiveASRConfiguration), diarization(LiveDiarizationConfiguration)
    var path: String { switch self { case .asr(let c): c.modelDirectory; case .diarization(let c): c.modelDirectory } }
    var supported: Bool { switch self { case .asr(let c): c.isValid && c.identity?.isSupported == true; case .diarization(let c): c.isValid } }
    var namespace: String { switch self { case .asr: "dbrief-asr-"; case .diarization: "dbrief-diar-" } }
    var fingerprint: String? { switch self { case .asr(let c): c.identity?.modelFingerprint; case .diarization(let c): c.identity.modelFingerprint } }
    var domain: String { switch self { case .asr: "dBrief.ASRAssets.v1\0"; case .diarization: "dBrief.DiarizationAssets.v1\0" } }
    var stagingKind: LiveASRStagingBudget.RootKind { switch self { case .asr: .mandatory; case .diarization: .diarization } }
}
private enum OwnedModelWitness: Sendable {
    case asr(LiveASRMetadataWitness), diarization(LiveDiarizationMetadataWitness)
}
private final class OwnedReadOnlySnapshot: Sendable {
    let configuration: OwnedModelConfiguration; let fingerprint: String; let witness: OwnedModelWitness
    let tree: ASRAssetTree
    init(tree: ASRAssetTree,configuration: OwnedModelConfiguration,fingerprint: String,witness: OwnedModelWitness) {
        self.tree = tree; self.configuration = configuration; self.fingerprint = fingerprint; self.witness = witness
    }
    func validateCurrentPath() throws -> URL { try tree.validateCurrentPath(readOnly: true) }
    static func open(_ configuration: OwnedModelConfiguration,testingStagingDirectory: URL?) throws -> OwnedReadOnlySnapshot {
        guard configuration.supported else { throw LiveASRAssetError.invalidConfiguration }
        let path = URL(fileURLWithPath: configuration.path), name = path.lastPathComponent, namespace = configuration.namespace
        guard name.hasPrefix(namespace), UUID(uuidString: String(name.dropFirst(namespace.count))) != nil else { throw LiveASRAssetError.invalidAsset }
        let parentURL = try testingStagingDirectory ?? ASRAssetTree.systemTemporaryDirectory()
        let parent = try ASRAssetTree.directory(path: parentURL.path)
        try ASRAssetTree.privateParent(parent)
        let parentPath = try ASRAssetTree.path(parent.fd)
        guard configuration.path == parentPath + "/" + name else { throw LiveASRAssetError.invalidAsset }
        let root = try ASRDirectory(taking: openat(parent.fd,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
        let tree = try ASRAssetTree.scan(root: root,parent: parent,name: name,path: configuration.path,limits: .init(),configuration: configuration,readOnly: true)
        let checked = try tree.fingerprint(configuration)
        _ = try tree.validateCurrentPath(readOnly: true)
        return .init(tree: tree,configuration: configuration,fingerprint: checked.0,witness: checked.1)
    }
}

/// Descriptor witness only. The helper receives no deletion authority.
public final class LiveASRReadOnlySnapshot: Sendable {
    public let configuration: LiveASRConfiguration
    public let fingerprint: String
    public let metadata: LiveASRMetadataWitness
    private let snapshot: OwnedReadOnlySnapshot
    fileprivate init(_ snapshot: OwnedReadOnlySnapshot) throws {
        guard case .asr(let configuration) = snapshot.configuration, case .asr(let metadata) = snapshot.witness else { throw LiveASRAssetError.invalidAsset }
        self.snapshot = snapshot; self.configuration = configuration; fingerprint = snapshot.fingerprint; self.metadata = metadata
    }
    public func validateCurrentPath() throws -> URL { try snapshot.validateCurrentPath() }
    public static func open(_ configuration: LiveASRConfiguration) throws -> LiveASRReadOnlySnapshot {
        try open(configuration,testingStagingDirectory: nil)
    }
    package static func open(_ configuration: LiveASRConfiguration,testingStagingDirectory: URL?) throws -> LiveASRReadOnlySnapshot {
        try .init(OwnedReadOnlySnapshot.open(.asr(configuration),testingStagingDirectory: testingStagingDirectory))
    }
}

/// A helper can retain/read the exact snapshot but cannot delete it.
public final class LiveDiarizationReadOnlySnapshot: Sendable {
    public let configuration: LiveDiarizationConfiguration
    public let fingerprint: String
    public let metadata: LiveDiarizationMetadataWitness
    private let snapshot: OwnedReadOnlySnapshot
    fileprivate init(_ snapshot: OwnedReadOnlySnapshot) throws {
        guard case .diarization(let configuration) = snapshot.configuration, case .diarization(let metadata) = snapshot.witness else { throw LiveASRAssetError.invalidAsset }
        self.snapshot = snapshot; self.configuration = configuration; fingerprint = snapshot.fingerprint; self.metadata = metadata
    }
    public func validateCurrentPath() throws -> URL { try snapshot.validateCurrentPath() }
    public static func open(_ configuration: LiveDiarizationConfiguration) throws -> LiveDiarizationReadOnlySnapshot {
        try open(configuration,testingStagingDirectory: nil)
    }
    package static func open(_ configuration: LiveDiarizationConfiguration,testingStagingDirectory: URL?) throws -> LiveDiarizationReadOnlySnapshot {
        try .init(OwnedReadOnlySnapshot.open(.diarization(configuration),testingStagingDirectory: testingStagingDirectory))
    }
}

/// Cooperating owners retain this private namespace until native work joins.
public final class LiveASRModelAssets: Sendable {
    public struct Limits: Sendable {
        public var maximumFileBytes: UInt64 = 2 * 1_073_741_824
        public var maximumTotalBytes: UInt64 = 8 * 1_073_741_824
        public init() {}
        fileprivate var isValid: Bool { (1...2 * 1_073_741_824).contains(maximumFileBytes) && (1...8 * 1_073_741_824).contains(maximumTotalBytes) }
    }
    public enum CopyPoint: Sendable { case beforeOpenFile, afterOpenFile, afterCreateDirectory, beforePublish }
    public typealias Probe = @Sendable (CopyPoint,String) async throws -> Void
    public let configuration: LiveASRConfiguration
    private let assets: OwnedModelAssets
    public convenience init(sourceDirectory: URL,identity: LiveASRIdentity,language: LiveASRConfiguration.Language,chunkMs: Int) throws {
        try self.init(sourceDirectory: sourceDirectory,identity: identity,language: language,chunkMs: chunkMs,budget: .shared,testingStagingDirectory: nil)
    }
    package init(sourceDirectory: URL,identity: LiveASRIdentity,language: LiveASRConfiguration.Language,chunkMs: Int,
                 budget: LiveASRStagingBudget,testingStagingDirectory: URL?,limits: Limits = .init(),probe: Probe? = nil) throws {
        assets = try .init(sourceDirectory: sourceDirectory,identity: .asr(identity,language,chunkMs),budget: budget,
            testingStagingDirectory: testingStagingDirectory,limits: limits,probe: probe)
        guard case .asr(let configuration) = assets.configuration else { throw LiveASRAssetError.invalidConfiguration }
        self.configuration = configuration
    }
    public func bind(to owner: UUID) -> Bool { assets.bind(to: owner) }
    public func prepare(owner: UUID) async throws { try await assets.prepare(owner: owner) }
    public func snapshot(owner: UUID) throws -> LiveASRReadOnlySnapshot { try .init(assets.snapshot(owner: owner)) }
    @discardableResult public func retire(owner: UUID) -> Task<Void,Never>? { assets.retire(owner: owner) }
}

public final class LiveDiarizationModelAssets: Sendable {
    public typealias Limits = LiveASRModelAssets.Limits
    public typealias CopyPoint = LiveASRModelAssets.CopyPoint
    public typealias Probe = LiveASRModelAssets.Probe
    public let configuration: LiveDiarizationConfiguration
    private let assets: OwnedModelAssets
    public convenience init(sourceDirectory: URL,identity: LiveDiarizationIdentity) throws {
        try self.init(sourceDirectory: sourceDirectory,identity: identity,budget: .shared,testingStagingDirectory: nil)
    }
    package init(sourceDirectory: URL,identity: LiveDiarizationIdentity,budget: LiveASRStagingBudget,
                 testingStagingDirectory: URL?,limits: Limits = .init(),probe: Probe? = nil) throws {
        assets = try .init(sourceDirectory: sourceDirectory,identity: .diarization(identity),budget: budget,
            testingStagingDirectory: testingStagingDirectory,limits: limits,probe: probe)
        guard case .diarization(let configuration) = assets.configuration else { throw LiveASRAssetError.invalidConfiguration }
        self.configuration = configuration
    }
    public func bind(to owner: UUID) -> Bool { assets.bind(to: owner) }
    public func prepare(owner: UUID) async throws { try await assets.prepare(owner: owner) }
    public func snapshot(owner: UUID) throws -> LiveDiarizationReadOnlySnapshot { try .init(assets.snapshot(owner: owner)) }
    @discardableResult public func retire(owner: UUID) -> Task<Void,Never>? { assets.retire(owner: owner) }
}

/// Shared descriptor copying/cleanup, with a closed typed format selection.
/// No CoreML constructor, package compiler or downloader is invoked here.
private final class OwnedModelAssets: Sendable {
    typealias Limits = LiveASRModelAssets.Limits
    typealias Probe = LiveASRModelAssets.Probe
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: UUID?; private var used = false; private var retired = false
        private var ready: ASROwnedSnapshot?
        func bind(_ value: UUID) -> Bool {
            lock.withLock { guard !used, !retired, owner == nil || owner == value else { return false }; owner = value; return true }
        }
        func begin(_ value: UUID) -> Bool {
            lock.withLock { guard owner == value, !used, !retired else { return false }; used = true; return true }
        }
        func active(_ value: UUID) -> Bool { lock.withLock { owner == value && !retired } }
        func publish(_ value: ASROwnedSnapshot, owner: UUID) -> Bool {
            lock.withLock { guard self.owner == owner, !retired, ready == nil else { return false }; ready = value; return true }
        }
        func snapshot(_ owner: UUID) throws -> OwnedReadOnlySnapshot {
            try lock.withLock {
                guard self.owner == owner, !retired, let ready else { throw LiveASRAssetError.invalidAsset }
                return ready.snapshot
            }
        }
        func retire(_ value: UUID?) -> ASROwnedSnapshot? {
            lock.withLock {
                guard value == nil || owner == value else { return nil }
                retired = true; let original = ready; ready = nil; return original
            }
        }
    }
    let configuration: OwnedModelConfiguration
    private let sourceDirectory: URL
    private let parent: ASRDirectory
    private let parentPath: String
    private let name: String
    private let budget: LiveASRStagingBudget
    private let limits: Limits
    private let probe: Probe?
    private let state = State()

    init(sourceDirectory: URL,identity: OwnedModelIdentity,budget: LiveASRStagingBudget,testingStagingDirectory: URL?,
         limits: Limits = .init(),probe: Probe? = nil) throws {
        guard identity.supported, limits.isValid, LiveASRIdentity.validPath(sourceDirectory.path) else { throw LiveASRAssetError.invalidConfiguration }
        let temporary = try testingStagingDirectory ?? ASRAssetTree.systemTemporaryDirectory()
        parent = try ASRAssetTree.directory(path: temporary.path); try ASRAssetTree.privateParent(parent)
        parentPath = try ASRAssetTree.path(parent.fd); name = identity.namespace + UUID().uuidString.lowercased()
        configuration = identity.configuration(path: parentPath + "/" + name)
        self.sourceDirectory = sourceDirectory; self.budget = budget; self.limits = limits; self.probe = probe
    }
    deinit {
        if let owned = state.retire(nil) { Task.detached { owned.cleanup() } }
    }
    public func bind(to owner: UUID) -> Bool { state.bind(owner) }
    func snapshot(owner: UUID) throws -> OwnedReadOnlySnapshot { try state.snapshot(owner) }

    /// The async caller may await real copying; hardware Stop only seals State.
    public func prepare(owner: UUID) async throws {
        guard state.begin(owner) else { throw LiveASRAssetError.invalidConfiguration }
        let ticket = try budget.beginWorker(kind: configuration.stagingKind)
        let worker = Task.detached(priority: .utility) { [self] in
            defer { budget.finishWorker(ticket) }
            var owned: ASROwnedSnapshot?
            var created: [ASRTreeEntry] = [], copied: [ASRTreeEntry] = []
            var unrecordedDirectory = false
            do {
                try check(owner)
                let sourceRoot = try ASRAssetTree.directory(path: sourceDirectory.path)
                // Reject a private staging parent nested inside this cache.
                _ = try ASRAssetTree.directory(path: parentPath,rejecting: sourceRoot.identity)
                let source = try ASRAssetTree.scan(root: sourceRoot,parent: nil,name: "",path: sourceDirectory.path,limits: limits,configuration: configuration,readOnly: false)
                try budget.allocate(ticket,bytes: source.totalBytes,parent: parent.fd); try check(owner)
                let root = try await createDirectory(parent,name: name,path: "",created: &created,unrecorded: &unrecordedDirectory,owner: owner,ticket: ticket)
                var directories = ["":root]
                for entry in source.entries {
                    try check(owner)
                    let parentPath = entry.path.split(separator: "/").dropLast().joined(separator: "/")
                    guard let destinationParent = directories[parentPath] else { throw LiveASRAssetError.invalidAsset }
                    if entry.directory != nil {
                        let child = try await createDirectory(destinationParent,name: entry.name,path: entry.path,created: &created,unrecorded: &unrecordedDirectory,owner: owner,ticket: ticket)
                        directories[entry.path] = child
                        copied.append(created.last!)
                    } else {
                        try await probe?(.beforeOpenFile,entry.path); try check(owner)
                        let input = openat(entry.parent.fd,entry.name,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                        guard input >= 0 else { throw LiveASRAssetError.invalidAsset }; defer { close(input) }
                        var before = stat()
                        guard fstat(input,&before) == 0, ASRFileIdentity(before) == entry.identity, before.st_size >= 0,
                              UInt64(before.st_size) == entry.size, ASRAssetTree.matches(entry) else { throw LiveASRAssetError.invalidAsset }
                        try await probe?(.afterOpenFile,entry.path); try check(owner)
                        let output = openat(destinationParent.fd,entry.name,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
                        guard output >= 0 else { throw LiveASRAssetError.invalidAsset }; defer { close(output) }
                        var info = stat()
                        guard fstat(output,&info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw LiveASRAssetError.invalidAsset }
                        copied.append(.init(path: entry.path,parent: destinationParent,name: entry.name,identity: .init(info),size: entry.size,directory: nil))
                        var count: UInt64 = 0, buffer = [UInt8](repeating: 0,count: 65_536)
                        while true {
                            try check(owner)
                            let amount = buffer.withUnsafeMutableBytes { Darwin.read(input,$0.baseAddress!,$0.count) }
                            if amount < 0 { if errno == EINTR { continue }; throw LiveASRAssetError.invalidAsset }
                            if amount == 0 { break }
                            guard UInt64(amount) <= entry.size-count else { throw LiveASRAssetError.oversized }
                            try budget.checkDisk(ticket,parent: parent.fd); try check(owner)
                            try buffer.withUnsafeBytes { try ASRAssetTree.write(UnsafeRawBufferPointer(start: $0.baseAddress,count: amount),fd: output) }
                            count += UInt64(amount)
                        }
                        var after = stat()
                        guard count == entry.size, fstat(input,&after) == 0, ASRFileIdentity(after) == entry.identity,
                              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, ASRAssetTree.matches(entry),
                              fsync(output) == 0, fchmod(output,0o444) == 0 else { throw LiveASRAssetError.invalidAsset }
                    }
                }
                for entry in created.reversed() where !entry.path.isEmpty {
                    guard let directory = entry.directory, fchmod(directory.fd,0o555) == 0 else { throw LiveASRAssetError.invalidAsset }
                }
                let tree = ASRAssetTree(root: root,parent: parent,name: name,path: configuration.path,entries: copied,totalBytes: source.totalBytes,configuration: configuration)
                let checked = try tree.fingerprint(configuration)
                let snapshot = OwnedReadOnlySnapshot(tree: tree,configuration: configuration,fingerprint: checked.0,witness: checked.1)
                let prepared = ASROwnedSnapshot(snapshot: snapshot,created: created,leaves: copied.filter { $0.directory == nil },budget: budget,ticket: ticket)
                owned = prepared
                _ = try snapshot.validateCurrentPath()
                try await probe?(.beforePublish,""); try check(owner)
                guard state.publish(prepared,owner: owner) else { throw CancellationError() }
            } catch {
                if let owned { owned.cleanup() }
                else {
                    let removed = ASROwnedSnapshot.cleanup(created: created,leaves: copied.filter { $0.directory == nil })
                    budget.rootDeleted(ticket,proven: !unrecordedDirectory && removed)
                }
                throw error
            }
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    @discardableResult public func retire(owner: UUID) -> Task<Void,Never>? {
        guard let original = state.retire(owner) else { return nil }
        return Task.detached { original.cleanup() }
    }
    private func check(_ owner: UUID) throws {
        try Task.checkCancellation(); guard state.active(owner) else { throw CancellationError() }
    }
    private func createDirectory(_ parent: ASRDirectory, name: String, path: String, created: inout [ASRTreeEntry],
                                 unrecorded: inout Bool, owner: UUID, ticket: UUID) async throws -> ASRDirectory {
        try check(owner); try budget.checkDisk(ticket,parent: self.parent.fd)
        guard mkdirat(parent.fd,name,0o700) == 0 else { throw LiveASRAssetError.invalidAsset }
        unrecorded = true
        var info = stat()
        guard fstatat(parent.fd,name,&info,AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw LiveASRAssetError.invalidAsset }
        let identity = ASRFileIdentity(info)
        // Record the named entry before open/probe; failed open still cleans it.
        created.append(.init(path: path,parent: parent,name: name,identity: identity,size: 0,directory: nil))
        unrecorded = false
        let child = try ASRDirectory(taking: openat(parent.fd,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
        guard child.identity == identity, ASRAssetTree.matches(created.last!) else { throw LiveASRAssetError.invalidAsset }
        created[created.count-1] = .init(path: path,parent: parent,name: name,identity: identity,size: 0,directory: child)
        try await probe?(.afterCreateDirectory,path); try check(owner)
        return child
    }
}

private final class ASROwnedSnapshot: @unchecked Sendable {
    let snapshot: OwnedReadOnlySnapshot
    private let created: [ASRTreeEntry]; private let leaves: [ASRTreeEntry]
    private let budget: LiveASRStagingBudget; private let ticket: UUID
    private let lock = NSLock(); private var cleaned = false
    init(snapshot: OwnedReadOnlySnapshot, created: [ASRTreeEntry], leaves: [ASRTreeEntry], budget: LiveASRStagingBudget, ticket: UUID) {
        self.snapshot = snapshot; self.created = created; self.leaves = leaves; self.budget = budget; self.ticket = ticket
    }
    func cleanup() {
        lock.withLock {
            guard !cleaned else { return }; cleaned = true
            budget.rootDeleted(ticket,proven: Self.cleanup(created: created,leaves: leaves))
        }
    }
    static func cleanup(created: [ASRTreeEntry], leaves: [ASRTreeEntry]) -> Bool {
        for entry in created { if let directory = entry.directory { _ = fchmod(directory.fd,0o700) } }
        var proven = true
        for entry in leaves {
            if !ASRAssetTree.matches(entry) || unlinkat(entry.parent.fd,entry.name,0) != 0 { proven = false }
        }
        for entry in created.reversed() {
            if !ASRAssetTree.matches(entry) || unlinkat(entry.parent.fd,entry.name,AT_REMOVEDIR) != 0 { proven = false }
        }
        // APFS can keep a nonzero nlink on an open unlinked directory. Successful
        // unlink receipts for every owned entry prove deletion; nlink does not.
        return proven
    }
}

private final class ASRAssetTree: Sendable {
    let root: ASRDirectory; let parent: ASRDirectory?; let name: String; let rootPath: String
    let entries: [ASRTreeEntry]; let totalBytes: UInt64; let configuration: OwnedModelConfiguration
    static let models: Set<String> = ["encoder.mlmodelc","decoder.mlmodelc","joint.mlmodelc","preprocessor.mlmodelc",
        "decoder_joint_argmax.mlmodelc","decoder_joint_noencproj.mlmodelc","decoder_joint.mlmodelc","joint_noencproj_batched.mlmodelc"]
    init(root: ASRDirectory, parent: ASRDirectory?, name: String, path: String, entries: [ASRTreeEntry], totalBytes: UInt64, configuration: OwnedModelConfiguration) {
        self.root = root; self.parent = parent; self.name = name; rootPath = path; self.entries = entries; self.totalBytes = totalBytes; self.configuration = configuration
    }
    static func scan(root: ASRDirectory, parent: ASRDirectory?, name: String, path: String,
                     limits: LiveASRModelAssets.Limits, configuration: OwnedModelConfiguration, readOnly: Bool) throws -> ASRAssetTree {
        var entries: [ASRTreeEntry] = [], total: UInt64 = 0
        func walk(_ directory: ASRDirectory, prefix: String, depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 8 else { throw LiveASRAssetError.oversized }
            for name in try names(directory.fd) {
                guard entries.count < 512 else { throw LiveASRAssetError.oversized }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                guard path.utf8.count <= 4096 else { throw LiveASRAssetError.oversized }
                var info = stat()
                guard fstatat(directory.fd,name,&info,AT_SYMLINK_NOFOLLOW) == 0 else { throw LiveASRAssetError.invalidAsset }
                let identity = ASRFileIdentity(info)
                if identity.type == S_IFDIR {
                    let child = try ASRDirectory(taking: openat(directory.fd,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
                    guard child.identity == identity else { throw LiveASRAssetError.invalidAsset }
                    entries.append(.init(path: path,parent: directory,name: name,identity: identity,size: 0,directory: child))
                    try walk(child,prefix: path,depth: depth+1)
                } else {
                    guard identity.type == S_IFREG, info.st_size >= 0 else { throw LiveASRAssetError.invalidAsset }
                    let size = UInt64(info.st_size), sum = total.addingReportingOverflow(size)
                    guard size <= limits.maximumFileBytes, !sum.overflow, sum.partialValue <= limits.maximumTotalBytes else { throw LiveASRAssetError.oversized }
                    total = sum.partialValue
                    entries.append(.init(path: path,parent: directory,name: name,identity: identity,size: size,directory: nil))
                }
            }
        }
        try walk(root,prefix: "",depth: 0)
        let tree = ASRAssetTree(root: root,parent: parent,name: name,path: path,entries: entries,totalBytes: total,configuration: configuration)
        try tree.validateLayout()
        _ = try tree.validateCurrentPath(readOnly: readOnly)
        return tree
    }
    private func validateLayout() throws {
        if case .diarization(let c) = configuration {
            let top = entries.filter { !$0.path.contains("/") }
            guard Set(top.filter { $0.directory != nil }.map(\.name)) == [c.identity.preset.modelFileName],
                  Set(top.filter { $0.directory == nil }.map(\.name)) == ["learnable_sil_emb.bin",".fluidaudio-nemotron3-weights"],
                  let embedding = top.first(where: { $0.name == "learnable_sil_emb.bin" }), embedding.size == 2048,
                  let marker = top.first(where: { $0.name == ".fluidaudio-nemotron3-weights" }), (1...256).contains(marker.size),
                  let metadata = entries.first(where: { $0.path == c.identity.preset.modelFileName + "/metadata.json" && $0.directory == nil }),
                  (1...UInt64(LiveDiarizationMetadataWitness.maximumMetadataBytes)).contains(metadata.size) else {
                throw LiveASRAssetError.invalidAsset
            }
            return
        }
        let top = entries.filter { !$0.path.contains("/") }, modelNames = Set(top.filter { $0.directory != nil }.map(\.name))
        guard Set(top.filter { $0.directory == nil }.map(\.name)) == ["metadata.json","tokenizer.json"],
              modelNames.contains("encoder.mlmodelc"), modelNames.isSubset(of: Self.models),
              modelNames.contains("decoder.mlmodelc") && modelNames.contains("joint.mlmodelc") ||
                !modelNames.isDisjoint(with: ["decoder_joint_argmax.mlmodelc","decoder_joint_noencproj.mlmodelc","decoder_joint.mlmodelc"]) else {
            throw LiveASRAssetError.invalidAsset
        }
        if modelNames.contains("joint_noencproj_batched.mlmodelc") {
            guard modelNames.contains("decoder.mlmodelc"), modelNames.contains("joint.mlmodelc") else { throw LiveASRAssetError.invalidAsset }
        }
        for model in modelNames {
            guard entries.contains(where: { $0.directory == nil && $0.size > 0 && $0.path.hasPrefix(model + "/") }) else { throw LiveASRAssetError.invalidAsset }
        }
        guard let metadata = top.first(where: { $0.name == "metadata.json" }), metadata.size > 0, metadata.size <= LiveASRModelContract.maximumMetadataBytes,
              let tokens = top.first(where: { $0.name == "tokenizer.json" }), tokens.size > 0, tokens.size <= LiveASRModelContract.maximumTokenizerBytes else {
            throw LiveASRAssetError.oversized
        }
    }
    func validateCurrentPath(readOnly: Bool) throws -> URL {
        try Task.checkCancellation()
        guard try Self.path(root.fd) == rootPath else { throw LiveASRAssetError.invalidAsset }
        if let parent { guard Self.matches(parent.fd,name: name,identity: root.identity) else { throw LiveASRAssetError.invalidAsset } }
        let reopened = try Self.directory(path: rootPath)
        guard reopened.identity == root.identity else { throw LiveASRAssetError.invalidAsset }
        var rootInfo = stat()
        guard fstat(root.fd,&rootInfo) == 0, !readOnly || rootInfo.st_uid == geteuid() && rootInfo.st_mode & 0o777 == 0o700 else { throw LiveASRAssetError.invalidAsset }
        var directories = ["":root]
        for entry in entries {
            guard Self.matches(entry) else { throw LiveASRAssetError.invalidAsset }
            var info = stat()
            guard fstatat(entry.parent.fd,entry.name,&info,AT_SYMLINK_NOFOLLOW) == 0 else { throw LiveASRAssetError.invalidAsset }
            if let child = entry.directory {
                if readOnly { guard info.st_mode & 0o777 == 0o555 else { throw LiveASRAssetError.invalidAsset } }
                directories[entry.path] = child
            } else {
                guard info.st_size >= 0, UInt64(info.st_size) == entry.size else { throw LiveASRAssetError.invalidAsset }
                if readOnly { guard info.st_nlink == 1, info.st_mode & 0o777 == 0o444 else { throw LiveASRAssetError.invalidAsset } }
            }
        }
        for (path,directory) in directories {
            let expected = entries.filter { $0.path.split(separator: "/").dropLast().joined(separator: "/") == path }.map(\.name).sorted()
            guard try Self.names(directory.fd) == expected else { throw LiveASRAssetError.invalidAsset }
        }
        return URL(fileURLWithPath: rootPath,isDirectory: true)
    }
    func fingerprint(_ configuration: OwnedModelConfiguration) throws -> (String,OwnedModelWitness) {
        try validateLayout(); _ = try validateCurrentPath(readOnly: true)
        var tree = SHA256(); tree.update(data: Data(configuration.domain.utf8))
        var metadata = Data(), tokenizer = Data(), embedding = Data(), marker = Data()
        let metadataPath: String
        switch configuration { case .asr: metadataPath = "metadata.json"; case .diarization(let c): metadataPath = c.identity.preset.modelFileName + "/metadata.json" }
        for entry in entries.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            try Task.checkCancellation()
            let path = Data(entry.path.utf8); tree.update(data: Data([entry.directory == nil ? 1 : 0]))
            var length = UInt32(path.count).littleEndian, size = entry.size.littleEndian
            withUnsafeBytes(of: &length) { tree.update(bufferPointer: $0) }; tree.update(data: path)
            withUnsafeBytes(of: &size) { tree.update(bufferPointer: $0) }
            if entry.directory != nil { continue }
            let fd = openat(entry.parent.fd,entry.name,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw LiveASRAssetError.invalidAsset }; defer { close(fd) }
            func validateFile() throws {
                var info = stat()
                guard fstat(fd,&info) == 0, ASRFileIdentity(info) == entry.identity, info.st_size >= 0, UInt64(info.st_size) == entry.size,
                      info.st_nlink == 1, info.st_mode & 0o777 == 0o444, Self.matches(entry) else { throw LiveASRAssetError.invalidAsset }
            }
            try validateFile()
            var hash = SHA256(), count: UInt64 = 0, buffer = [UInt8](repeating: 0,count: 65_536)
            while true {
                try Task.checkCancellation()
                let amount = buffer.withUnsafeMutableBytes { Darwin.read(fd,$0.baseAddress!,$0.count) }
                if amount < 0 { if errno == EINTR { continue }; throw LiveASRAssetError.invalidAsset }
                if amount == 0 { break }
                guard UInt64(amount) <= entry.size-count else { throw LiveASRAssetError.oversized }
                let bytes = Data(buffer.prefix(amount)); hash.update(data: bytes); count += UInt64(amount)
                if entry.path == metadataPath { metadata.append(bytes) }
                if case .asr = configuration, entry.path == "tokenizer.json" { tokenizer.append(bytes) }
                if case .diarization = configuration {
                    if entry.path == "learnable_sil_emb.bin" { embedding.append(bytes) }
                    if entry.path == ".fluidaudio-nemotron3-weights" { marker.append(bytes) }
                }
            }
            try validateFile(); guard count == entry.size else { throw LiveASRAssetError.invalidAsset }
            tree.update(data: Data(hash.finalize()))
        }
        let result = tree.finalize().map { String(format: "%02x",$0) }.joined()
        guard result == configuration.fingerprint else { throw LiveASRAssetError.fingerprintMismatch }
        let witness: OwnedModelWitness
        switch configuration {
        case .asr(let c): witness = .asr(try LiveASRModelContract.validate(metadata: metadata,tokenizer: tokenizer,configuration: c))
        case .diarization(let c): witness = .diarization(try .init(metadata: metadata,embedding: embedding,marker: marker,revision: c.identity.modelRevision))
        }
        _ = try validateCurrentPath(readOnly: true)
        return (result,witness)
    }
    static func matches(_ entry: ASRTreeEntry) -> Bool { matches(entry.parent.fd,name: entry.name,identity: entry.identity) }
    static func matches(_ parent: Int32, name: String, identity: ASRFileIdentity) -> Bool {
        var info = stat(); return fstatat(parent,name,&info,AT_SYMLINK_NOFOLLOW) == 0 && ASRFileIdentity(info) == identity
    }
    static func names(_ fd: Int32) throws -> [String] {
        let reopened = openat(fd,".",O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard reopened >= 0 else { throw LiveASRAssetError.invalidAsset }
        guard let stream = fdopendir(reopened) else { close(reopened); throw LiveASRAssetError.invalidAsset }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            try Task.checkCancellation(); errno = 0
            guard let next = readdir(stream) else { guard errno == 0 else { throw LiveASRAssetError.invalidAsset }; break }
            var bytes = next.pointee.d_name
            let name = withUnsafeBytes(of: &bytes) { raw -> String? in
                guard let end = raw.firstIndex(of: 0) else { return nil }; return String(bytes: raw[..<end],encoding: .utf8)
            }
            guard let name else { throw LiveASRAssetError.invalidAsset }
            if name == "." || name == ".." { continue }
            guard result.count < 512, !name.isEmpty, name.utf8.count <= 255,
                  !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), !name.contains("/") else { throw LiveASRAssetError.oversized }
            result.append(name)
        }
        return result.sorted()
    }
    static func directory(path: String, rejecting: ASRFileIdentity? = nil) throws -> ASRDirectory {
        guard LiveASRIdentity.validPath(path) else { throw LiveASRAssetError.invalidConfiguration }
        var directory = try ASRDirectory(taking: open("/",O_RDONLY | O_DIRECTORY | O_CLOEXEC))
        for part in path.split(separator: "/") {
            let child = try ASRDirectory(taking: openat(directory.fd,String(part),O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
            guard child.identity != rejecting else { throw LiveASRAssetError.invalidAsset }; directory = child
        }
        return directory
    }
    static func privateParent(_ parent: ASRDirectory) throws {
        var info = stat()
        guard fstat(parent.fd,&info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw LiveASRAssetError.invalidAsset }
    }
    static func path(_ fd: Int32) throws -> String {
        var buffer = [CChar](repeating: 0,count: Int(MAXPATHLEN))
        guard fcntl(fd,F_GETPATH,&buffer) == 0, let end = buffer.firstIndex(of: 0),
              let path = String(bytes: buffer[..<end].map { UInt8(bitPattern: $0) },encoding: .utf8) else { throw LiveASRAssetError.invalidAsset }
        return path
    }
    static func systemTemporaryDirectory() throws -> URL {
        var buffer = [CChar](repeating: 0,count: 4097)
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR,&buffer,buffer.count)
        guard length > 1, length <= buffer.count, let end = buffer.firstIndex(of: 0),
              let value = String(bytes: buffer[..<end].map { UInt8(bitPattern: $0) },encoding: .utf8) else { throw LiveASRAssetError.invalidAsset }
        // The OS supplies its /var alias. Canonicalize only this trusted parent;
        // caller model/configuration paths always use no-follow components.
        let parent = try ASRDirectory(taking: open(value,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        try privateParent(parent); return URL(fileURLWithPath: try path(parent.fd),isDirectory: true)
    }
    static func write(_ buffer: UnsafeRawBufferPointer, fd: Int32) throws {
        var offset = 0
        while offset < buffer.count {
            try Task.checkCancellation()
            let count = Darwin.write(fd,buffer.baseAddress!.advanced(by: offset),buffer.count-offset)
            if count < 0 { if errno == EINTR { continue }; throw LiveASRAssetError.invalidAsset }
            guard count > 0 else { throw LiveASRAssetError.invalidAsset }; offset += count
        }
    }
}
