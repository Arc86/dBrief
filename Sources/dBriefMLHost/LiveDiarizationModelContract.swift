@preconcurrency import CoreML
import CryptoKit
import Foundation
import dBriefWire

enum LiveDiarizationNativeError: Error, Equatable { case invalidConfiguration, invalidModel, invalidInput, invalidOutput, inactive, failed }

/// Fixed consumed schema only. A real bundle/catalogue row is still unqualified.
struct LiveDiarizationModelContract: Sendable {
    enum Element: String, Sendable { case float16 = "Float16", float32 = "Float32", int32 = "Int32" }
    enum Flexibility: Sendable { case unspecified, enumerated([[Int]]), range([NSRange]) }
    struct Feature: Sendable {
        var name: String
        var shape: [Int]
        var element: Element = .float32
        var isOptional = false
        var isMultiArray = true
        var flexibility: Flexibility = .unspecified
    }
    struct Description: Sendable {
        var inputs: [Feature]
        var outputs: [Feature]
        var stateCount = 0
        var isUpdatable = false
    }
    let preset: LiveDiarizationPreset
    let metadataDigest: Data
    private let inputs: [Feature], outputs: [Feature]
    static func inputShapes(_ p: LiveDiarizationPreset) -> [String:[Int]] {
        ["chunk":[1,(p.core+p.right)*8,128],"chunk_lengths":[1],"spkcache":[1,264,512],
         "spkcache_lengths":[1],"fifo":[1,p.fifo,512],"fifo_lengths":[1]]
    }
    static func outputShapes(_ p: LiveDiarizationPreset) -> [String:[Int]] {
        let packed = 264+p.fifo+p.core+p.right
        return ["speaker_preds":[1,packed,8],"speaker_preds_10ms":[1,packed*8,8],"chunk_pre_encode_embs":[1,p.core+p.right,512]]
    }
    init(metadata: Data,preset: LiveDiarizationPreset) throws {
        guard !metadata.isEmpty, metadata.count <= LiveDiarizationMetadataWitness.maximumMetadataBytes else { throw LiveDiarizationNativeError.invalidModel }
        do {
            guard let models = try JSONSerialization.jsonObject(with: metadata) as? [[String:Any]], models.count == 1,
                  let model = models.first, model["metadataOutputVersion"] as? String == "3.0",
                  model["isUpdatable"] as? String == "0", model["method"] as? String == "predict",
                  (model["modelType"] as? [String:Any])?["name"] as? String == "MLModelType_mlProgram",
                  let states = model["stateSchema"] as? [Any], states.isEmpty else { throw LiveDiarizationNativeError.invalidModel }
            self.preset = preset; metadataDigest = Data(SHA256.hash(data: metadata))
            inputs = try Self.metadataFeatures(model["inputSchema"],expected: Self.inputShapes(preset),input: true)
            outputs = try Self.metadataFeatures(model["outputSchema"],expected: Self.outputShapes(preset),input: false)
        } catch { throw LiveDiarizationNativeError.invalidModel }
    }
    private static func metadataFeatures(_ value: Any?,expected: [String:[Int]],input: Bool) throws -> [Feature] {
        guard let records = value as? [[String:Any]], records.count == expected.count else { throw LiveDiarizationNativeError.invalidModel }
        var seen: Set<String> = []
        return try records.map { record in
            guard let name = record["name"] as? String, let shape = expected[name], seen.insert(name).inserted,
                  record["type"] as? String == "MultiArray", record["isOptional"] as? String == "0",
                  record["hasShapeFlexibility"] as? String == "0", let rawType = record["dataType"] as? String,
                  let element = Element(rawValue: rawType), let rawShape = record["shape"] as? String, rawShape.utf8.count <= 128 else {
                throw LiveDiarizationNativeError.invalidModel
            }
            let encoded = rawShape.filter { !$0.isWhitespace }
            guard encoded.utf8.allSatisfy({ (48...57).contains($0) || [91,93,44].contains($0) }),
                  try JSONDecoder().decode([Int].self,from: Data(encoded.utf8)) == shape,
                  input && name.hasSuffix("_lengths") ? element == .int32 : [.float16,.float32].contains(element) else {
                throw LiveDiarizationNativeError.invalidModel
            }
            return .init(name: name,shape: shape,element: element)
        }
    }
    func validate(_ description: Description) throws {
        guard description.stateCount == 0, !description.isUpdatable else { throw LiveDiarizationNativeError.invalidModel }
        try Self.validate(description.inputs,expected: inputs); try Self.validate(description.outputs,expected: outputs)
    }
    private static func validate(_ records: [Feature],expected: [Feature]) throws {
        guard records.count == expected.count else { throw LiveDiarizationNativeError.invalidModel }
        var seen: Set<String> = []
        for record in records {
            guard seen.insert(record.name).inserted, let witness = expected.first(where: { $0.name == record.name }),
                  record.isMultiArray, !record.isOptional, record.shape == witness.shape, record.element == witness.element else {
                throw LiveDiarizationNativeError.invalidModel
            }
            switch record.flexibility {
            case .unspecified: break // Only with the verified fixed metadata witness.
            case .enumerated(let shapes):
                guard shapes.count == 1, shapes[0] == witness.shape else { throw LiveDiarizationNativeError.invalidModel }
            case .range(let ranges):
                guard ranges.count == witness.shape.count,
                      zip(ranges,witness.shape).allSatisfy({ $0.0.location == $0.1 && $0.0.length == 1 }) else { throw LiveDiarizationNativeError.invalidModel }
            }
        }
    }
    func validate(_ description: MLModelDescription) throws {
        var states = 0
        if #available(macOS 15.0, *) { states = description.stateDescriptionsByName.count }
        try validate(.init(inputs: Self.features(description.inputDescriptionsByName,expected: inputs),
            outputs: Self.features(description.outputDescriptionsByName,expected: outputs),stateCount: states,isUpdatable: description.isUpdatable))
    }
    private static func features(_ records: [String:MLFeatureDescription],expected: [Feature]) throws -> [Feature] {
        guard Set(records.keys) == Set(expected.map(\.name)) else { throw LiveDiarizationNativeError.invalidModel }
        return try records.map { name,record in
            guard name == record.name, record.type == .multiArray, let constraint = record.multiArrayConstraint else { throw LiveDiarizationNativeError.invalidModel }
            let shape = try dimensions(constraint.shape)
            let element: Element
            switch constraint.dataType {
            case .float16: element = .float16
            case .float32: element = .float32
            case .int32: element = .int32
            default: throw LiveDiarizationNativeError.invalidModel
            }
            let flexibility: Flexibility
            switch constraint.shapeConstraint.type {
            case .unspecified: flexibility = .unspecified
            case .enumerated:
                guard constraint.shapeConstraint.enumeratedShapes.count == 1 else { throw LiveDiarizationNativeError.invalidModel }
                flexibility = .enumerated(try constraint.shapeConstraint.enumeratedShapes.map(dimensions))
            case .range:
                guard constraint.shapeConstraint.sizeRangeForDimension.count == shape.count else { throw LiveDiarizationNativeError.invalidModel }
                flexibility = .range(constraint.shapeConstraint.sizeRangeForDimension.map(\.rangeValue))
            @unknown default: throw LiveDiarizationNativeError.invalidModel
            }
            return .init(name: name,shape: shape,element: element,isOptional: record.isOptional,flexibility: flexibility)
        }
    }
    private static func dimensions(_ numbers: [NSNumber]) throws -> [Int] {
        guard (1...3).contains(numbers.count) else { throw LiveDiarizationNativeError.invalidModel }
        return try numbers.map { number in
            let value = number.intValue
            guard value > 0, value <= 8_192, number == NSNumber(value: value) else { throw LiveDiarizationNativeError.invalidModel }
            return value
        }
    }
}
