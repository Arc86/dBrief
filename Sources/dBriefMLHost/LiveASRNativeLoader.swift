import CoreML
import Foundation
import dBriefWire

/// Portable records keep tests outside CoreML while covering the actual model
/// descriptions which the SDK uses to allocate per-stream arrays and MLState.
struct LiveASRNativeFeature: Sendable {
    enum Kind: String, Sendable { case input, output, state }
    enum ElementType: Sendable, Equatable { case float16, float32, int32, double, int64, invalid
        var byteWidth: Int { switch self { case .float16: 2; case .float32,.int32: 4; case .double,.int64: 8; case .invalid: 0 } }
    }
    let name: String
    let kind: Kind
    let shape: [Int]
    let bytesPerElement: Int
    let alternativeShapes: [[Int]]
    let elementType: ElementType
    let isMultiArray: Bool
    init(name: String, kind: Kind, shape: [Int], bytesPerElement: Int, alternativeShapes: [[Int]] = [],
         elementType: ElementType? = nil, isMultiArray: Bool = true) {
        self.name = name; self.kind = kind; self.shape = shape; self.bytesPerElement = bytesPerElement
        self.alternativeShapes = alternativeShapes; self.isMultiArray = isMultiArray
        self.elementType = elementType ?? (bytesPerElement == 2 ? .float16 : bytesPerElement == 4 ? .float32 : bytesPerElement == 8 ? .double : .invalid)
    }
}

struct LiveASRNativeDescription: Sendable {
    enum Role: Sendable, Hashable { case encoder, decoder, joint, decoderJoint, decoderJointArgmax, decoderJointNoEncProj, jointNoEncProjBatched }
    let role: Role
    let features: [LiveASRNativeFeature]
}

struct LiveASRNativePolicy: Sendable {
    let computeUnits: LiveASRIdentity.ComputeUnits
    let allowLowPrecisionGPUAccumulation: Bool
    func modelConfiguration() -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        switch computeUnits {
        case .cpuOnly: configuration.computeUnits = .cpuOnly
        case .cpuAndNeuralEngine: configuration.computeUnits = .cpuAndNeuralEngine
        case .cpuAndGPU: configuration.computeUnits = .cpuAndGPU
        case .all: configuration.computeUnits = .all
        }
        configuration.allowLowPrecisionAccumulationOnGPU = allowLowPrecisionGPUAccumulation
        return configuration
    }
}

enum LiveASRNativeConfiguration {
    static func policy(_ configuration: LiveASRConfiguration) throws -> LiveASRNativePolicy {
        guard configuration.isValid, let identity = configuration.identity, identity.isSupported else {
            throw LiveASRAssetError.invalidConfiguration
        }
        return .init(computeUnits: identity.computeUnits,allowLowPrecisionGPUAccumulation: false)
    }

    static func validate(_ descriptions: [LiveASRNativeDescription], metadata: LiveASRMetadataWitness, chunkMs: Int) throws {
        guard [560,1120,2240].contains(chunkMs), !descriptions.isEmpty, descriptions.count <= 7,
              Set(descriptions.map(\.role)).count == descriptions.count else { throw LiveASRAssetError.invalidAsset }
        var featureCount = 0, totalElements = 0, totalBytes = 0
        for description in descriptions {
            var names = Set<String>()
            for feature in description.features {
                featureCount += 1
                guard featureCount <= 128, !feature.name.isEmpty, feature.name.utf8.count <= 256,
                      !feature.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      names.insert(feature.kind.rawValue + ":" + feature.name).inserted,
                      [2,4,8].contains(feature.bytesPerElement), feature.elementType.byteWidth == feature.bytesPerElement,
                      feature.alternativeShapes.count <= 16 else {
                    throw LiveASRAssetError.invalidAsset
                }
                var largest = 0
                for shape in [feature.shape] + feature.alternativeShapes {
                    guard !shape.isEmpty, shape.count <= 8 else { throw LiveASRAssetError.invalidAsset }
                    var product = 1
                    for dimension in shape {
                        let next = product.multipliedReportingOverflow(by: dimension)
                        guard dimension > 0, !next.overflow, next.partialValue <= 8_000_000 else {
                            throw LiveASRAssetError.invalidAsset
                        }
                        product = next.partialValue
                    }
                    try semanticShape(shape,feature: feature,description: description,metadata: metadata,chunkMs: chunkMs)
                    largest = max(largest,product)
                }
                let elements = totalElements.addingReportingOverflow(largest)
                let bytes = largest.multipliedReportingOverflow(by: feature.bytesPerElement)
                let aggregate = totalBytes.addingReportingOverflow(bytes.partialValue)
                guard !elements.overflow, elements.partialValue <= 64_000_000,
                      !bytes.overflow, !aggregate.overflow, aggregate.partialValue <= 512 * 1_048_576 else {
                    throw LiveASRAssetError.invalidAsset
                }
                totalElements = elements.partialValue; totalBytes = aggregate.partialValue
            }
            try requiredFeatures(description,names: names)
        }
        if descriptions.contains(where: { $0.role == .decoderJointNoEncProj }),
           !descriptions.contains(where: { $0.role == .encoder && $0.features.contains(where: { $0.kind == .output && $0.name == "encoder_proj" }) }) {
            throw LiveASRAssetError.invalidAsset
        }
    }

