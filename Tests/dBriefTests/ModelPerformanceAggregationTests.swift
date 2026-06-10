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

@Suite("TranscriptionStat.aggregate")
struct TranscriptionStatAggregateTests {
    @Test("Averages end-to-end and inference ratios, plus overhead")
    func aggregates() {
        let recs = [
            ModelPerformanceRecord(transcriptionModel: "M", audioDuration: 600,
                                   transcriptionTime: 200, inferenceTime: 30),
            ModelPerformanceRecord(transcriptionModel: "M", audioDuration: 600,
                                   transcriptionTime: 300, inferenceTime: nil),
        ]
        let stat = TranscriptionStat.aggregate(recs).first!
        #expect(stat.sessions == 2)
        // end-to-end avg ratio = (600/200 + 600/300)/2 = (3 + 2)/2 = 2.5
        #expect(abs(stat.speedup - 2.5) < 0.0001)
        // inference only from rec1: 600/30 = 20
        #expect(abs((stat.inferenceSpeedup ?? 0) - 20) < 0.0001)
        // overhead only from rec1: 200 - 30 = 170
        #expect(abs((stat.avgOverhead ?? 0) - 170) < 0.0001)
    }

    @Test("No inference samples yields nil inference fields")
    func noInference() {
        let recs = [ModelPerformanceRecord(transcriptionModel: "M",
                                           audioDuration: 600, transcriptionTime: 300)]
        let stat = TranscriptionStat.aggregate(recs).first!
        #expect(stat.inferenceSpeedup == nil)
        #expect(stat.avgOverhead == nil)
    }
}
