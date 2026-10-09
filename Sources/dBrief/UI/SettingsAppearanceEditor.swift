import AppKit
import SwiftUI

/// Visual appearance controls shared by Settings and native preview fixtures.
/// Emits `SettingsCard`s, so place it in a `SettingsPageScaffold` or a VStack.
struct SettingsAppearanceEditor: View {
    @Binding var preferences: ViewerAppearancePreferences
    @Binding var typography: AppTypographyPreferences
    @Binding var nonNeon: Bool
    @Environment(\.colorScheme) private var systemScheme

    private var palette: ViewerPalette {
        ViewerThemeResolver.resolve(
            mode: preferences.effectiveMode(systemIsDark: systemScheme == .dark),
            sourceHex: preferences.sourceAccentHex, nonNeon: nonNeon)
    }

    var body: some View {
        SettingsCard("Theme", description: "Follow System switches between your light and dark theme with macOS.",
                     section: .appearance) {
            SettingsStackedRow { themeControls }
        }

        SettingsCard("Accent", section: .accentColor) {
            SettingsStackedRow {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        accentPresets
                        Divider().frame(height: 22)
                        customAccentControl
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        accentPresets
                        customAccentControl
                    }
                }
            }
            SettingsRow("Non-neon", caption: "Uses the accent instead of the brand gradient on outlines and the AI sparkle.") {
                Toggle("Non-neon", isOn: $nonNeon)
            }
        }

        SettingsCard("Interface text", description: "Menus, transcripts and settings throughout dBrief.",
                     section: .typography) {
            SettingsRow("Font") {
                Picker("Font", selection: $typography.readingFont) {
                    ForEach(ViewerReadingFont.allCases, id: \.self) { font in
                        Text(font.displayName).tag(font)
                    }
                }
                .pickerStyle(.menu)
            }
            SettingsRow("Text size") {
                HStack(spacing: 6) {
                    Text("\(typography.fontSize) pt").uiFont(.system(size: 12).monospacedDigit())
                        .foregroundStyle(palette.text.color)
                    Stepper("Text size", value: $typography.fontSize,
                            in: AppTypographyPreferences.fontSizeRange)
                        .labelsHidden()
                        .accessibilityValue("\(typography.fontSize) points")
                }
            }
            SettingsStackedRow { fontPreview }
        }
    }

    private var themeControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 8) {
                modeButton(.system, symbol: "desktopcomputer")
                modeButton(.light, symbol: "sun.max")
                modeButton(.dark, symbol: "moon")
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    themePair(dark: false).frame(minWidth: 240)
                    themePair(dark: true).frame(minWidth: 240)
                }
                VStack(alignment: .leading, spacing: 14) {
                    themePair(dark: false)
                    themePair(dark: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func modeButton(_ mode: AppThemeMode, symbol: String) -> some View {
        let selected = preferences.themeMode == mode
        return Button {
            preferences.themeMode = mode
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: symbol).font(.system(size: 14))
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                    }
                }
                .frame(height: 18)
                Text(mode.displayName).uiFont(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(selected ? palette.accentText.color : palette.heading.color)
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(8)
            .background(selected ? palette.selected.color : palette.canvas.color,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? palette.accentText.color.opacity(0.65) : palette.divider.color, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.displayName) theme mode")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func themePair(dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dark ? "Dark mode" : "Light mode")
                .uiFont(.system(size: 11, weight: .semibold)).foregroundStyle(palette.secondary.color)
            HStack(alignment: .top, spacing: 10) {
                themeButton(dark ? .dark : .light)
                themeButton(dark ? .darkPaper : .paper)
            }
        }
    }

    private func themeButton(_ mode: ViewerAppearanceMode) -> some View {
        let selected = (mode.isDark ? preferences.darkTheme : preferences.lightTheme) == mode
        return Button {
            if mode.isDark { preferences.darkTheme = mode }
            else { preferences.lightTheme = mode }
        } label: {
            VStack(spacing: 8) {
                AppearanceThemePreview(mode: mode, accentHex: preferences.sourceAccentHex, nonNeon: nonNeon)
                    .frame(height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(selected ? palette.accentText.color : palette.divider.color, lineWidth: selected ? 2 : 1)
                    }
                HStack(spacing: 5) {
                    Text(mode.displayName).uiFont(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(palette.accentText.color)
                    }
                }
                .foregroundStyle(palette.heading.color)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.displayName), \(mode.isDark ? "dark" : "light") mode theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("Use \(mode.displayName) when \(mode.isDark ? "dark" : "light") mode is active")
    }

    private var accentPresets: some View {
        HStack(spacing: 10) {
            ForEach(AppearanceAccentPreset.all) { preset in
                accentButton(preset)
            }
        }
    }

    private var customAccentControl: some View {
        HStack(spacing: 8) {
            Text("Custom…").uiFont(.system(size: 12)).foregroundStyle(palette.text.color)
            ColorPicker("Custom accent color", selection: customAccent, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 36)
                .accessibilityLabel("Custom accent color")
        }
        .fixedSize()
    }

    private func accentButton(_ preset: AppearanceAccentPreset) -> some View {
        let selected = ViewerRGB(hex: preferences.sourceAccentHex)?.hex == preset.hex
        let color = ViewerRGB(hex: preset.hex)!
        return Button {
            preferences.sourceAccentHex = preset.hex
        } label: {
            Circle().fill(color.color)
                .frame(width: 24, height: 24)
                .overlay { Circle().strokeBorder(palette.divider.color, lineWidth: 1) }
                .overlay {
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(preset.hex == "#FFFFFF" || preset.hex == "#FF962C" ? .black : .white)
                    }
                }
                .padding(4)
                .overlay {
                    Circle().strokeBorder(selected ? palette.accentText.color : .clear, lineWidth: 2)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.name) accent")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(preset.name)
    }

    private var fontPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "textformat").font(.system(size: 11))
                Text("Live preview").uiFont(.caption)
            }
            .foregroundStyle(palette.secondary.color)
            Text("A clear view of your meeting.")
                .font(AppFontStyle.body.resolve(using: typography))
                .foregroundStyle(palette.text.color)
                .fixedSize(horizontal: false, vertical: true)
            Text("Recording, transcripts, and settings")
                .font(AppFontStyle.caption.resolve(using: typography))
                .foregroundStyle(palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.canvas.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.divider.color, lineWidth: 1) }
        .accessibilityLabel("Live preview, \(typography.readingFont.displayName), \(typography.fontSize) points")
    }

    private var customAccent: Binding<Color> {
        Binding(get: {
            ViewerRGB(hex: preferences.sourceAccentHex)?.color ?? palette.primary.color
        }, set: { color in
            guard let color = NSColor(color).usingColorSpace(.sRGB) else { return }
            preferences.sourceAccentHex = String(format: "#%02X%02X%02X",
                Int((color.redComponent * 255).rounded()),
                Int((color.greenComponent * 255).rounded()),
                Int((color.blueComponent * 255).rounded()))
        })
    }
}

