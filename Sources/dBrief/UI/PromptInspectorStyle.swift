import SwiftUI

/// The prompt editor's primary button: Settings' accent-filled primary style.
struct PromptPrimaryAction: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.settingsPrimary)
    }
}

struct PromptInspectorHeading: View {
    let title: String
    let subtitle: String
    let symbol: String
    @Environment(\.viewerPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 23, weight: .medium)).foregroundStyle(palette.accentText.color)
            Text(title).uiFont(.title3.weight(.semibold))
            Text(subtitle).uiFont(.callout).foregroundStyle(palette.secondary.color)
        }.padding(.bottom, 6)
    }
}

struct PromptEngineLabel: View {
    let name: String
    let destination: String
    @Environment(\.viewerPalette) private var palette
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cpu").foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).uiFont(.callout.weight(.medium))
                Text(destination).uiFont(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(12).background(palette.canvas.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
