import Foundation

/// Stable speaker-identity colours. The slot depends only on the diarization
/// ID, so renaming a speaker or marking that speaker as “me” does not recolour it.
enum ViewerSpeakerPalette {
    private static let lightSpeakers = [
        rgb("#3371CD"), rgb("#9854BD"), rgb("#16827C"), rgb("#B85C27"),
        rgb("#BE4858"), rgb("#43804F"), rgb("#9B701B"), rgb("#34778F"),
    ]
    private static let darkSpeakers = [
        rgb("#75A6F0"), rgb("#C38BE0"), rgb("#58BDB2"), rgb("#E69A69"),
        rgb("#E77D8C"), rgb("#7AC487"), rgb("#D6B85E"), rgb("#72BBD7"),
    ]
    private static let paperSpeakers = [
        rgb("#2D64B4"), rgb("#8B4BAA"), rgb("#14766F"), rgb("#A75825"),
        rgb("#AC3D4E"), rgb("#2F7441"), rgb("#8D6517"), rgb("#286A80"),
    ]
    private static let darkPaperSpeakers = [
        rgb("#829ED2"), rgb("#B18DC4"), rgb("#73ADA4"), rgb("#D0A077"),
        rgb("#C9858D"), rgb("#8EAA7B"), rgb("#BEAD78"), rgb("#82AEBF"),
    ]
    private static let lightNeutral = rgb("#65718A")
    private static let darkNeutral = rgb("#A3AFC4")
    private static let paperNeutral = rgb("#756D60")
    private static let darkPaperNeutral = rgb("#B9AD98")

    static func color(for speakerID: String?, mode: ViewerAppearanceMode) -> ViewerRGB {
        guard let speakerID,
              !speakerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return neutral(for: mode)
        }

        let colours = speakers(for: mode)
        let slot = speakerID.unicodeScalars.reduce(into: 0) { index, scalar in
            index = (index + Int(scalar.value % UInt32(colours.count))) % colours.count
        }
        return colours[slot]
    }

    private static func speakers(for mode: ViewerAppearanceMode) -> [ViewerRGB] {
        switch mode {
        case .light: lightSpeakers
        case .dark: darkSpeakers
        case .paper: paperSpeakers
        case .darkPaper: darkPaperSpeakers
        }
    }

    private static func neutral(for mode: ViewerAppearanceMode) -> ViewerRGB {
        switch mode {
        case .light: lightNeutral
        case .dark: darkNeutral
        case .paper: paperNeutral
        case .darkPaper: darkPaperNeutral
        }
    }

    private static func rgb(_ hex: String) -> ViewerRGB {
        ViewerRGB(hex: hex)!
    }
}
