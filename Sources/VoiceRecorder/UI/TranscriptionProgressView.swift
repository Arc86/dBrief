import SwiftUI
import AppKit

struct TranscriptionProgressView: View {
    @Environment(AppState.self) private var appState
    @State private var copied = false

    private var isComplete: Bool {
        !appState.processingSteps.isEmpty && appState.processingSteps.allSatisfy {
            if case .completed = $0.status { return true }
            if case .failed = $0.status { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isComplete ? "Processing Complete" : "Processing...")
                .font(.headline)

            ForEach(appState.processingSteps) { step in
                HStack(spacing: 8) {
                    stepIcon(for: step.status)
                        .frame(width: 16)

                    Text(step.name)
                        .font(.callout)

                    Spacer()
                }
            }

            if isComplete, let recording = appState.currentRecording, recording.transcription != nil {
                Divider()
                HStack {
                    Button(copied ? "Copied!" : "Copy Transcription") {
                        if let text = recording.transcription?.text {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copied = false
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func stepIcon(for status: ProcessingStep.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .inProgress:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}
