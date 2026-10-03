import CoreFoundation
import CryptoKit
import Foundation

public enum LiveASRAssetError: Error, Equatable { case invalidConfiguration, invalidAsset, oversized, fingerprintMismatch, busy, insufficientDisk }

/// Only validated copied bytes can construct this witness.
public struct LiveASRMetadataWitness: Sendable {
    public let languageHint: String?
    public let promptID: Int
    public let channelCacheFrames: Int
    public let metadataDigest: Data
    public let tokenizerDigest: Data
    fileprivate init(languageHint: String?, promptID: Int, channelCacheFrames: Int, metadata: Data, tokenizer: Data) {
        self.languageHint = languageHint; self.promptID = promptID; self.channelCacheFrames = channelCacheFrames
        metadataDigest = Data(SHA256.hash(data: metadata)); tokenizerDigest = Data(SHA256.hash(data: tokenizer))
    }
}

public enum LiveASRModelContract {
    public static let maximumMetadataBytes = 1_048_576
    public static let maximumTokenizerBytes = 32 * 1_048_576

    public static func validate(metadata: Data, tokenizer: Data, configuration: LiveASRConfiguration) throws -> LiveASRMetadataWitness {
        do {
            guard configuration.isValid, configuration.identity?.isSupported == true,
                  !metadata.isEmpty, metadata.count <= maximumMetadataBytes,
                  !tokenizer.isEmpty, tokenizer.count <= maximumTokenizerBytes,
                  let json = try JSONSerialization.jsonObject(with: metadata) as? [String:Any], json.count <= 256 else {
                throw LiveASRAssetError.invalidAsset
            }
            func integer(_ value: Any?) throws -> Int {
                guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= 1_000_000,
                      n.doubleValue.rounded(.towardZero) == n.doubleValue else { throw LiveASRAssetError.invalidAsset }
                return Int(n.doubleValue)
            }
            let exact: [String:Int] = ["sample_rate":16000,"mel_features":128,"chunk_mel_frames":configuration.chunkMs/10,
                "pre_encode_cache":9,"total_mel_frames":configuration.chunkMs/10+9,"vocab_size":13087,"blank_idx":13087,
                "encoder_dim":1024,"decoder_hidden":640,"decoder_layers":2,"num_prompts":128]
            for (key,value) in exact { guard try integer(json[key]) == value else { throw LiveASRAssetError.invalidAsset } }
            if let ms = json["chunk_ms"] { guard try integer(ms) == configuration.chunkMs else { throw LiveASRAssetError.invalidAsset } }
            func shape(_ key: String) throws -> [Int] {
                guard let array = json[key] as? [Any], array.count == 4 else { throw LiveASRAssetError.invalidAsset }
                let values = try array.map(integer)
                var product = 1
                for value in values {
                    let result = product.multipliedReportingOverflow(by: value)
                    guard value > 0, !result.overflow, result.partialValue <= 8_000_000 else { throw LiveASRAssetError.invalidAsset }
                    product = result.partialValue
                }
                return values
            }
            let channel = try shape("cache_channel_shape"), time = try shape("cache_time_shape")
            guard channel[0] == 1, channel[1] == 24, (1...256).contains(channel[2]), channel[3] == 1024,
                  time == [1,24,1024,8], let rawPrompts = json["prompt_dictionary"] as? [String:Any],
                  !rawPrompts.isEmpty, rawPrompts.count <= 128 else { throw LiveASRAssetError.invalidAsset }
            var prompts: [String:Int] = [:]
            for (key,value) in rawPrompts {
                let id = try integer(value)
                guard !key.isEmpty, key.utf8.count <= 64, !key.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                      id < 128, Int32(exactly: id) != nil else { throw LiveASRAssetError.invalidAsset }
                prompts[key] = id
            }
            let defaultID = try integer(json["default_prompt_id"])
            guard defaultID < 128, prompts["auto"] == defaultID,
                  let rawTags = json["lang_tag_token_ids"] as? [Any], !rawTags.isEmpty, rawTags.count <= 128 else { throw LiveASRAssetError.invalidAsset }
            let tags = try rawTags.map(integer)
            guard Set(tags).count == tags.count, tags.allSatisfy({ $0 < 13087 }) else { throw LiveASRAssetError.invalidAsset }
            let pieces = try flatVocabulary(tokenizer)
            for id in tags {
                guard let piece = pieces[id], piece.hasPrefix("<"), piece.hasSuffix(">"), (3...64).contains(piece.utf8.count) else {
                    throw LiveASRAssetError.invalidAsset
                }
            }
            let language = configuration.language.rawValue
            let hint: String?
            if configuration.language == .auto { hint = nil }
            else {
                hint = prompts[language] != nil ? language : prompts.keys.sorted().first {
                    $0.replacingOccurrences(of: "_",with: "-").lowercased().split(separator: "-").first == Substring(language)
                }
                guard let hint, let prompt = prompts[hint], prompt < 128,
                      tags.contains(where: { pieces[$0] == "<\(hint)>" || pieces[$0]?.dropFirst().dropLast().lowercased().split(separator: "-").first == Substring(language) }) else {
                    throw LiveASRAssetError.invalidAsset
                }
            }
            return .init(languageHint: hint,promptID: hint.flatMap { prompts[$0] } ?? defaultID,channelCacheFrames: channel[2],
                         metadata: metadata,tokenizer: tokenizer)
        } catch let error as LiveASRAssetError { throw error }
        catch { throw LiveASRAssetError.invalidAsset }
    }

