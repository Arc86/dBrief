import Testing
import Foundation
@testable import dBriefWire

@Suite struct FrameCodecTests {
    @Test func encodeThenDecodeSingleFrame() throws {
        let payload = Data("hello".utf8)
        let framed = FrameCodec.encode(payload)
        var reader = FrameReader()
        reader.append(framed)
        let frames = reader.drainFrames()
        #expect(frames == [payload])
    }

    @Test func decodesTwoConcatenatedFrames() throws {
        var blob = FrameCodec.encode(Data("one".utf8))
        blob.append(FrameCodec.encode(Data("two".utf8)))
        var reader = FrameReader()
        reader.append(blob)
        #expect(reader.drainFrames() == [Data("one".utf8), Data("two".utf8)])
    }

    @Test func handlesLengthPrefixSplitAcrossReads() throws {
        let framed = FrameCodec.encode(Data("split".utf8))
        var reader = FrameReader()
        reader.append(framed.prefix(2))            // partial length prefix
        #expect(reader.drainFrames().isEmpty)
        reader.append(framed.suffix(from: 2))      // remainder
        #expect(reader.drainFrames() == [Data("split".utf8)])
    }
}
