import dBriefWire
import CoreML
import Foundation
import Testing
@testable import dBriefMLHost

private enum VADContractFixture {
    static let inputs = ["audio_input":[1,4160],"hidden_state":[1,128],"cell_state":[1,128]]
    static let outputs = ["vad_output":[1,1,1],"new_hidden_state":[1,128],"new_cell_state":[1,128]]
    static var metadata: [String: Any] {
        func features(_ map: [String: [Int]]) -> [[String: Any]] {
            map.keys.sorted().map { name in ["name":name,"type":"MultiArray","dataType":"Float32",
                "isOptional":"0","hasShapeFlexibility":"0","shape":String(data: try! JSONEncoder().encode(map[name]!),encoding: .utf8)!] }
        }
        return ["metadataOutputVersion":"3.0","version":"6.2.1","stateSchema":[],"isUpdatable":"0","method":"predict",
            "modelType":["name":"MLModelType_mlProgram"],"inputSchema":features(inputs),"outputSchema":features(outputs)]
    }
    static func data(_ metadata: [String: Any] = metadata) throws -> Data { try JSONSerialization.data(withJSONObject: [metadata]) }
    static var description: LiveVADModelContract.Description {
        return .init(inputs: inputs.map { .init(name: $0.key,shape: $0.value) },outputs: outputs.map { .init(name: $0.key,shape: $0.value) })
    }
    static func stridedState(base: Float) throws -> MLMultiArray {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 257)
        pointer.initialize(repeating: .nan,count: 257)
        for i in 0..<128 { pointer[i * 2] = base + Float(i) }
        do {
            return try MLMultiArray(dataPointer: UnsafeMutableRawPointer(pointer),shape: [1,128],dataType: .float32,strides: [256,2],
                deallocator: { $0.assumingMemoryBound(to: Float.self).deallocate() })
        } catch { pointer.deallocate(); throw error }
    }
    static func arrays() throws -> [String: MLMultiArray] {
        let probability = try MLMultiArray(shape: [1,1,1],dataType: .float32)
        probability[[0,0,0] as [NSNumber]] = 0.25
        return ["vad_output":probability,"new_hidden_state":try stridedState(base: 2),"new_cell_state":try stridedState(base: -200)]
    }
    static func provider(_ values: [String: MLMultiArray]) throws -> MLDictionaryFeatureProvider {
        try MLDictionaryFeatureProvider(dictionary: values.mapValues { $0 as Any })
    }
}

@Suite struct LiveVADModelContractTests {
    @Test func pinnedFixedMetadataWitnessAndMatchingDescriptionsAreRequired() throws {
        let contract = try LiveVADModelContract(cachedMetadata: VADContractFixture.data())
        try contract.validate(VADContractFixture.description)
        var description = VADContractFixture.description
        description.inputs[0].flexibility = .enumerated([description.inputs[0].shape])
        try contract.validate(description)
        description.inputs[0].flexibility = .range(description.inputs[0].shape.map { NSRange(location: $0,length: 1) })
        try contract.validate(description)
    }

    @Test(arguments: ["missing","extra","duplicate","name","optional","dtype","flex","shape","state","version","format","update","model-type","method"])
    func incompatibleCachedMetadataRefusesAContract(mode: String) throws {
        var metadata = VADContractFixture.metadata
        var inputs = try #require(metadata["inputSchema"] as? [[String: Any]])
        switch mode {
        case "missing": inputs.removeLast()
        case "extra": inputs.append(["name":"extra"])
        case "duplicate": inputs[1] = inputs[0]
        case "name": inputs[0]["name"] = "audio_input_fuzzy"
        case "optional": inputs[0]["isOptional"] = "1"
        case "dtype": inputs[0]["dataType"] = "Double"
        case "flex": inputs[0]["hasShapeFlexibility"] = "1"
        case "shape": inputs[0]["shape"] = "[1, 4160.5]"
        case "state": metadata["stateSchema"] = [["name":"state"]]
        case "version": metadata["version"] = "6.0.0"
        case "format": metadata["metadataOutputVersion"] = "4.0"
        case "update": metadata["isUpdatable"] = "1"
        case "model-type": metadata["modelType"] = ["name":"other"]
        default: metadata["method"] = "other"
        }
        metadata["inputSchema"] = inputs
        #expect(throws: LiveVADModelError.invalidModel) { _ = try LiveVADModelContract(cachedMetadata: VADContractFixture.data(metadata)) }
    }

