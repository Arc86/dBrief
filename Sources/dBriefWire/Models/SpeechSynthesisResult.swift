import Foundation

/// Result of a TTSKit (Qwen3-TTS) synthesis run. The generated audio is written
/// to a file by the helper (audio is never sent over the pipe — same contract as
/// transcription), so this carries only the output path and lightweight metadata.
public struct SpeechSynthesisResult: Sendable, Codable {
    /// Filesystem path of the written audio (WAV, mono, `sampleRate` Hz).
    public let outputPath: String
    /// Duration of the synthesized audio in seconds.
    public let durationSeconds: Double
    /// Sample rate of the written audio in Hz.
    public let sampleRate: Int

    public init(outputPath: String, durationSeconds: Double, sampleRate: Int) {
        self.outputPath = outputPath
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
    }
}

/// Which on-device TTS backend synthesizes spoken summaries. Raw values are the
/// `engine` discriminator carried on `MLRequest.synthesizeSpeech` so the helper
/// routes to the right service without `dBrief` importing either TTS framework.
public enum TTSEngine: String, Codable, Sendable, Hashable, CaseIterable {
    /// TTSKit / Qwen3-TTS — multilingual, voice-style instructions, 0.6B/1.7B.
    case qwen3
    /// FluidAudio Kokoro (KokoroAne) — fast, ANE-resident; English/Mandarin/Japanese (beta).
    case kokoro

    /// Human-readable label for the engine picker.
    public var displayName: String {
        switch self {
        case .qwen3: "Qwen3 TTS"
        case .kokoro: "Kokoro"
        }
    }

    /// One-line descriptor under the picker.
    public var shortDescription: String {
        switch self {
        case .qwen3: "Multilingual · voice styles"
        case .kokoro: "Fast · EN/ZH/JA (beta)"
        }
    }
}

/// Selectable Kokoro (FluidAudio KokoroAne) voice. Raw values are Kokoro voice
/// ids passed verbatim to `KokoroAneManager` (which downloads the embedding on
/// demand), so `dBrief` never imports FluidAudio.
///
/// Only voices that actually ship in FluidAudio's KokoroAne CoreML repos are
/// listed: the English ANE repo currently ships a single voice (`af_heart`),
/// while the Mandarin (`ANE-zh`) repo ships `zf_001`…`zf_007`. The Japanese
/// variant has no text frontend, so no Japanese voices are offered. Kokoro infers
/// language from the voice id, so there is no separate language control.
public enum KokoroVoice: String, Codable, Sendable, CaseIterable {
    // English (the only voice FluidAudio currently ships for the English variant)
    case afHeart = "af_heart"
    // Mandarin (ANE-zh/voices/*.bin)
    case zf001 = "zf_001"
    case zf002 = "zf_002"
    case zf003 = "zf_003"
    case zf004 = "zf_004"
    case zf005 = "zf_005"

    /// Human-readable label for the voice picker.
    public var displayName: String {
        switch self {
        case .afHeart: "Heart"
        case .zf001: "Mandarin 1"
        case .zf002: "Mandarin 2"
        case .zf003: "Mandarin 3"
        case .zf004: "Mandarin 4"
        case .zf005: "Mandarin 5"
        }
    }

    /// Language grouping for the picker (Kokoro derives language from the voice).
    public var language: String {
        switch self {
        case .afHeart: "English"
        case .zf001, .zf002, .zf003, .zf004, .zf005: "Mandarin"
        }
    }
}

/// Selectable Qwen3-TTS model size for spoken-summary synthesis. Raw values match
/// TTSKit's `TTSModelVariant` raw values so the helper can map them directly
/// without `dBrief` importing TTSKit.
public enum TTSModelSize: String, Codable, Sendable, CaseIterable {
    /// Lighter, faster; ignores the voice-style instruction. Better on 16 GB Macs.
    case small = "0.6b"
    /// Heavier; markedly more natural prosody and the only variant that follows
    /// the voice-style instruction.
    case large = "1.7b"

