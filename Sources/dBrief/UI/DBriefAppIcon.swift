import AppKit

/// The full-color artwork shared by in-app surfaces. The bundle icon remains
/// the macOS app icon; use the PNG here so every screen shows the same image.
@MainActor
enum DBriefAppIcon {
    static let image: NSImage? = {
        if let url = Bundle.main.url(forResource: "dBrief-Icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(named: "AppIcon")
    }()

    /// The artwork already includes its rounded enclosure. Drawing it directly
    /// keeps Tahoe from shrinking that enclosure inside a second pale tile.
    static func installDockIcon() {
        guard let image else { return }
        let tile = NSApp.dockTile
        let view = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.autoresizingMask = [.width, .height]
        tile.contentView = view
        tile.display()
    }
}
