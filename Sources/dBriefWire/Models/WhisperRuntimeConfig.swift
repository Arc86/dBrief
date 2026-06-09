import Foundation

/// Runtime configuration passed to WhisperKit for each transcription call.
/// Allows the user's model and GPU settings to take effect without restarting the app.
public struct WhisperRuntimeConfig: Sendable, Equatable, Codable {
    public let modelName: String
    public let language: String?
    public let diarizationEnabled: Bool
    /// CoreML compute units applied to WhisperKit's audio encoder and text decoder.
    /// Keeping the decoder off the Neural Engine (`.cpuAndGPU`) avoids nil-logits
    /// crashes that some large models (e.g. large-v3 turbo) hit on the ANE.
    public var computeUnits: WhisperComputeUnits = .all

    public init(
        modelName: String,
        language: String?,
        diarizationEnabled: Bool,
        computeUnits: WhisperComputeUnits = .all
    ) {
        self.modelName = modelName
        self.language = language
        self.diarizationEnabled = diarizationEnabled
        self.computeUnits = computeUnits
    }

    public static let `default` = WhisperRuntimeConfig(
        modelName: "openai_whisper-small",
        language: nil,
        diarizationEnabled: false
    )
}