    /// The SDK force-casts this flat object. Parse it explicitly to reject raw
    /// duplicate keys and numeric aliases before JSONSerialization can collapse them.
    private static func flatVocabulary(_ data: Data) throws -> [Int:String] {
        let bytes = [UInt8](data); var i = 0, result: [Int:String] = [:]
        func whitespace() { while i < bytes.count, [9,10,13,32].contains(bytes[i]) { i += 1 } }
        func take(_ value: UInt8) throws {
            whitespace(); guard i < bytes.count, bytes[i] == value else { throw LiveASRAssetError.invalidAsset }; i += 1
        }
        func string() throws -> String {
            whitespace(); let start = i
            guard i < bytes.count, bytes[i] == 34 else { throw LiveASRAssetError.invalidAsset }; i += 1
            var escaped = false
            while i < bytes.count {
                let c = bytes[i]; i += 1
                if escaped { escaped = false; continue }
                if c == 92 { escaped = true; continue }
                if c == 34 {
                    guard i-start <= 25_000 else { throw LiveASRAssetError.invalidAsset }
                    return try JSONDecoder().decode(String.self,from: data.subdata(in: start..<i))
                }
                guard c >= 32 else { throw LiveASRAssetError.invalidAsset }
            }
            throw LiveASRAssetError.invalidAsset
        }
        try take(123); whitespace()
        guard i < bytes.count, bytes[i] != 125 else { throw LiveASRAssetError.invalidAsset }
        while true {
            let key = try string()
            guard key.utf8.count <= 5, let id = Int(key), String(id) == key, (0...13087).contains(id), result[id] == nil else {
                throw LiveASRAssetError.invalidAsset
            }
            try take(58); let piece = try string()
            guard !piece.isEmpty, piece.utf8.count <= 4096, result.count < 13088 else { throw LiveASRAssetError.invalidAsset }
            result[id] = piece; whitespace()
            guard i < bytes.count else { throw LiveASRAssetError.invalidAsset }
            if bytes[i] == 125 { i += 1; break }
            try take(44)
        }
        whitespace()
        guard i == bytes.count, (13087...13088).contains(result.count), (0..<13087).allSatisfy({ result[$0] != nil }),
              result[13087] == nil || result[13087] == "<blank>" else { throw LiveASRAssetError.invalidAsset }
        return result
    }
}