    private static func semanticShape(_ shape: [Int], feature: LiveASRNativeFeature, description: LiveASRNativeDescription,
                                      metadata: LiveASRMetadataWitness, chunkMs: Int) throws {
        func exact(_ expected: [Int], _ types: [LiveASRNativeFeature.ElementType]) throws {
            guard shape == expected, feature.isMultiArray, types.contains(feature.elementType) else { throw LiveASRAssetError.invalidAsset }
        }
        let role = description.role, name = feature.name
        if role == .encoder {
            switch name {
            case "mel": try exact([1,128,chunkMs/10+9],[.float32])
            case "cache_channel", "cache_channel_out": try exact([1,24,metadata.channelCacheFrames,1024],feature.kind == .state ? [.float16,.float32] : [.float32])
            case "cache_time", "cache_time_out": try exact([1,24,1024,8],feature.kind == .state ? [.float16,.float32] : [.float32])
            case "cache_len", "cache_len_out", "mel_length", "prompt_id": try exact([1],[.int32])
            case "encoded": try exact([1,1024,chunkMs/80],[.float32])
            case "encoder_proj": try exact([1,chunkMs/80,640],[.float32])
            default: break
            }
        } else {
            switch name {
            case "token": try exact([1,1],[.int32])
            case "token_length": try exact([1],[.int32])
            case "token_id":
                guard shape.reduce(1,*) == 1, feature.isMultiArray, feature.elementType == .int32 else { throw LiveASRAssetError.invalidAsset }
            case "h_in", "h_out", "c_in", "c_out": try exact([2,1,640],[.float32])
            case "encoder": try exact([1,1024,1],[.float32])
            case "decoder": try exact([1,640,1],[.float32])
            case "decoder_out":
                guard shape.count == 3, shape[0] == 1, shape[1] == 640, feature.isMultiArray, feature.elementType == .float32 else {
                    throw LiveASRAssetError.invalidAsset
                }
            case "encoder_proj":
                if role == .jointNoEncProjBatched {
                    guard let input = description.features.first(where: { $0.kind == .input && $0.name == "encoder_proj" }),
                          input.shape.count == 3, (1...32).contains(input.shape[1]) else { throw LiveASRAssetError.invalidAsset }
                    try exact([1,input.shape[1],640],[.float32])
                } else { try exact([1,1,640],[.float32]) }
            case "logits":
                if role == .jointNoEncProjBatched {
                    guard let input = description.features.first(where: { $0.kind == .input && $0.name == "encoder_proj" }),
                          input.shape.count == 3, (1...32).contains(input.shape[1]) else { throw LiveASRAssetError.invalidAsset }
                    try exact([1,input.shape[1],1,13088],[.float16,.float32])
                } else {
                    guard shape.last == 13088, shape.dropLast().allSatisfy({ $0 == 1 }),
                          feature.isMultiArray, feature.elementType == .float32 else { throw LiveASRAssetError.invalidAsset }
                }
            default: break
            }
        }
    }

    private static func requiredFeatures(_ description: LiveASRNativeDescription, names: Set<String>) throws {
        var inputs: [String], outputs: [String], states: [String] = []
        switch description.role {
        case .encoder:
            inputs = ["mel","mel_length","cache_len","prompt_id"]; outputs = ["encoded","cache_len_out"]
            if description.features.contains(where: { $0.kind == .state }) { states = ["cache_channel","cache_time"] }
            else { inputs += ["cache_channel","cache_time"]; outputs += ["cache_channel_out","cache_time_out"] }
        case .decoder:
            inputs = ["token","token_length","h_in","c_in"]; outputs = ["decoder_out","h_out","c_out"]
        case .joint:
            inputs = ["encoder","decoder"]; outputs = ["logits"]
        case .decoderJoint, .decoderJointArgmax, .decoderJointNoEncProj:
            inputs = ["token","token_length","h_in","c_in",description.role == .decoderJointNoEncProj ? "encoder_proj" : "encoder"]
            outputs = [description.role == .decoderJointArgmax ? "token_id" : "logits","h_out","c_out"]
        case .jointNoEncProjBatched:
            inputs = ["encoder_proj","decoder"]; outputs = ["logits"]
        }
        guard inputs.allSatisfy({ names.contains("input:" + $0) }), outputs.allSatisfy({ names.contains("output:" + $0) }),
              states.allSatisfy({ names.contains("state:" + $0) }) else { throw LiveASRAssetError.invalidAsset }
    }

