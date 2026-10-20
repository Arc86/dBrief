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
    /// FluidAudio Kokoro (KokoroAne) — fast, ANE-resident; English, Spanish, French, Japanese.
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
        case .qwen3: String(localized: "Multilingual · voice styles")
        case .kokoro: String(localized: "Fast · English, Spanish, French, Japanese")
        }
    }

    /// Languages this engine can speak a spoken summary in.
    public var supportedLanguages: [TTSLanguage] {
        switch self {
        case .qwen3: TTSLanguage.allCases
        case .kokoro: [.english, .spanish, .french, .japanese]
        }
    }

    /// The language actually used: the requested one when supported, else English.
    public func resolvedLanguage(_ requested: TTSLanguage) -> TTSLanguage {
        supportedLanguages.contains(requested) ? requested : .english
    }
}

/// Selectable Kokoro (FluidAudio KokoroAne) voice. Raw values are Kokoro voice
/// ids passed verbatim to `KokoroAneManager`; the helper downloads packs on
/// demand, so `dBrief` never imports FluidAudio.
///
/// English voice packs are cached by the helper before FluidAudio loads them.
/// Heart remains the default for existing installations.
public enum KokoroVoice: String, Codable, Sendable, CaseIterable {
    case afHeart = "af_heart"
    case afAlloy = "af_alloy"
    case afAoede = "af_aoede"
    case afBella = "af_bella"
    case afJessica = "af_jessica"
    case afKore = "af_kore"
    case afNicole = "af_nicole"
    case afNova = "af_nova"
    case afRiver = "af_river"
    case afSarah = "af_sarah"
    case afSky = "af_sky"
    case amAdam = "am_adam"
    case amEcho = "am_echo"
    case amEric = "am_eric"
    case amFenrir = "am_fenrir"
    case amLiam = "am_liam"
    case amMichael = "am_michael"
    case amOnyx = "am_onyx"
    case amPuck = "am_puck"
    case amSanta = "am_santa"
    case bfAlice = "bf_alice"
    case bfEmma = "bf_emma"
    case bfIsabella = "bf_isabella"
    case bfLily = "bf_lily"
    case bmDaniel = "bm_daniel"
    case bmFable = "bm_fable"
    case bmGeorge = "bm_george"
    case bmLewis = "bm_lewis"
    case efDora = "ef_dora"
    case emAlex = "em_alex"
    case emSanta = "em_santa"
    case ffSiwis = "ff_siwis"
    case jfAlpha = "jf_alpha"
    case jfGongitsune = "jf_gongitsune"
    case jfNezumi = "jf_nezumi"
    case jfTebukuro = "jf_tebukuro"
    case jmKumo = "jm_kumo"

    public var displayName: String {
        rawValue.split(separator: "_").last!.capitalized
    }

    /// The language this voice speaks, from its Kokoro id prefix.
    public var language: TTSLanguage {
        switch rawValue.first {
        case "e": .spanish
        case "f": .french
        case "j": .japanese
        default: .english
        }
    }

    public var detail: String {
        let female = rawValue.dropFirst().hasPrefix("f")
        switch rawValue.first {
        case "a": return female ? String(localized: "American · Female") : String(localized: "American · Male")
        case "b": return female ? String(localized: "British · Female") : String(localized: "British · Male")
        default:
            return female ? String(localized: "\(language.displayName) · Female")
                : String(localized: "\(language.displayName) · Male")
        }
    }

    public static func voices(for language: TTSLanguage) -> [KokoroVoice] {
        allCases.filter { $0.language == language }
    }

    public static func defaultVoice(for language: TTSLanguage) -> KokoroVoice? {
        switch language {
        case .english: .afHeart
        case .spanish: .efDora
        case .french: .ffSiwis
        case .japanese: .jfAlpha
        default: nil
        }
    }

    /// `voice` when it speaks `language`; otherwise that language's default voice
    /// (English's when Kokoro doesn't speak `language` at all).
    public static func resolved(_ voice: KokoroVoice, for language: TTSLanguage) -> KokoroVoice {
        voice.language == language ? voice : defaultVoice(for: language) ?? .afHeart
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
        case .small: String(localized: "Qwen3 TTS 0.6B (lighter)")
        case .large: String(localized: "Qwen3 TTS 1.7B (most natural)")
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
        case .ryan: String(localized: "Dynamic male voice with strong rhythmic drive · English")
        case .aiden: String(localized: "Sunny American male voice with a clear midrange · English")
        case .onoAnna: String(localized: "Playful, light Japanese female voice · Japanese")
        case .sohee: String(localized: "Warm Korean female voice with rich emotion · Korean")
        case .eric: String(localized: "Lively, slightly husky male voice · Chinese (Sichuan)")
        case .dylan: String(localized: "Youthful, clear male voice · Chinese (Beijing)")
        case .serena: String(localized: "Warm, gentle young female voice · Chinese")
        case .vivian: String(localized: "Bright, slightly edgy young female voice · Chinese")
        case .uncleFu: String(localized: "Seasoned male voice with a low, mellow timbre · Chinese")
        }
    }
}

/// Selectable Qwen3-TTS output language. Raw values match TTSKit's
/// `Qwen3Language` raw values exactly so the helper can map them without
/// `dBrief` importing TTSKit.
public enum TTSLanguage: String, Codable, Sendable, CaseIterable {
    case english, chinese, japanese, korean, german, french, russian, portuguese, spanish, italian

    /// Localized label for settings UI. Never put this in a model prompt: use `englishName`.
    public var displayName: String {
        switch self {
        case .english: String(localized: "English")
        case .chinese: String(localized: "Chinese")
        case .japanese: String(localized: "Japanese")
        case .korean: String(localized: "Korean")
        case .german: String(localized: "German")
        case .french: String(localized: "French")
        case .russian: String(localized: "Russian")
        case .portuguese: String(localized: "Portuguese")
        case .spanish: String(localized: "Spanish")
        case .italian: String(localized: "Italian")
        }
    }

    /// Stable English name, for model prompts (never localized).
    public var englishName: String {
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
