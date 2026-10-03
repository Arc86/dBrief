@preconcurrency import CoreML
import Foundation
import dBriefWire

/// No native tensors/models cross this actor-facing validation boundary.
protocol LiveVADModelHandle: AnyObject, Sendable {
    var assets: LiveVADModelAssets { get }
    func validate(_ contract: LiveVADModelContract) async throws
}

/// The native implementation is sealed below. Test objects exercise destruction
/// order without constructing a CoreML model; handles serialize all operations.
protocol LiveVADModelObject: AnyObject, Sendable {
    var assets: LiveVADModelAssets { get }
    func validate(_ contract: LiveVADModelContract) throws
}

struct LiveVADModelFactory: Sendable {
    typealias Loader = @Sendable (LiveVADModelAssets, LiveVADNativeConfiguration) async throws -> any LiveVADModelHandle
    let handles: [LiveSource: any LiveVADModelHandle]
    private init(handles: [LiveSource: any LiveVADModelHandle]) { self.handles = handles }

    static func load(configuration: LiveVADConfiguration, sources: [LiveSource], assets: LiveVADModelAssets,
                     loader: Loader? = nil) async throws -> Self {
        try Task.checkCancellation()
        guard configuration == assets.configuration, (1...2).contains(sources.count),
              Set(sources).count == sources.count, sources.allSatisfy(\.isCaptureSource) else { throw LiveProtocolError.invalidConfiguration }
        let native = try LiveVADNativeConfiguration(configuration)
        let contract = try LiveVADModelContract(cachedMetadata: assets.readMetadata())
        try Task.checkCancellation()
        let load: Loader = loader ?? { owner,configuration in try await LiveVADOwnedModelHandle.load(assets: owner,configuration: configuration) }
        var handles: [LiveSource: any LiveVADModelHandle] = [:], identities: Set<ObjectIdentifier> = []
        for source in sources {
            try Task.checkCancellation()
            let handle = try await load(assets,native)
            try Task.checkCancellation()
            guard handle.assets === assets, identities.insert(ObjectIdentifier(handle)).inserted else { throw LiveVADModelError.invalidModel }
            try await handle.validate(contract)
            try Task.checkCancellation()
            handles[source] = handle
        }
        try Task.checkCancellation()
        return Self(handles: handles)
    }
}

actor LiveVADOwnedModelHandle: LiveVADModelHandle {
    nonisolated let assets: LiveVADModelAssets
    private var model: (any LiveVADModelObject)?
    init(assets: LiveVADModelAssets, model: any LiveVADModelObject) { self.assets = assets; self.model = model }
    deinit {
        model = nil
        withExtendedLifetime(assets) {}
    }
    func validate(_ contract: LiveVADModelContract) throws {
        guard let model, model.assets === assets else { throw LiveVADModelError.invalidModel }
        try model.validate(contract)
    }

    /// Trusted test seams cannot be selected by wire configuration. Cancellation
    /// forwards to queued work, but once a synchronous constructor starts the
    /// actual task/owner must unwind before any result or cleanup is returned.
    static func load(assets: LiveVADModelAssets, configuration: LiveVADNativeConfiguration,
                     testingBeforeConstruction: (@Sendable () async -> Void)? = nil,
                     testingConstructor: (@Sendable (URL, LiveVADNativeConfiguration) throws -> any LiveVADModelObject)? = nil) async throws -> Self {
        try Task.checkCancellation()
        guard configuration.configuration == assets.configuration else { throw LiveProtocolError.invalidConfiguration }
        let work = Task.detached {
            defer { withExtendedLifetime(assets) {} }
            try Task.checkCancellation()
            await testingBeforeConstruction?()
            try Task.checkCancellation()
            let url = try assets.modelDirectory
            try Task.checkCancellation()
            let model: any LiveVADModelObject
            if let testingConstructor { model = try testingConstructor(url,configuration) }
            else { model = try CoreMLVADModel(assets: assets,directory: url,configuration: configuration) }
            guard model.assets === assets else { throw LiveVADModelError.invalidModel }
            let handle = Self(assets: assets,model: model)
            try Task.checkCancellation()
            return handle
        }
        return try await withTaskCancellationHandler {
            let handle = try await work.value
            try Task.checkCancellation()
            return handle
        } onCancel: { work.cancel() }
    }
}

/// Only its owning handle actor can reach this object after construction. The
/// unchecked sendability bridges CoreML; the private model never escapes and no
/// concurrent native operation is possible through the handle's interface.
private final class CoreMLVADModel: LiveVADModelObject, @unchecked Sendable {
    let assets: LiveVADModelAssets
    private var model: MLModel?
    init(assets: LiveVADModelAssets, directory: URL, configuration: LiveVADNativeConfiguration) throws {
        self.assets = assets
        let settings = MLModelConfiguration(); settings.computeUnits = configuration.vad.computeUnits
        model = try MLModel(contentsOf: directory,configuration: settings)
    }
    deinit { model = nil; withExtendedLifetime(assets) {} }
    func validate(_ contract: LiveVADModelContract) throws {
        guard let model else { throw LiveVADModelError.invalidModel }
        try contract.validate(model.modelDescription)
    }
}
