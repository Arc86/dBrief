import SwiftUI

/// The gradient exists only on the outline; the interior is always opaque.
struct ViewerBrandButtonStyle: ButtonStyle {
    @Environment(\.viewerPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .uiFont(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.heading.color)
            .padding(.horizontal, 12)
            .frame(minHeight: height)
            .background(palette.surface.color, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(LinearGradient(colors: palette.brandStops.map(\.color), startPoint: .leading, endPoint: .trailing), lineWidth: configuration.isPressed ? 2 : 1.5)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct ViewerSparkle: View {
    @Environment(\.viewerPalette) private var palette
    @Environment(\.viewerNonNeon) private var nonNeon
    var size: CGFloat = 20

    var body: some View {
        ViewerSparkleShape()
            .stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            .foregroundStyle(LinearGradient(colors: nonNeon ? [palette.accentText.color, palette.accentText.color] : palette.brandStops.map(\.color), startPoint: .leading, endPoint: .trailing))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct ViewerSparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 12, y: 3))
        for point in [CGPoint(x: 13.9, y: 8.8), CGPoint(x: 20, y: 11), CGPoint(x: 13.9, y: 13.2), CGPoint(x: 12, y: 19), CGPoint(x: 10.1, y: 13.2), CGPoint(x: 4, y: 11), CGPoint(x: 10.1, y: 8.8)] { p.addLine(to: point) }
        p.closeSubpath()
        p.move(to: CGPoint(x: 20, y: 2)); p.addLine(to: CGPoint(x: 20, y: 6))
        p.move(to: CGPoint(x: 18, y: 4)); p.addLine(to: CGPoint(x: 22, y: 4))
        p.move(to: CGPoint(x: 3, y: 17)); p.addLine(to: CGPoint(x: 3, y: 21))
        p.move(to: CGPoint(x: 1, y: 19)); p.addLine(to: CGPoint(x: 5, y: 19))
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}
