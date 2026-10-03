@preconcurrency import CoreML
import Foundation

enum LiveVADModelError: Error, Equatable { case invalidModel, invalidOutput }

struct LiveVADNativeOutput: Sendable, Equatable {
    let probability: Float
    let hiddenState: [Float]
    let cellState: [Float]
}

/// A witness from the verified snapshot's bounded pinned metadata. CoreML's
/// default shape and unconstrained shape descriptions alone are not proof of
/// fixed outputs: every prediction must also pass readOutput's runtime checks.
struct LiveVADModelContract: Sendable {
    enum Flexibility: Sendable {
        case unspecified
        case enumerated([[Int]])
        case range([NSRange])
    }
    struct Feature: Sendable {
        var name: String
        var shape: [Int]
        var isMultiArray = true
        var isOptional = false
        var dataType: MLMultiArrayDataType = .float32
        var flexibility: Flexibility = .unspecified
    }
    struct Description: Sendable {
        var inputs: [Feature]
        var outputs: [Feature]
        var stateCount = 0
        var isUpdatable = false
    }
    static let maximumMetadataBytes = 65_536
    private static let inputs = ["audio_input":[1,4160],"hidden_state":[1,128],"cell_state":[1,128]]
    private static let outputs = ["vad_output":[1,1,1],"new_hidden_state":[1,128],"new_cell_state":[1,128]]

