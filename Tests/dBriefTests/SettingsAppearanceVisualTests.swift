import AppKit
import CoreText
import SwiftUI
import Testing
@testable import dBrief

@Suite("Appearance settings native renders", .serialized) @MainActor
struct SettingsAppearanceVisualTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DBRIEF_APPEARANCE_SNAPSHOT_DIR"] != nil))
    func appearanceLayoutAdaptsToWidthFontAndScheme() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for url in try FileManager.default.contentsOfDirectory(
            at: project.appendingPathComponent("Sources/dBrief/Resources/Fonts"), includingPropertiesForKeys: nil)
            where url.pathExtension == "otf" {
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DBRIEF_APPEARANCE_SNAPSHOT_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (font, size, scheme) in [
            (ViewerReadingFont.inter, 12, ColorScheme.light),
            (.inter, 13, .dark), (.openDyslexic, 20, .light)
        ] {
            for width: CGFloat in [520, 760, 1400] {
                let typography = AppTypographyPreferences(readingFont: font, fontSize: size)
                let palette = ViewerThemeResolver.resolve(mode: scheme == .dark ? .dark : .light,
                    sourceHex: "#1268F5", nonNeon: true)
                let host = NSHostingView(rootView: AppearanceFixture()
                    .environment(\.uiTypography, typography)
                    .environment(\.font, AppFontStyle.body.resolve(using: typography))
                    .environment(\.viewerPalette, palette)
                    .environment(\.colorScheme, scheme)
                    .buttonStyle(.typographyBordered).menuStyle(.button)
                    .tint(palette.primary.color)
                    .background(NativeControlTypography(preferences: typography).frame(width: 0, height: 0)))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: size == 20 ? 1800 : 1050),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                host.sizingOptions = []
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(250))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent(
                    "appearance-\(font.rawValue)-\(size)-\(scheme == .dark ? "dark" : "light")-\(Int(width)).png"))
                window.close()
            }
        }
    }
}

private struct AppearanceFixture: View {
    @State private var preferences = ViewerAppearancePreferences(lightTheme: .paper, darkTheme: .darkPaper)
    @State private var nonNeon = true
    @Environment(\.uiTypography) private var initialTypography
    @State private var typography: AppTypographyPreferences?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsAppearanceEditor(preferences: $preferences,
                    typography: Binding(get: { typography ?? initialTypography }, set: { typography = $0 }),
                    nonNeon: $nonNeon)

                // A plain card beside it: the editor must share its column width.
                SettingsCard("Startup") {
                    SettingsRow("Start at login") { Toggle("Start at login", isOn: .constant(false)) }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
