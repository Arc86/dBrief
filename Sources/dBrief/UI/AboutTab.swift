import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The About page: app identity and update check, the facts support asks for,
/// diagnostics export, links and the privacy promise — on Signature cards.
struct AboutTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(UpdaterController.self) private var updaterController
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status
    @State private var diagnosticsStatus: String?

    // MARK: Version / system facts

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
    private var isBeta: Bool { AppSupportPaths.bundleIdentifier.hasSuffix(".beta") }
    private var osDescription: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "Apple Silicon"
        #else
        let arch = "Intel"
        #endif
        return "\(v.majorVersion).\(v.minorVersion) · \(arch)"
    }

    private var links: [LinkRow] {
        [
            LinkRow(label: "GitHub", meta: "github.com/Arc86/dBrief",
                    icon: "chevron.left.forwardslash.chevron.right", url: "https://github.com/Arc86/dBrief"),
            LinkRow(label: "Website", meta: "get.dbrief.nl", icon: "globe", url: "https://get.dbrief.nl"),
            LinkRow(label: "Documentation", meta: "get.dbrief.nl/docs", icon: "book", url: "https://get.dbrief.nl/docs.html"),
            LinkRow(label: "Release notes", meta: "What's new in v\(shortVersion)", icon: "doc.text",
                    url: "https://github.com/Arc86/dBrief/releases"),
            LinkRow(label: "Report an issue", meta: "Open a GitHub issue", icon: "ladybug",
                    url: "https://github.com/Arc86/dBrief/issues"),
        ]
    }

    // MARK: Body

    var body: some View {
        SettingsPageScaffold(page: .about) {
            SettingsCard(section: .about) {
                SettingsStackedRow { identity }
            }

            SettingsCard("This Mac") {
                infoRow("Version", shortVersion)
                infoRow(isBeta ? "Beta build" : "Build", buildNumber)
                infoRow("Channel", isBeta ? "Beta" : "Stable")
                infoRow("macOS", osDescription)
                infoRow("Transcription", appSettings.effectiveTranscriptionEngine.displayName)
                infoRow("Analysis", appSettings.effectiveAIEngine.displayName)
            }

            SettingsCard("Diagnostics") {
                SettingsRow("Support report",
                            caption: "App, storage, recovery and recording-lifecycle events. Audio, transcripts, meeting titles, names, file paths and credentials are excluded.",
                            systemImage: "stethoscope") {
                    Button("Export diagnostics…") { exportDiagnostics() }.buttonStyle(.settingsPrimary)
                }
                SettingsRow("Recovery files", systemImage: "lifepreserver") {
                    Button("Show in Finder") { showRecoveryFolder() }
                        .buttonStyle(.settingsSecondary)
                        .disabled(!FileManager.default.fileExists(atPath: InterruptedSessionStore.defaultRootURL.path))
                }
                if let diagnosticsStatus {
                    SettingsStackedRow {
                        Text(diagnosticsStatus)
                            .uiFont(.system(size: 11.5))
                            .foregroundStyle(diagnosticsStatus.hasPrefix("Couldn’t") ? status.danger.color : palette.secondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            SettingsCard("Links", description: "Your meetings never leave your Mac. No telemetry, analytics or accounts.") {
                ForEach(links) { link in
                    SettingsRow(verbatim: link.label, caption: link.meta, systemImage: link.icon) {
                        Link(destination: URL(string: link.url)!) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.settingsSecondary)
                        .accessibilityLabel("Open \(link.label)")
                    }
                }
            }

            Text("© 2026 dBrief · MIT License")
                .uiFont(.system(size: 11))
                .foregroundStyle(palette.secondary.color)
                .frame(maxWidth: .infinity)
        }
    }

    private var identity: some View {
        VStack(spacing: 6) {
            Group {
                if let icon = DBriefAppIcon.image {
                    Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    BrandBarsMark(height: 32)
                        .frame(width: 64, height: 64)
                        .background(palette.canvas.color, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
            }
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
            Text("dBrief")
                .uiFont(.system(size: 20, weight: .semibold))
                .foregroundStyle(palette.heading.color)
            Text("Version \(shortVersion) (\(buildNumber)) · \(isBeta ? "Beta" : "Stable")")
                .uiFont(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(palette.secondary.color)
            Button("Check for updates") { updaterController.checkForUpdates() }
                .buttonStyle(.settingsSecondary)
                .disabled(!updaterController.canCheckForUpdates)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        SettingsRow(verbatim: key) {
            Text(value)
                .uiFont(.system(size: 12).monospacedDigit())
                .foregroundStyle(palette.text.color)
                .textSelection(.enabled)
        }
    }

    // MARK: Diagnostics

    @MainActor
    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "Export dBrief Diagnostics"
        panel.nameFieldStringValue = "dBrief-Diagnostics-\(Self.diagnosticsTimestamp()).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let report = DBriefDiagnosticsExporter.makeReport(
                recordingFolderURL: appSettings.effectiveRecordingFolderURL
            )
            try DBriefDiagnosticsExporter.writeReport(report, to: url)
            diagnosticsStatus = "Diagnostics exported. Review the report before sharing it with support."
        } catch {
            diagnosticsStatus = "Couldn’t export diagnostics. \(error.localizedDescription)"
        }
    }

    private func showRecoveryFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([InterruptedSessionStore.defaultRootURL])
    }

    private static func diagnosticsTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private struct LinkRow: Identifiable {
        let id = UUID()
        let label: String
        let meta: String
        let icon: String
        let url: String
    }
}
