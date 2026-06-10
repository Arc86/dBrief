import SwiftUI

/// Privacy indicator for the Apple Speech transcription engine.
///
/// Apple Speech's privacy posture depends on the OS: macOS 26+ uses the modern
/// `SpeechAnalyzer`, which runs fully on-device, while macOS 14–25 fall back to
/// `SFSpeechRecognizer`, which may send audio to Apple's servers for recognition.
/// This surfaces that distinction wherever Apple Speech is shown (onboarding and
/// Settings) so users always know where their audio goes.
struct ApplePrivacyBadge: View {
    /// When `true`, the running OS uses the fully on-device `SpeechAnalyzer`.
    private var isFullyOnDevice: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: isFullyOnDevice ? "lock.shield.fill" : "exclamationmark.shield.fill")
                .foregroundStyle(isFullyOnDevice ? .green : .orange)
                .font(.caption)
            Text(isFullyOnDevice
                ? "On-device — your audio stays on this Mac."
                : "May send audio to Apple's servers for recognition on this macOS version.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (isFullyOnDevice ? Color.green : Color.orange).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }
}
