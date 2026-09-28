# Native macOS app icon

This Icon Composer document supplies the full-tile icon for macOS Tahoe.
It uses the existing logo without glass, translucency, or layer shadows.
The 1.22 scale fills the native mask instead of nesting the artwork's own
rounded enclosure inside another tile.

Run `make icons` with Xcode 26 or later after editing this document or its
artwork. Commit the resulting `Sources/dBrief/Resources/Assets.car` so normal
app builds need only Command Line Tools. `make app` copies this catalog into
the bundle; `CFBundleIconName` selects it on Tahoe. The original `AppIcon.icns`
is kept for compatibility, and the direct Dock image is unchanged.
