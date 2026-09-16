import SwiftUI

/// Glass is reserved for the primary control; content stays opaque and legible.
struct PromptPrimaryAction: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.buttonStyle(.glassProminent).controlSize(.large) }
        else { content.buttonStyle(.borderedProminent).controlSize(.large) }
    }
}

struct PromptInspectorHeading: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 23, weight: .medium)).foregroundStyle(.tint)
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }.padding(.bottom, 6)
    }
}

struct PromptEngineLabel: View {
    let name: String
    let destination: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cpu").foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.callout.weight(.medium))
                Text(destination).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
