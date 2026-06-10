import Testing
import Foundation
@testable import dBrief

@Suite("ModelPerformanceRecord.inferenceTime")
struct ModelPerformanceRecordTests {
    @Test("inferenceTime round-trips through JSON")
    func roundTrips() throws {
        let rec = ModelPerformanceRecord(transcriptionModel: "M",
                                         audioDuration: 600,
                                         transcriptionTime: 200,
                                         inferenceTime: 30)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(ModelPerformanceRecord.self, from: try enc.encode(rec))
        #expect(back.inferenceTime == 30)
    }

    @Test("Legacy record JSON without inferenceTime decodes as nil")
    func legacyDecodesNil() throws {
        let json = """
        {"id":"\(UUID().uuidString)","date":"2026-01-01T00:00:00Z","transcriptionModel":"M","audioDuration":600,"transcriptionTime":30}
        """.data(using: .utf8)!
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(ModelPerformanceRecord.self, from: json)
        #expect(back.inferenceTime == nil)
    }
}
