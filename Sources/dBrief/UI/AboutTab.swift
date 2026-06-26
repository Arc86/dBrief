import AppKit
import SwiftUI

/// The About settings page: brand hero, an update-checker card wired to
/// `UpdateService`, a build-info grid (real version/OS/engine values), an
/// external-links list, and a privacy seal. Adapts the dark neon design to the
/// hybrid Light/Dark BrandKit treatment so it reads in both schemes.
struct AboutTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.calmAppearance) private var calm
    @State private var update = UpdateService()
    @State private var phase: UpdatePhase = .idle
    @State private var animate = false

    enum UpdatePhase { case idle, checking, upToDate, available }

    // MARK: Version / system facts

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
    private var osDescription: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "Apple Silicon"
        #else
        let arch = "Intel"
        #endif
        return "\(v.majorVersion).\(v.minorVersion) · \(arch)"
    }

    private var buildInfo: [InfoRow] {
        [
            InfoRow(key: "Version", value: shortVersion),
            InfoRow(key: "Build", value: buildNumber),
            InfoRow(key: "Channel", value: "Stable"),
            InfoRow(key: "macOS", value: osDescription),
            InfoRow(key: "Transcription", value: appSettings.effectiveTranscriptionEngine.displayName),
            InfoRow(key: "Analysis", value: appSettings.effectiveAIEngine.displayName),
        ]
    }

    private var links: [LinkRow] {
        [
            LinkRow(label: "GitHub", meta: "github.com/Arc86/dBrief",
                    icon: "chevron.left.forwardslash.chevron.right", tint: .primary,
                    url: "https://github.com/Arc86/dBrief"),
            LinkRow(label: "Website", meta: "get.dbrief.nl",
                    icon: "globe", tint: Brand.cyan,
                    url: "https://get.dbrief.nl"),
            LinkRow(label: "Documentation", meta: "get.dbrief.nl/docs",
                    icon: "book", tint: Brand.violet,
                    url: "https://get.dbrief.nl/docs.html"),
            LinkRow(label: "Release notes", meta: "What's new in v\(shortVersion)",
                    icon: "doc.text", tint: Brand.coral,
                    url: "https://github.com/Arc86/dBrief/releases"),
            LinkRow(label: "Report an issue", meta: "Open a GitHub issue",
                    icon: "ladybug", tint: .primary,
                    url: "https://github.com/Arc86/dBrief/issues"),
        ]
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                updateCard
                section("Build") { buildGrid }
                section("Links") { linksList }
                privacySeal
                footer
            }
            .padding(36)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear { animate = true }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(AngularGradient(
                        colors: [Brand.coral, Brand.violet, Brand.cyan, Brand.coral],
                        center: .center))
                    .frame(width: 112, height: 112)
                    .blur(radius: 22)
                    .opacity(0.5)
                    .rotationEffect(.degrees(animate ? 360 : 0))
                    .animation(.linear(duration: 14).repeatForever(autoreverses: false), value: animate)

                logoImage
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                    .offset(y: animate ? -6 : 0)
                    .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: animate)
            }
            .frame(width: 92, height: 92)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("dBrief")
                        .font(.system(size: 34, weight: .heavy))
                        .tracking(-1)
                        .foregroundStyle(.primary)
                    Text("v\(shortVersion)")
                        .font(.brandMono(12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                }
                (Text("Your meetings, ")
                    .foregroundStyle(.secondary)
                 + Text("remembered.")
                    .foregroundStyle(Brand.violet)
                    .fontWeight(.semibold))
                    .font(.system(size: 15))
            }
            Spacer(minLength: 0)
        }
    }

    private var logoImage: some View {
        Group {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Brand.ctaFill(calm: calm))
                    .overlay(Image(systemName: "waveform")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.white))
            }
        }
    }

    // MARK: Update card

    private var updateCard: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(updateIconTint)
                    .frame(width: 38, height: 38)
                updateIcon
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(updateTitle)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(updateSubtitle)
                    .font(.brandMono(12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            updateButton
        }
        .padding(16)
        .background(updateCardTint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(updateCardStroke, lineWidth: 1))
        .animation(.easeOut(duration: 0.25), value: phase)
    }

    @ViewBuilder private var updateIcon: some View {
        switch phase {
        case .idle:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Image(systemName: "checkmark")
                .font(.system(size: 16, weight: .bold)).foregroundStyle(Brand.ready)
        case .available:
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Brand.violet)
        }
    }

    @ViewBuilder private var updateButton: some View {
        switch phase {
        case .available:
            Button("Download & install") { update.openReleasePage() }
                .buttonStyle(.plain)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Brand.ctaFill(calm: calm), in: Capsule())
                .shadow(color: Brand.ctaGlow(calm: calm, base: Brand.violet), radius: calm ? 0 : 12, y: calm ? 0 : 5)
        case .checking:
            Text("Checking…")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Color.primary.opacity(0.06), in: Capsule())
        default:
            Button(phase == .upToDate ? "Check again" : "Check for updates") { runCheck() }
                .buttonStyle(.plain)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(phase == .upToDate ? .primary : Color(nsColor: .windowBackgroundColor))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(phase == .upToDate
                    ? AnyShapeStyle(Color.primary.opacity(0.08))
                    : AnyShapeStyle(Color.primary), in: Capsule())
        }
    }

    private func runCheck() {
        guard phase != .checking else { return }
        phase = .checking
        Task {
            await update.checkForUpdates(manual: true)
            phase = update.updateAvailable ? .available : .upToDate
        }
    }

    private var updateTitle: String {
        switch phase {
        case .idle: "Check for updates"
        case .checking: "Checking for updates…"
        case .upToDate: "dBrief is up to date"
        case .available: "Update available — v\(update.latestVersion ?? "?")"
        }
    }
    private var updateSubtitle: String {
        switch phase {
        case .idle: "You're on v\(shortVersion)"
        case .checking: "Contacting GitHub releases"
        case .upToDate: "v\(shortVersion) is the latest version"
        case .available:
            if let err = update.lastError { err }
            else { "Tap to download the latest release" }
        }
    }
    private var updateIconTint: Color {
        switch phase {
        case .idle: Color.primary.opacity(0.06)
        case .checking: Brand.cyanTint
        case .upToDate: Brand.ready.opacity(0.16)
        case .available: Brand.violetTint
        }
    }
    private var updateCardTint: Color {
        switch phase {
        case .idle: Color.primary.opacity(0.03)
        case .checking: Brand.cyanTint
        case .upToDate: Brand.ready.opacity(0.1)
        case .available: Brand.violetTint
        }
    }
    private var updateCardStroke: Color {
        switch phase {
        case .idle: Color.primary.opacity(0.08)
        case .checking: Brand.cyan.opacity(0.3)
        case .upToDate: Brand.ready.opacity(0.3)
        case .available: Brand.violet.opacity(0.35)
        }
    }

    // MARK: Build grid

    private var buildGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)]
        return LazyVGrid(columns: columns, spacing: 1) {
            ForEach(buildInfo) { row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.key.uppercased())
                        .font(.brandMono(10))
                        .tracking(0.8)
                        .foregroundStyle(.tertiary)
                    Text(row.value)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .background(Color.primary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }

    // MARK: Links

    private var linksList: some View {
        VStack(spacing: 0) {
            ForEach(Array(links.enumerated()), id: \.element.id) { idx, link in
                if idx > 0 { Divider().overlay(Color.primary.opacity(0.06)) }
                Link(destination: URL(string: link.url)!) {
                    HStack(spacing: 14) {
                        Image(systemName: link.icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(link.tint == .primary ? AnyShapeStyle(.primary) : AnyShapeStyle(link.tint))
                            .frame(width: 30, height: 30)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.label)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.primary)
                            Text(link.meta)
                                .font(.brandMono(11.5))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Privacy seal + footer

    private var privacySeal: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.violet)
            Text("Your meetings never leave your Mac. Zero telemetry. Zero analytics. Zero accounts.")
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Brand.violetTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Brand.violet.opacity(0.22), lineWidth: 1))
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("© 2026 dBrief · MIT License")
                .font(.brandMono(12))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Text("Made for people who forget what was decided on Tuesday.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: Section helper

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BrandKicker(title, color: Color.secondary.opacity(0.8))
            content()
        }
    }

    // MARK: Row models

    private struct InfoRow: Identifiable {
        let id = UUID()
        let key: String
        let value: String
    }
    private struct LinkRow: Identifiable {
        let id = UUID()
        let label: String
        let meta: String
        let icon: String
        let tint: Color
        let url: String
    }
}
