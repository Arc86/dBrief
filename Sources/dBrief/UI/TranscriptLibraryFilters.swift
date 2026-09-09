import SwiftUI

/// Compact sidebar navigation; native menus keep the form-style picker chrome
/// out of the recording list and remain usable at the narrowest sidebar width.
struct TranscriptLibraryFilters: View {
    @Binding var view: LibrarySmartView
    @Binding var status: LibraryRecordingStatus?
    var isLoading: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Library view", selection: $view) {
                    ForEach(LibrarySmartView.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(view.title).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Library view")
            .accessibilityValue(view.title)
            .help(view.title)

            if !view.includesRecoveryWork {
                Menu {
                    Picker("Recording status", selection: $status) {
                        Text("Any status").tag(nil as LibraryRecordingStatus?)
                        ForEach(LibraryRecordingStatus.allCases, id: \.self) {
                            Text($0.title).tag(Optional($0))
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: status == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                            .font(.system(size: 14))
                        if let status { Text(status.title).font(.caption) }
                    }
                    .foregroundStyle(status == nil ? Color.secondary : Color.accentColor)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Filter by recording status")
                .accessibilityValue(status?.title ?? "Any status")
                .help("Status: \(status?.title ?? "Any status")")
            }
            // Reserve the slot, so initial loading never shifts the controls/list.
            ProgressView().controlSize(.mini)
                .frame(width: 12, height: 12)
                .opacity(isLoading ? 1 : 0)
                .accessibilityHidden(!isLoading)
                .accessibilityLabel("Loading library")
        }
        .controlSize(.small)
        .frame(height: 24)
    }
}
