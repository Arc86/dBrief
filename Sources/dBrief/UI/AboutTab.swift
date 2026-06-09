import AppKit
import SwiftUI

struct AboutTab: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .shadow(radius: 10)
            } else {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.blue)
            }

            VStack(spacing: 8) {
                Text("dBrief")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Version \(appVersion)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            Text("Automated meeting intelligence for sales teams.\nCapture discovery calls, generate AI summaries, and sync action items.")
                .multilineTextAlignment(.center)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)

            HStack(spacing: 16) {
                Link("Check for Updates", destination: URL(string: "https://github.com/Arc86/dBrief/releases/latest")!)
                Link("Support", destination: URL(string: "https://github.com/Arc86/dBrief/issues")!)
                Link("Documentation", destination: URL(string: "https://github.com/Arc86/dBrief")!)
            }
            .controlSize(.small)

            Spacer()

            Text("© 2026 Jesper Mol")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