    @Test func metadataReadAndStructureHaveSeparateSmallBounds() throws {
        let valid = try VADContractFixture.data()
        var exact = valid; exact.append(Data(repeating: 0x20,count: 65_536-valid.count))
        _ = try LiveVADModelContract(cachedMetadata: exact)
        exact.append(0x20)
        for data in [Data(),Data("{}".utf8),Data("[".utf8),exact,try JSONSerialization.data(withJSONObject: [VADContractFixture.metadata,VADContractFixture.metadata])] {
            #expect(throws: LiveVADModelError.invalidModel) { _ = try LiveVADModelContract(cachedMetadata: data) }
        }
    }

    @Test(arguments: ["missing","extra","duplicate","name","optional","type","dtype","shape","enumerated","range","state","update"])
    func loadedModelDescriptionCannotDisagreeWithTheWitness(mode: String) throws {
        let contract = try LiveVADModelContract(cachedMetadata: VADContractFixture.data())
        var description = VADContractFixture.description
        switch mode {
        case "missing": description.outputs.removeLast()
        case "extra": description.outputs.append(.init(name: "extra",shape: [1]))
        case "duplicate": description.outputs[1] = description.outputs[0]
        case "name": description.outputs[0].name += "_fuzzy"
        case "optional": description.outputs[0].isOptional = true
        case "type": description.outputs[0].isMultiArray = false
        case "dtype": description.outputs[0].dataType = .double
        case "shape": description.outputs[0].shape = [128]
        case "enumerated": description.outputs[0].flexibility = .enumerated([description.outputs[0].shape,[1]])
        case "range": description.outputs[0].flexibility = .range(description.outputs[0].shape.map { NSRange(location: $0,length: 2) })
        case "state": description.stateCount = 1
        default: description.isUpdatable = true
        }
        #expect(throws: LiveVADModelError.invalidModel) { try contract.validate(description) }
    }

    @Test func stridedRuntimeStatesReadCoordinatesAndIgnoreNaNPadding() throws {
        let values = try VADContractFixture.arrays()
        let result = try LiveVADModelContract.readOutput(VADContractFixture.provider(values))
        #expect(result.probability == 0.25)
        #expect(result.hiddenState == (0..<128).map { 2 + Float($0) })
        #expect(result.cellState == (0..<128).map { -200 + Float($0) })
    }

    @Test func correctlyNamedScalarOutputRejectsTheWholeResult() throws {
        var values = try VADContractFixture.arrays().mapValues { $0 as Any }
        values["vad_output"] = MLFeatureValue(double: 0.25)
        let provider = try MLDictionaryFeatureProvider(dictionary: values)
        #expect(throws: LiveVADModelError.invalidOutput) { _ = try LiveVADModelContract.readOutput(provider) }
    }

    @Test(arguments: ["extra","missing","fuzzy","dtype","shape","nan","infinity","negative","above-one","hidden-nan-last","cell-infinity-last"])
    func malformedRuntimeOutputRejectsTheWholeResult(mode: String) throws {
        var values = try VADContractFixture.arrays()
        switch mode {
        case "extra": values["extra"] = values["vad_output"]
        case "missing": values.removeValue(forKey: "new_cell_state")
        case "fuzzy": values["new_hidden_state_fuzzy"] = values.removeValue(forKey: "new_hidden_state")
        case "dtype": values["new_hidden_state"] = try MLMultiArray(shape: [1,128],dataType: .double)
        case "shape": values["new_hidden_state"] = try MLMultiArray(shape: [128],dataType: .float32)
        case "nan": values["vad_output"]?[[0,0,0] as [NSNumber]] = NSNumber(value: Float.nan)
        case "infinity": values["vad_output"]?[[0,0,0] as [NSNumber]] = NSNumber(value: Float.infinity)
        case "negative": values["vad_output"]?[[0,0,0] as [NSNumber]] = -0.01
        case "above-one": values["vad_output"]?[[0,0,0] as [NSNumber]] = 1.01
        case "hidden-nan-last": values["new_hidden_state"]?[[0,127] as [NSNumber]] = NSNumber(value: Float.nan)
        default: values["new_cell_state"]?[[0,127] as [NSNumber]] = NSNumber(value: -Float.infinity)
        }
        #expect(throws: LiveVADModelError.invalidOutput) { _ = try LiveVADModelContract.readOutput(VADContractFixture.provider(values)) }
    }
}