private struct AppearanceAccentPreset: Identifiable {
    let name: String
    let hex: String
    var id: String { hex }
    static let all = [
        Self(name: "Blue", hex: "#1268F5"), Self(name: "Violet", hex: "#7054D9"),
        Self(name: "Green", hex: "#19745B"), Self(name: "Orange", hex: "#FF962C"),
        Self(name: "Black", hex: "#000000"), Self(name: "White", hex: "#FFFFFF")
    ]
}

/// A miniature interface illustrates the real palette without tiny unreadable text.
private struct AppearanceThemePreview: View {
    let mode: ViewerAppearanceMode
    let accentHex: String
    let nonNeon: Bool
    private var palette: ViewerPalette {
        ViewerThemeResolver.resolve(mode: mode, sourceHex: accentHex, nonNeon: nonNeon)
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Circle().fill(palette.primary.color).frame(width: 9, height: 9)
                RoundedRectangle(cornerRadius: 2).fill(palette.selected.color).frame(height: 5)
                RoundedRectangle(cornerRadius: 2).fill(palette.secondary.color.opacity(0.22)).frame(height: 4)
                RoundedRectangle(cornerRadius: 2).fill(palette.secondary.color.opacity(0.22)).frame(height: 4)
                Spacer(minLength: 0)
            }
            .padding(8).frame(width: 38)
            .background(palette.sidebarTop.color)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    RoundedRectangle(cornerRadius: 2).fill(palette.heading.color.opacity(0.8))
                        .frame(width: 35, height: 5)
                    Spacer()
                    Circle().fill(palette.primary.color).frame(width: 6, height: 6)
                }
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(palette.text.color.opacity(0.35)).frame(height: 3)
                    RoundedRectangle(cornerRadius: 2).fill(palette.text.color.opacity(0.2)).frame(height: 3)
                    RoundedRectangle(cornerRadius: 2).fill(palette.text.color.opacity(0.2)).frame(width: 25, height: 3)
                }
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.surface.color, in: RoundedRectangle(cornerRadius: 4))
                Spacer(minLength: 0)
                Capsule().fill(palette.primary.color).frame(width: 27, height: 6)
            }
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.canvas.color)
        }
        .accessibilityHidden(true)
    }
}
