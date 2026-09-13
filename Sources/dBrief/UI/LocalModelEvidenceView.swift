import SwiftUI

struct LocalModelEvidenceView: View {
    let modelID: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Editorial estimates, reviewed 13 September 2026. These are broad selection bands, not dBrief benchmarks or guaranteed Mac performance.")
            if modelID == LocalTranscriptionChoice.apple {
                Text("Accuracy 4/5 and speed 4/5 apply only to SpeechAnalyzer on macOS 26 with a supported locale. Older systems and unsupported-locale fallback remain unscored. RAM and language assets are managed by macOS; assets may download on first use.")
                Text("Evidence varies by workload: an independent LibriSpeech evaluation found accuracy close to large v3; Argmax's earlier macOS 26 beta earnings-call benchmark placed it between Whisper Base and Small. The conservative band reflects that uncertainty.")
                Link("Independent on-device evaluation", destination: URL(string: "https://github.com/verliapp/stt-benchmark")!)
                Link("Argmax benchmark and methodology", destination: URL(string: "https://www.argmaxinc.com/blog/apple-and-argmax")!)
                Link("Apple SpeechAnalyzer", destination: URL(string: "https://developer.apple.com/videos/play/wwdc2025/277/")!)
            } else {
                Text("Accuracy 4/5 and speed 5/5 are family estimates. NVIDIA reports average English WER of 6.05% for v2 and 6.34% for v3; v3 results vary by language. FluidAudio documents fast Apple Silicon inference. Core ML conversion, audio and hardware affect results.")
                Text("RAM values are planning estimates, not download size or peak app use. Speaker identification adds approximately 0.5 GiB. GPU batch-throughput figures are not Mac latency predictions.")
                Link("NVIDIA model evaluation", destination: URL(string: modelID == LocalTranscriptionChoice.parakeetV2
                    ? "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2"
                    : "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")!)
                Link("FluidAudio Apple Silicon implementation", destination: URL(string: "https://github.com/FluidInference/FluidAudio")!)
            }
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
    }
}
