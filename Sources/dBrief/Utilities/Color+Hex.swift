import SwiftUI

extension Color {
    /// Initialise from a 6-digit hex string (with or without leading `#`).
    /// Example: `Color(hex: "ff453a")`
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var rgbValue: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgbValue)
        let r = Double((rgbValue & 0xff0000) >> 16) / 255
        let g = Double((rgbValue & 0x00ff00) >> 8) / 255
        let b = Double(rgbValue & 0x0000ff) / 255
        self.init(red: r, green: g, blue: b)
    }
}
