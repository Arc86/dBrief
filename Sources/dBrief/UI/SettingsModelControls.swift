import SwiftUI

/// The "…" menu beside a local model card: removes the downloaded model and reports
/// the outcome through `message` (shown by the page as a status row).
struct ModelActionsMenu: View {
    let modelName: String
    @Binding var message: String?
    let purge: () async throws -> Void

    var body: some View {
        Menu {
            Button("Remove downloaded model", role: .destructive) {
                Task {
                    do {
                        try await purge()
                        message = "Local \(modelName) model cache removed."
                    } catch {
                        message = error.localizedDescription
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More model actions")
    }
}

/// "Memory and sources" disclosure under a local model card, labelled on the palette.
struct ModelEvidenceDisclosure<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.viewerPalette) private var palette

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        DisclosureGroup {
            content
        } label: {
            Text("Memory and sources")
                .uiFont(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.heading.color)
        }
        .uiFont(.system(size: 12))
    }
}
