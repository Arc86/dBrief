import CryptoKit
import Darwin
import Foundation
import dBriefWire

enum LiveVADAssetError: Error, Equatable { case invalidConfiguration, invalidAsset, oversized, fingerprintMismatch }

/// Private copies outside app/SDK cache purge domains. Cooperating code must
/// never rename/purge this namespace while any native work retains the owner.
/// Checks detect existing substitutions, not arbitrary later same-user writes.
/// This preparation invokes no CoreML, ModelHub or downloader operation.
final class LiveVADModelAssets: Sendable {
    struct Limits: Sendable {
        var maximumFileBytes: UInt64 = 16 * 1024 * 1024
        var maximumTotalBytes: UInt64 = 32 * 1024 * 1024
        var isValid: Bool { (1...16 * 1024 * 1024).contains(maximumFileBytes) && (1...32 * 1024 * 1024).contains(maximumTotalBytes) }
    }
    enum CopyPoint: Sendable { case beforeOpenFile, afterOpenFile, afterCreateDirectory }
    typealias Probe = @Sendable (CopyPoint, String) async throws -> Void
    private struct Entry: Sendable { let path: String; let size: UInt64; let hash: Data? }
    private struct Fingerprint { let value: String; let metadata: Entry }
    private struct Identity: Sendable, Equatable {
        let device: dev_t
        let inode: ino_t
        let type: mode_t
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino; type = info.st_mode & S_IFMT }
    }
    private final class Directory: Sendable {
        let fd: Int32
        let identity: Identity
        init(taking fd: Int32) throws {
            var info = stat()
            guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFDIR else { close(fd); throw LiveVADAssetError.invalidAsset }
            self.fd = fd; identity = Identity(info)
        }
        deinit { close(fd) }
    }
    private struct FileEntry: Sendable {
        let path: String
        let parent: Directory
        let name: String
        let identity: Identity
    }
    private struct DirectoryEntry: Sendable {
        let parent: Directory
        let name: String
        let identity: Identity
    }
    private static let files = ["analytics/coremldata.bin","coremldata.bin","metadata.json","model.mil","weights/weight.bin"]
    private static let directories = ["analytics","weights"]
    private static let supportedRevision = "silero-vad-unified-256ms-v6.2.1"
    let fingerprint: String
    let configuration: LiveVADConfiguration
    private let metadata: Entry
    private let parentURL: URL
    private let rootName: String
    private let parent: Directory
    private let root: Directory
    private let model: Directory
    private let children: [String: Directory]
    private let leaves: [FileEntry]
    private let created: [DirectoryEntry]
    private let opened: [Directory]

    /// The native loader must keep this asset owner strongly alive through the
    /// load, every returned model/manager and actual cancellation unwind.
    var modelDirectory: URL {
        get throws {
            let rootURL = parentURL.appendingPathComponent(rootName,isDirectory: true)
            guard try Self.path(parent.fd) == parentURL.path, try Self.path(root.fd) == rootURL.path,
                  Self.matches(parent.fd,name: rootName,identity: root.identity),
                  Self.matches(root.fd,name: "model.mlmodelc",identity: model.identity) else { throw LiveVADAssetError.invalidAsset }
            let absolute = try Self.directory(path: rootURL.path,checkCancellation: false)
            defer { close(absolute) }
            var info = stat()
            guard fstat(absolute,&info) == 0, Identity(info) == root.identity else { throw LiveVADAssetError.invalidAsset }
            try Self.exactNames(root.fd,expected: ["model.mlmodelc"],checkCancellation: false)
            try Self.exactNames(model.fd,expected: ["metadata.json","model.mil","coremldata.bin","analytics","weights"],checkCancellation: false)
            for (name,directory) in children {
                guard Self.matches(model.fd,name: name,identity: directory.identity) else { throw LiveVADAssetError.invalidAsset }
                try Self.exactNames(directory.fd,expected: [name == "analytics" ? "coremldata.bin" : "weight.bin"],checkCancellation: false)
            }
            for leaf in leaves {
                var info = stat()
                guard fstatat(leaf.parent.fd,leaf.name,&info,AT_SYMLINK_NOFOLLOW) == 0,
                      Identity(info) == leaf.identity, info.st_size > 0, info.st_nlink == 1,
                      info.st_mode & 0o777 == 0o444 else { throw LiveVADAssetError.invalidAsset }
            }
            return rootURL.appendingPathComponent("model.mlmodelc",isDirectory: true)
        }
    }
    private init(parentURL: URL, rootName: String, parent: Directory, root: Directory, model: Directory,
                 children: [String: Directory], leaves: [FileEntry], created: [DirectoryEntry], opened: [Directory],
                 configuration: LiveVADConfiguration, fingerprint: Fingerprint) {
        self.parentURL = parentURL; self.rootName = rootName; self.parent = parent; self.root = root; self.model = model
        self.children = children; self.leaves = leaves; self.fingerprint = fingerprint.value
        self.configuration = configuration; metadata = fingerprint.metadata
        self.created = created; self.opened = opened
    }
    deinit { Self.cleanup(created: created,opened: opened,leaves: leaves) }

    /// Only the copied, descriptor-owned leaf can supply the schema witness.
    /// Its length/digest were captured in the final snapshot hashing pass.
    func readMetadata(testingAfterOpen: (@Sendable () throws -> Void)? = nil) throws -> Data {
        try Task.checkCancellation()
        _ = try modelDirectory
        guard metadata.size <= LiveVADModelContract.maximumMetadataBytes else { throw LiveVADModelError.invalidModel }
        guard let leaf = leaves.first(where: { $0.path == "metadata.json" }) else { throw LiveVADAssetError.invalidAsset }
        let fd = openat(leaf.parent.fd,leaf.name,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw LiveVADAssetError.invalidAsset }
        defer { close(fd) }
        func validateLeaf() throws {
            var info = stat()
            guard fstat(fd,&info) == 0, Identity(info) == leaf.identity, info.st_size > 0,
                  UInt64(info.st_size) == metadata.size, info.st_mode & 0o777 == 0o444, info.st_nlink == 1,
                  Self.matches(leaf.parent.fd,name: leaf.name,identity: leaf.identity) else { throw LiveVADAssetError.invalidAsset }
        }
        try validateLeaf()
        try testingAfterOpen?()
        var data = Data(), buffer = [UInt8](repeating: 0,count: LiveVADModelContract.maximumMetadataBytes)
        data.reserveCapacity(Int(metadata.size))
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd,$0.baseAddress!, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw LiveVADAssetError.invalidAsset }
            if count == 0 { break }
            guard count <= LiveVADModelContract.maximumMetadataBytes-data.count else { throw LiveVADModelError.invalidModel }
            data.append(contentsOf: buffer.prefix(count))
        }
        try validateLeaf(); try Task.checkCancellation()
        guard UInt64(data.count) == metadata.size, Data(SHA256.hash(data: data)) == metadata.hash else {
            throw LiveVADAssetError.fingerprintMismatch
        }
        return data
    }

    /// The staging URL/probe are explicit trusted-owner test seams. Production
    /// callers omit both; configuration can never select a staging namespace.
    static func prepare(_ configuration: LiveVADConfiguration, testingStagingDirectory: URL? = nil,
                        limits: Limits = .init(), probe: Probe? = nil) async throws -> LiveVADModelAssets {
        guard configuration.isValid, configuration.identity.runtimeRevision == LiveVADNativeConfiguration.runtimeRevision,
              configuration.identity.implementationRevision == LiveVADIdentity.currentImplementationRevision,
              configuration.identity.modelRevision == supportedRevision, limits.isValid else { throw LiveVADAssetError.invalidConfiguration }
        try Task.checkCancellation()
        let source = try Directory(taking: directory(path: configuration.modelPath))
        try exactNames(source.fd,expected: ["metadata.json","model.mil","coremldata.bin","analytics","weights"])
        var sourceDirectories: [String: Directory] = [:]
        for name in directories {
            let child = try Directory(taking: childDirectory(source.fd,name: name)); sourceDirectories[name] = child
            try exactNames(child.fd,expected: [name == "analytics" ? "coremldata.bin" : "weight.bin"])
        }
        let parentURL = try testingStagingDirectory ?? systemTemporaryDirectory()
        let parent = try Directory(taking: directory(path: parentURL.path,rejecting: source.identity))
        var parentInfo = stat()
        guard fstat(parent.fd,&parentInfo) == 0, parentInfo.st_uid == geteuid(), parentInfo.st_mode & 0o077 == 0 else {
            throw LiveVADAssetError.invalidAsset
        }
        let name = "dbrief-vad-\(UUID())"
        var created: [DirectoryEntry] = [], opened: [Directory] = [], children: [String: Directory] = [:], leaves: [FileEntry] = []
        var transferred = false
        defer { if !transferred { cleanup(created: created,opened: opened,leaves: leaves) } }
        let root = try await createDirectory(parent,name: name,created: &created,opened: &opened,probe: probe)
        let destination = try await createDirectory(root,name: "model.mlmodelc",created: &created,opened: &opened,probe: probe)
        for directoryName in directories {
            children[directoryName] = try await createDirectory(destination,name: directoryName,created: &created,opened: &opened,probe: probe)
        }
        var total: UInt64 = 0
        for path in files {
            try Task.checkCancellation()
            let parts = path.split(separator: "/").map(String.init), fileName = parts.last!
            let from = parts.count == 1 ? source : sourceDirectories[parts[0]]!
            let to = parts.count == 1 ? destination : children[parts[0]]!
            try await probe?(.beforeOpenFile,path); try Task.checkCancellation()
            let file = openat(from.fd,fileName,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else { throw LiveVADAssetError.invalidAsset }
            defer { close(file) }
            var info = stat()
            guard fstat(file,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else { throw LiveVADAssetError.invalidAsset }
            guard UInt64(info.st_size) <= limits.maximumFileBytes else { throw LiveVADAssetError.oversized }
            try await probe?(.afterOpenFile,path); try Task.checkCancellation()
            let output = openat(to.fd,fileName,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
            guard output >= 0 else { throw LiveVADAssetError.invalidAsset }
            defer { close(output) }
            var outputInfo = stat()
            guard fstat(output,&outputInfo) == 0, outputInfo.st_mode & S_IFMT == S_IFREG else { throw LiveVADAssetError.invalidAsset }
            leaves.append(.init(path: path,parent: to,name: fileName,identity: Identity(outputInfo)))
            var size: UInt64 = 0, buffer = [UInt8](repeating: 0,count: 65_536)
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { Darwin.read(file,$0.baseAddress!, $0.count) }
                if count < 0 { if errno == EINTR { continue }; throw LiveVADAssetError.invalidAsset }
                if count == 0 { break }
                try account(count,size: &size,total: &total,limits: limits)
                try buffer.withUnsafeBytes { bytes in try write(UnsafeRawBufferPointer(start: bytes.baseAddress,count: count),to: output) }
            }
            guard size > 0, fsync(output) == 0, fchmod(output,0o444) == 0 else { throw LiveVADAssetError.invalidAsset }
        }
        // Read the final copied tree, not a manifest of earlier source reads.
        // This also catches mutation of an already copied leaf at a later probe.
        let fingerprint = try fingerprintCopiedTree(leaves,limits: limits)
        guard fingerprint.value == configuration.identity.modelFingerprint else { throw LiveVADAssetError.fingerprintMismatch }
        for directory in children.values { guard fchmod(directory.fd,0o555) == 0 else { throw LiveVADAssetError.invalidAsset } }
        guard fchmod(destination.fd,0o555) == 0 else { throw LiveVADAssetError.invalidAsset }
        try Task.checkCancellation()
        let assets = LiveVADModelAssets(parentURL: parentURL,rootName: name,parent: parent,root: root,model: destination,
            children: children,leaves: leaves,created: created,opened: opened,configuration: configuration,fingerprint: fingerprint)
        transferred = true // This owner now cleans failures during publication too.
        _ = try assets.modelDirectory
        return assets
    }

    private static func systemTemporaryDirectory() throws -> URL {
        var buffer = [CChar](repeating: 0,count: 4097)
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR,&buffer,buffer.count)
        guard length > 1, length <= buffer.count, let value = string(buffer) else { throw LiveVADAssetError.invalidAsset }
        // Open only the OS-derived path (which includes the system /var alias),
        // then use its kernel pathname. Foundation can rewrite /private/var
        // back to /var even after resolvingSymlinksInPath.
        let fd = open(value,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LiveVADAssetError.invalidAsset }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw LiveVADAssetError.invalidAsset }
        return URL(fileURLWithPath: try path(fd),isDirectory: true)
    }
    private static func createDirectory(_ parent: Directory, name: String, created: inout [DirectoryEntry],
                                        opened: inout [Directory], probe: Probe?) async throws -> Directory {
        guard mkdirat(parent.fd,name,0o700) == 0 else { throw LiveVADAssetError.invalidAsset }
        var info = stat()
        guard fstatat(parent.fd,name,&info,AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw LiveVADAssetError.invalidAsset }
        let identity = Identity(info)
        // No new FD is needed for this receipt; EMFILE during the following
        // open still leaves enough ownership proof to remove the empty entry.
        created.append(.init(parent: parent,name: name,identity: identity))
        try await probe?(.afterCreateDirectory,name)
        try Task.checkCancellation()
        let directory = try Directory(taking: childDirectory(parent.fd,name: name))
        guard directory.identity == identity else { throw LiveVADAssetError.invalidAsset }
        opened.append(directory)
        return directory
    }
    private static func directory(path: String, rejecting original: Identity? = nil, checkCancellation: Bool = true) throws -> Int32 {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0"),
              path.split(separator: "/",omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LiveVADAssetError.invalidAsset
        }
        var fd = open("/",O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LiveVADAssetError.invalidAsset }
        do {
            for component in path.split(separator: "/") {
                if checkCancellation { try Task.checkCancellation() }
                let next = try childDirectory(fd,name: String(component)); close(fd); fd = next
                if let original {
                    var info = stat()
                    guard fstat(fd,&info) == 0, Identity(info) != original else { throw LiveVADAssetError.invalidAsset }
                }
            }
            return fd
        } catch { close(fd); throw error }
    }
    private static func childDirectory(_ parent: Int32, name: String) throws -> Int32 {
        let fd = openat(parent,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LiveVADAssetError.invalidAsset }
        return fd
    }
    private static func exactNames(_ fd: Int32, expected: Set<String>, checkCancellation: Bool = true) throws {
        // dup shares the directory offset and would make repeated validation
        // observe EOF. A new descriptor relative to the owned directory does not.
        let copy = try childDirectory(fd,name: ".")
        guard let stream = fdopendir(copy) else { close(copy); throw LiveVADAssetError.invalidAsset }
        defer { closedir(stream) }
        var names: Set<String> = []
        while true {
            if checkCancellation { try Task.checkCancellation() }; errno = 0
            guard let entry = readdir(stream) else { if errno != 0 { throw LiveVADAssetError.invalidAsset }; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self,capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw LiveVADAssetError.invalidAsset }
            if name == "." || name == ".." { continue }
            guard names.count < 8, expected.contains(name), names.insert(name).inserted else { throw LiveVADAssetError.invalidAsset }
        }
        guard names == expected else { throw LiveVADAssetError.invalidAsset }
    }
    private static func write(_ bytes: UnsafeRawBufferPointer, to fd: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            let count = Darwin.write(fd,bytes.baseAddress!.advanced(by: offset),bytes.count-offset)
            if count < 0 { if errno == EINTR { continue }; throw LiveVADAssetError.invalidAsset }
            guard count > 0 else { throw LiveVADAssetError.invalidAsset }
            offset += count
        }
    }
    private static func account(_ count: Int, size: inout UInt64, total: inout UInt64, limits: Limits) throws {
        let nextSize = size.addingReportingOverflow(UInt64(count)), nextTotal = total.addingReportingOverflow(UInt64(count))
        guard !nextSize.overflow, !nextTotal.overflow, nextSize.partialValue <= limits.maximumFileBytes,
              nextTotal.partialValue <= limits.maximumTotalBytes else { throw LiveVADAssetError.oversized }
        size = nextSize.partialValue; total = nextTotal.partialValue
    }
    private static func fingerprintCopiedTree(_ leaves: [FileEntry], limits: Limits) throws -> Fingerprint {
        var entries = directories.map { Entry(path: $0,size: 0,hash: nil) }, total: UInt64 = 0
        for leaf in leaves {
            let file = openat(leaf.parent.fd,leaf.name,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else { throw LiveVADAssetError.invalidAsset }
            defer { close(file) }
            var info = stat()
            guard fstat(file,&info) == 0, Identity(info) == leaf.identity, info.st_size > 0,
                  info.st_nlink == 1, info.st_mode & 0o777 == 0o444 else { throw LiveVADAssetError.invalidAsset }
            var hash = SHA256(), size: UInt64 = 0, buffer = [UInt8](repeating: 0,count: 65_536)
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { Darwin.read(file,$0.baseAddress!, $0.count) }
                if count < 0 { if errno == EINTR { continue }; throw LiveVADAssetError.invalidAsset }
                if count == 0 { break }
                try account(count,size: &size,total: &total,limits: limits)
                buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(start: $0.baseAddress,count: count)) }
            }
            guard size > 0 else { throw LiveVADAssetError.invalidAsset }
            entries.append(.init(path: leaf.path,size: size,hash: Data(hash.finalize())))
        }
        var tree = SHA256(); tree.update(data: Data("dBrief.VADAssets.v1\0".utf8))
        for entry in entries.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            let path = Data(entry.path.utf8)
            tree.update(data: Data([entry.hash == nil ? 0 : 1]))
            var length = UInt32(path.count).littleEndian, size = entry.size.littleEndian
            withUnsafeBytes(of: &length) { tree.update(bufferPointer: $0) }; tree.update(data: path)
            withUnsafeBytes(of: &size) { tree.update(bufferPointer: $0) }
            if let hash = entry.hash { tree.update(data: hash) }
        }
        guard let metadata = entries.first(where: { $0.path == "metadata.json" }), metadata.hash != nil else { throw LiveVADAssetError.invalidAsset }
        return .init(value: tree.finalize().map { String(format: "%02x",$0) }.joined(),metadata: metadata)
    }
    private static func matches(_ parent: Int32, name: String, identity: Identity) -> Bool {
        var info = stat()
        return fstatat(parent,name,&info,AT_SYMLINK_NOFOLLOW) == 0 && Identity(info) == identity
    }
    private static func path(_ fd: Int32) throws -> String {
        var buffer = [CChar](repeating: 0,count: Int(MAXPATHLEN))
        guard fcntl(fd,F_GETPATH,&buffer) == 0, let value = string(buffer) else { throw LiveVADAssetError.invalidAsset }
        return value
    }
    private static func string(_ buffer: [CChar]) -> String? {
        guard let end = buffer.firstIndex(of: 0) else { return nil }
        return String(bytes: buffer[..<end].map { UInt8(bitPattern: $0) },encoding: .utf8)
    }
    /// Never follow cleanup paths. Deliberate replacement leaves that external
    /// link untouched and can leave an empty owned orphan; no recursive reaper.
    private static func cleanup(created: [DirectoryEntry], opened: [Directory], leaves: [FileEntry]) {
        for directory in opened { _ = fchmod(directory.fd,0o700) }
        for leaf in leaves where matches(leaf.parent.fd,name: leaf.name,identity: leaf.identity) { _ = unlinkat(leaf.parent.fd,leaf.name,0) }
        for entry in created.reversed() where matches(entry.parent.fd,name: entry.name,identity: entry.identity) {
            _ = unlinkat(entry.parent.fd,entry.name,AT_REMOVEDIR)
        }
    }
}
