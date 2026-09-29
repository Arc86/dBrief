import SwiftUI

/// Shared finished-recording layout. Services and selection remain in the
/// owning detail view; this container only arranges its presentation slots.
struct ViewerDocumentLayout<Header: View, Document: View, Playback: View, Assistant: View>: View {
    @ViewBuilder var header: () -> Header
    @ViewBuilder var document: () -> Document
    @ViewBuilder var playback: () -> Playback
    @ViewBuilder var assistant: () -> Assistant

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                header()
                document()
                    .frame(maxWidth: 920, maxHeight: .infinity)
                playback().frame(maxWidth: 920)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            assistant()
        }
    }
}