    /// Read descriptions only: no tensor, state or prediction allocation.
    static func description(_ model: MLModel, role: LiveASRNativeDescription.Role) throws -> LiveASRNativeDescription {
        let description = model.modelDescription
        var features: [LiveASRNativeFeature] = []
        let ordinary = [(LiveASRNativeFeature.Kind.input,description.inputDescriptionsByName),(.output,description.outputDescriptionsByName)]
        for (kind, records) in ordinary {
            guard records.count <= 128 else { throw LiveASRAssetError.invalidAsset }
            for (name, record) in records {
                switch record.type {
                case .multiArray:
                    guard let constraint = record.multiArrayConstraint else { throw LiveASRAssetError.invalidAsset }
                    let shape = try dimensions(constraint.shape)
                    let type = try elementType(constraint.dataType)
                    features.append(.init(name: name,kind: kind,shape: shape,bytesPerElement: type.byteWidth,
                                          alternativeShapes: try alternatives(constraint.shapeConstraint,defaultShape: shape),elementType: type))
                case .int64, .double:
                    features.append(.init(name: name,kind: kind,shape: [1],bytesPerElement: 8,
                                          elementType: record.type == .int64 ? .int64 : .double,isMultiArray: false))
                default: throw LiveASRAssetError.invalidAsset
                }
            }
        }
        if #available(macOS 15, *) {
            guard description.stateDescriptionsByName.count <= 128 else { throw LiveASRAssetError.invalidAsset }
            for (name,record) in description.stateDescriptionsByName {
                guard let constraint = record.stateConstraint else { throw LiveASRAssetError.invalidAsset }
                let type = try elementType(constraint.dataType)
                features.append(.init(name: name,kind: .state,shape: try dimensions(constraint.bufferShape.map { NSNumber(value: $0) }),
                                      bytesPerElement: type.byteWidth,elementType: type))
            }
        }
        return .init(role: role,features: features)
    }

    private static func elementType(_ type: MLMultiArrayDataType) throws -> LiveASRNativeFeature.ElementType {
        switch type {
        case .float16: return .float16
        case .float32: return .float32
        case .int32: return .int32
        case .double: return .double
        default: throw LiveASRAssetError.invalidAsset
        }
    }
    private static func dimensions(_ shape: [NSNumber]) throws -> [Int] {
        guard !shape.isEmpty, shape.count <= 8 else { throw LiveASRAssetError.invalidAsset }
        return try shape.map {
            let number = $0.doubleValue
            guard number.isFinite, number > 0, number <= 8_000_000, number.rounded(.towardZero) == number else {
                throw LiveASRAssetError.invalidAsset
            }
            return Int(number)
        }
    }
    private static func alternatives(_ constraint: MLMultiArrayShapeConstraint, defaultShape: [Int]) throws -> [[Int]] {
        switch constraint.type {
        case .unspecified: return [] // Bound the SDK's default output backing; the exact model remains profile-qualified.
        case .enumerated:
            guard !constraint.enumeratedShapes.isEmpty, constraint.enumeratedShapes.count <= 16 else { throw LiveASRAssetError.invalidAsset }
            let shapes = try constraint.enumeratedShapes.map(dimensions)
            guard shapes.contains(defaultShape), shapes.allSatisfy({ $0.count == defaultShape.count }) else { throw LiveASRAssetError.invalidAsset }
            return shapes
        case .range:
            guard constraint.sizeRangeForDimension.count == defaultShape.count else { throw LiveASRAssetError.invalidAsset }
            var maximum: [Int] = [], minimum: [Int] = []
            for (index,value) in constraint.sizeRangeForDimension.enumerated() {
                let range = value.rangeValue, upper = range.location.addingReportingOverflow(range.length)
                guard range.location > 0, range.length > 0, !upper.overflow, upper.partialValue - 1 <= 8_000_000,
                      defaultShape[index] >= range.location, defaultShape[index] < upper.partialValue else { throw LiveASRAssetError.invalidAsset }
                minimum.append(range.location); maximum.append(upper.partialValue-1)
            }
            return [minimum,maximum]
        @unknown default: throw LiveASRAssetError.invalidAsset
        }
    }
}

struct LiveASRNativeLoadRequest: Sendable {
    let snapshot: LiveASRReadOnlySnapshot
    let policy: LiveASRNativePolicy
}

enum LiveASRNativeLoader {
    static func load(_ configuration: LiveASRConfiguration, testingStagingDirectory: URL? = nil,
                     environment: [String:String] = ProcessInfo.processInfo.environment,
                     beforeConstruction: (@Sendable () async throws -> Void)? = nil,
                     constructor: @Sendable (LiveASRNativeLoadRequest) async throws -> any NemotronDecoderMaking = {
                         try await NemotronDecoderFactory.loadOwned($0)
                     }) async throws -> any NemotronDecoderMaking {
        let policy = try LiveASRNativeConfiguration.policy(configuration)
        guard !environment.keys.contains(where: { $0.hasPrefix("FLUIDAUDIO_") }) else { throw LiveASRAssetError.invalidConfiguration }
        try Task.checkCancellation()
        let snapshot = try LiveASRReadOnlySnapshot.open(configuration,testingStagingDirectory: testingStagingDirectory)
        try await beforeConstruction?()
        try Task.checkCancellation()
        _ = try snapshot.validateCurrentPath()
        return try await constructor(.init(snapshot: snapshot,policy: policy))
    }
}
