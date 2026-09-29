import SwiftUI

struct ViewerReadingOptions: View {
    @Binding private var preferences: ViewerAppearancePreferences
    @Environment(\.viewerPalette) private var palette

    init(preferences: Binding<ViewerAppearancePreferences>) {
        self._preferences = preferences
    }

    private var pointSize: Binding<Double> {
        Binding(
            get: { Double(preferences.fontSize) },
            set: { preferences.fontSize = Int($0.rounded()) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reading options")
                .uiFont(.headline)
                .foregroundStyle(palette.heading.color)

            Picker("Font", selection: $preferences.readingFont) {
                ForEach(ViewerReadingFont.allCases, id: \.self) { font in
                    Text(font.displayName).tag(font)
                }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Text size")
                    Spacer()
                    Text("\(preferences.fontSize) pt")
                        .monospacedDigit()
                        .foregroundStyle(palette.secondary.color)
                        .accessibilityLabel("\(preferences.fontSize) points")
                }
                Slider(value: pointSize, in: 12...24, step: 1)
                    .tint(palette.primary.color)
                    .accessibilityLabel("Text size")
                    .accessibilityValue("\(preferences.fontSize) points")
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Transcript density")
                    .uiFont(.subheadline)
                    .foregroundStyle(palette.text.color)
                Picker("Transcript density", selection: $preferences.density) {
                    ForEach(ViewerDensity.allCases, id: \.self) { density in
                        Text(density.displayName).tag(density)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Transcript density")
            }

            Toggle("Speaker Names", isOn: $preferences.showSpeakerNames)
                .tint(palette.primary.color)

            Divider()
                .overlay(palette.divider.color)

            Button("Reset reading options") {
                var reset = preferences
                reset.resetReading()
                preferences = reset
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.accentText.color)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .uiFont(.system(size: 13))
        .foregroundStyle(palette.text.color)
        .padding(14)
        .frame(width: 270, alignment: .leading)
        .background(palette.surface.color)
        .fixedSize(horizontal: false, vertical: true)
    }
}
