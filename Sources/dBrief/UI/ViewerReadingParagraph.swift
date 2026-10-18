import SwiftUI

/// The selectable paragraph used by the recycling transcript List. Sharing the
/// renderer with native visual fixtures keeps font/metric checks on the real path.
struct ViewerReadingParagraph: View {
    let text: AttributedString
    @Environment(\.viewerPalette) private var palette
    @Environment(\.viewerReading) private var reading
    @Environment(\.viewerMode) private var mode

    var body: some View {
        Text(text)
            .font(ViewerFonts.font(for: reading, effectiveMode: mode))
            .foregroundStyle(palette.text.color)
            .lineSpacing(ViewerFonts.additionalLineSpacing(for: reading, effectiveMode: mode))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