    /// Human-readable label for settings UI.
    public var displayName: String {
        switch self {
        case .small: "Qwen3 TTS 0.6B (lighter)"
        case .large: "Qwen3 TTS 1.7B (most natural)"
        }
    }

    /// Whether this variant follows the spoken-voice style instruction.
    public var supportsVoiceInstruction: Bool { self == .large }
}

/// Selectable Qwen3-TTS speaker voice. Raw values match TTSKit's `Qwen3Speaker`
/// raw values exactly so the helper can map them without `dBrief` importing
/// TTSKit. A voice works with any `TTSLanguage`, but sounds best in its native
/// language (shown in `detail`).
public enum TTSVoice: String, Codable, Sendable, CaseIterable {
    case ryan, aiden
    case onoAnna = "ono-anna"
    case sohee, eric, dylan, serena, vivian
    case uncleFu = "uncle-fu"

    /// Human-readable label for settings UI.
    public var displayName: String {
        switch self {
        case .ryan: "Ryan"
        case .aiden: "Aiden"
        case .onoAnna: "Ono Anna"
        case .sohee: "Sohee"
        case .eric: "Eric"
        case .dylan: "Dylan"
        case .serena: "Serena"
        case .vivian: "Vivian"
        case .uncleFu: "Uncle Fu"
        }
    }

    /// Character of the voice plus its native (best-quality) language.
    public var detail: String {
        switch self {
        case .ryan: "Dynamic male voice with strong rhythmic drive · English"
        case .aiden: "Sunny American male voice with a clear midrange · English"
        case .onoAnna: "Playful, light Japanese female voice · Japanese"
        case .sohee: "Warm Korean female voice with rich emotion · Korean"
        case .eric: "Lively, slightly husky male voice · Chinese (Sichuan)"
        case .dylan: "Youthful, clear male voice · Chinese (Beijing)"
        case .serena: "Warm, gentle young female voice · Chinese"
        case .vivian: "Bright, slightly edgy young female voice · Chinese"
        case .uncleFu: "Seasoned male voice with a low, mellow timbre · Chinese"
        }
    }
}

/// Selectable Qwen3-TTS output language. Raw values match TTSKit's
/// `Qwen3Language` raw values exactly so the helper can map them without
/// `dBrief` importing TTSKit.
public enum TTSLanguage: String, Codable, Sendable, CaseIterable {
    case english, chinese, japanese, korean, german, french, russian, portuguese, spanish, italian

    /// Human-readable label for settings UI.
    public var displayName: String {
        switch self {
        case .english: "English"
        case .chinese: "Chinese"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .german: "German"
        case .french: "French"
        case .russian: "Russian"
        case .portuguese: "Portuguese"
        case .spanish: "Spanish"
        case .italian: "Italian"
        }
    }

    /// A short sentence in this language, used to audition a voice in Settings.
    public var sampleText: String {
        switch self {
        case .english: "Here's a quick preview of how your spoken summary will sound."
        case .chinese: "这是您的语音摘要听起来效果的简短预览。"
        case .japanese: "これは、音声要約がどのように聞こえるかの簡単なプレビューです。"
        case .korean: "음성 요약이 어떻게 들리는지 미리 들어보세요."
        case .german: "Hier ist eine kurze Vorschau, wie Ihre gesprochene Zusammenfassung klingt."
        case .french: "Voici un bref aperçu de la façon dont votre résumé parlé sonnera."
        case .russian: "Вот краткий пример того, как будет звучать ваше голосовое резюме."
        case .portuguese: "Aqui está uma breve prévia de como o seu resumo falado vai soar."
        case .spanish: "Aquí tienes una breve muestra de cómo sonará tu resumen hablado."
        case .italian: "Ecco una breve anteprima di come suonerà il tuo riassunto parlato."
        }
    }
}
