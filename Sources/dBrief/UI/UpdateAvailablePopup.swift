import SwiftUI

private let brandOrange = Color(hex: "#FF6B00")

/// Floating "Update available" notification, styled to match `CallDetectedPopup`.
/// Reads the discovered release directly from `UpdateService` and shown by
/// `UpdateAvailableOverlayController`. Notify-only: "Update" opens the GitHub
/// release page; it does not download or install.
struct UpdateAvailablePopup: View {
    @Environment(UpdateService.self) private var updateService

    /// Dismiss callback supplied by the overlay controller (closes the panel).
    var onDismiss: () -> Void = {}

    var body: some View {
        ZStack {
            // Glass background — matches native macOS notification style
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)

            HStack(alignment: .center, spacing: 14) {
                // dBrief app icon
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Update available")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(updateService.latestVersion.map { "dBrief \($0) is ready to download." }
                        ?? "A new version of dBrief is ready.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    HStack(spacing: 10) {
                        Button("Later") {
                            onDismiss()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)

                        Button("Update") {
                            updateService.openReleasePage()
                            onDismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .tint(brandOrange)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            // Dismiss button — top-trailing, on top
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(width: 360, height: 118)
    }
}