    init(cachedMetadata data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumMetadataBytes else { throw LiveVADModelError.invalidModel }
        do {
            guard let models = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], models.count == 1,
                  let model = models.first, model["metadataOutputVersion"] as? String == "3.0", model["version"] as? String == "6.2.1",
                  model["isUpdatable"] as? String == "0", model["method"] as? String == "predict",
                  (model["modelType"] as? [String: Any])?["name"] as? String == "MLModelType_mlProgram",
                  let states = model["stateSchema"] as? [Any], states.isEmpty else { throw LiveVADModelError.invalidModel }
            try Self.validateMetadataFeatures(model["inputSchema"],expected: Self.inputs)
            try Self.validateMetadataFeatures(model["outputSchema"],expected: Self.outputs)
        } catch { throw LiveVADModelError.invalidModel }
    }

    private static func validateMetadataFeatures(_ value: Any?, expected: [String: [Int]]) throws {
        guard let features = value as? [[String: Any]], features.count == expected.count else { throw LiveVADModelError.invalidModel }
        var seen: Set<String> = []
        for feature in features {
            guard let name = feature["name"] as? String, let shape = expected[name], seen.insert(name).inserted,
                  feature["type"] as? String == "MultiArray", feature["dataType"] as? String == "Float32",
                  feature["isOptional"] as? String == "0", feature["hasShapeFlexibility"] as? String == "0",
                  let encodedShape = feature["shape"] as? String, encodedShape.utf8.count <= 64,
                  try JSONDecoder().decode([Int].self,from: Data(encodedShape.utf8)) == shape else { throw LiveVADModelError.invalidModel }
        }
    }

    func validate(_ description: Description) throws {
        guard description.stateCount == 0, !description.isUpdatable else { throw LiveVADModelError.invalidModel }
        try Self.validateFeatures(description.inputs,expected: Self.inputs)
        try Self.validateFeatures(description.outputs,expected: Self.outputs)
    }
    private static func validateFeatures(_ features: [Feature], expected: [String: [Int]]) throws {
        guard features.count == expected.count else { throw LiveVADModelError.invalidModel }
        var seen: Set<String> = []
        for feature in features {
            guard let shape = expected[feature.name], seen.insert(feature.name).inserted, feature.isMultiArray, !feature.isOptional,
                  feature.dataType == .float32, feature.shape == shape else { throw LiveVADModelError.invalidModel }
            switch feature.flexibility {
            case .unspecified: break // Requires this validated metadata witness and runtime shape checks.
            case .enumerated(let shapes):
                guard shapes.count == 1, shapes[0] == shape else { throw LiveVADModelError.invalidModel }
            case .range(let ranges):
                guard ranges.count == shape.count, zip(ranges,shape).allSatisfy({ $0.0.location == $0.1 && $0.0.length == 1 }) else {
                    throw LiveVADModelError.invalidModel
                }
            }
        }
    }

    /// Called only after direct owned model loading; no metadata-only readiness.
    func validate(_ description: MLModelDescription) throws {
        var stateCount = 0
        if #available(macOS 15.0, *) { stateCount = description.stateDescriptionsByName.count }
        try validate(.init(inputs: Self.features(description.inputDescriptionsByName,expected: Self.inputs),
            outputs: Self.features(description.outputDescriptionsByName,expected: Self.outputs),stateCount: stateCount,isUpdatable: description.isUpdatable))
    }
    private static func features(_ descriptions: [String: MLFeatureDescription], expected: [String: [Int]]) throws -> [Feature] {
        guard Set(descriptions.keys) == Set(expected.keys) else { throw LiveVADModelError.invalidModel }
        return try descriptions.map { name,description in
            guard description.name == name, description.type == .multiArray, let constraint = description.multiArrayConstraint else {
                throw LiveVADModelError.invalidModel
            }
            let shape = try dimensions(constraint.shape)
            let flexibility: Flexibility
            switch constraint.shapeConstraint.type {
            case .unspecified: flexibility = .unspecified
            case .enumerated:
                guard constraint.shapeConstraint.enumeratedShapes.count == 1 else { throw LiveVADModelError.invalidModel }
                flexibility = .enumerated(try constraint.shapeConstraint.enumeratedShapes.map(dimensions))
            case .range:
                guard constraint.shapeConstraint.sizeRangeForDimension.count == shape.count else { throw LiveVADModelError.invalidModel }
                flexibility = .range(constraint.shapeConstraint.sizeRangeForDimension.map(\.rangeValue))
            @unknown default: throw LiveVADModelError.invalidModel
            }
            return .init(name: name,shape: shape,isMultiArray: true,isOptional: description.isOptional,dataType: constraint.dataType,flexibility: flexibility)
        }
    }
    private static func dimensions(_ numbers: [NSNumber]) throws -> [Int] {
        guard (1...3).contains(numbers.count) else { throw LiveVADModelError.invalidModel }
        return try numbers.map { number in
            let value = number.intValue
            guard value > 0, number == NSNumber(value: value) else { throw LiveVADModelError.invalidModel }
            return value
        }
    }

    /// Native arrays stay local. Coordinate subscripts obey each CoreML array's
    /// strides; padding cannot enter the returned state. Never fuzzy-match a
    /// name, bind dataPointer to Float or return partly validated state.
    static func readOutput(_ provider: any MLFeatureProvider) throws -> LiveVADNativeOutput {
        guard provider.featureNames == Set(outputs.keys) else { throw LiveVADModelError.invalidOutput }
        func array(_ name: String) throws -> MLMultiArray {
            let shape = outputs[name]!
            guard let feature = provider.featureValue(for: name), feature.type == .multiArray, let array = feature.multiArrayValue,
                  array.dataType == .float32, array.shape == shape.map({ NSNumber(value: $0) }), array.count == shape.reduce(1,*) else {
                throw LiveVADModelError.invalidOutput
            }
            return array
        }
        let probabilityArray = try array("vad_output")
        let probability = probabilityArray[[0,0,0] as [NSNumber]].floatValue
        guard probability.isFinite, (0...1).contains(probability) else { throw LiveVADModelError.invalidOutput }
        func state(_ name: String) throws -> [Float] {
            let values = try array(name)
            return try (0..<128).map { index in
                let value = values[[NSNumber(value: 0),NSNumber(value: index)]].floatValue
                guard value.isFinite else { throw LiveVADModelError.invalidOutput }
                return value
            }
        }
        let hidden = try state("new_hidden_state"), cell = try state("new_cell_state")
        return .init(probability: probability,hiddenState: hidden,cellState: cell)
    }
}
