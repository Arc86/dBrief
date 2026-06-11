import Foundation
import Testing
@testable import dBrief
import dBriefWire

@Suite("Endpoint provider")
struct EndpointProviderTests {

    @Test("Legacy JSON without provider decodes as openAICompatible")
    func legacyDecode() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"Old","baseURL":"https://api.openai.com","modelName":"gpt-4o","apiKey":"k"}
        """.data(using: .utf8)!
        let endpoint = try JSONDecoder().decode(Endpoint.self, from: legacy)
        #expect(endpoint.provider == .openAICompatible)
        #expect(endpoint.name == "Old")
    }

    @Test("Provider round-trips through Codable")
    func roundTrip() throws {
        let e = Endpoint(name: "Claude", baseURL: "https://api.anthropic.com", modelName: "claude-sonnet-4-6", provider: .anthropic)
        let data = try JSONEncoder().encode(e)
        let decoded = try JSONDecoder().decode(Endpoint.self, from: data)
        #expect(decoded.provider == .anthropic)
    }

    @Test("Provider-specific URLs")
    func urls() {
        let anthropic = Endpoint(name: "", baseURL: "https://api.anthropic.com", modelName: "m", provider: .anthropic)
        #expect(anthropic.messagesURL?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(anthropic.transcriptionURL == nil)

        let dg = Endpoint(name: "", baseURL: "https://api.deepgram.com", modelName: "nova-3", provider: .deepgram)
        #expect(dg.transcriptionURL?.absoluteString == "https://api.deepgram.com/v1/listen")

        let el = Endpoint(name: "", baseURL: "https://api.elevenlabs.io", modelName: "scribe_v1", provider: .elevenLabs)
        #expect(el.transcriptionURL?.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text")

        let groq = Endpoint(name: "", baseURL: "https://api.groq.com/openai", modelName: "whisper-large-v3-turbo")
        #expect(groq.transcriptionURL?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
        #expect(!groq.isWhisperASR)
    }
}

@Suite("Anthropic response parsing")
struct AnthropicParseTests {
    @Test("Concatenates text content blocks")
    func parsesText() {
        let json = """
        {"id":"msg_1","type":"message","content":[{"type":"text","text":"Hello "},{"type":"text","text":"world"}]}
        """.data(using: .utf8)!
        #expect(AIService.parseAnthropicText(json) == "Hello world")
    }

    @Test("Ignores non-text blocks and bad payloads")
    func ignoresNonText() {
        let json = """
        {"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"answer"}]}
        """.data(using: .utf8)!
        #expect(AIService.parseAnthropicText(json) == "answer")
        #expect(AIService.parseAnthropicText(Data("nonsense".utf8)) == "")
    }
}

@Suite("Cloud ASR mappers")
struct CloudASRMapperTests {

    @Test("Deepgram maps transcript, words, and speakers")
    func deepgram() {
        let json = """
        {"results":{"channels":[{"alternatives":[{"transcript":"Hi there friend",
        "words":[
          {"word":"hi","punctuated_word":"Hi","start":0.0,"end":0.3,"confidence":0.9,"speaker":0},
          {"word":"there","punctuated_word":"there","start":0.4,"end":0.7,"confidence":0.8,"speaker":0},
          {"word":"friend","punctuated_word":"friend","start":2.0,"end":2.4,"confidence":0.95,"speaker":1}
        ]}]}]}}
        """.data(using: .utf8)!
        let result = CloudASRMappers.parseDeepgram(json, language: "en")
        #expect(result.text == "Hi there friend")
        // Split into 2 segments: speaker change (and a >1s pause) before "friend".
        #expect(result.segments.count == 2)
        #expect(result.segments[0].speaker == "Speaker 1")
        #expect(result.segments[1].speaker == "Speaker 2")
        #expect(result.segments[0].words?.count == 2)
        #expect(result.speakerCount == 2)
    }

    @Test("ElevenLabs maps text and filters non-word tokens")
    func elevenLabs() {
        let json = """
        {"language_code":"en","text":"Hello world",
        "words":[
          {"text":"Hello","type":"word","start":0.0,"end":0.5,"speaker_id":"speaker_0"},
          {"text":" ","type":"spacing","start":0.5,"end":0.5},
          {"text":"world","type":"word","start":0.6,"end":1.0,"speaker_id":"speaker_0"}
        ]}
        """.data(using: .utf8)!
        let result = CloudASRMappers.parseElevenLabs(json)
        #expect(result.text == "Hello world")
        #expect(result.language == "en")
        #expect(result.segments.count == 1)
        #expect(result.segments[0].words?.map(\.word) == ["Hello", "world"])
        #expect(result.segments[0].speaker == "Speaker 1")
    }

    @Test("Falls back to a single segment when no words are present")
    func noWords() {
        let json = """
        {"text":"Just text"}
        """.data(using: .utf8)!
        let result = CloudASRMappers.parseElevenLabs(json)
        #expect(result.text == "Just text")
        #expect(result.segments.count == 1)
        #expect(result.segments[0].words == nil)
    }
}
