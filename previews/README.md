# Menu bar visual preview

Standalone SwiftUI prototype based on the Pen menu bar frames. The Idle, Recording, Complete and Output tabs switch between mock states; both light and dark appearances are shown together. Panel controls are static visual elements and cannot record, process, delete, copy or change settings.

Build, export screenshots and open the native review window:

```sh
zsh previews/build-menu-bar-preview.sh --open
```

The prototype compiles directly with `swiftc`, without building dBrief or its dependencies. Source lives outside `Sources/` so the production app does not include it. Generated preview bundle is under `previews/build/`; all eight panel images and four comparison images are under `previews/renders/`.

This is the visual review stage only. The production implementation plan remains unexecuted. Native system typography substitutes for Inter; sample output text is readable English. Fixed canvas heights reproduce the reference compositions; the review window scrolls on smaller displays.

Verified: compiled with Swift 6.3.3 for macOS 14; exported all eight light/dark panel images and four comparison images; inspected each state's composition and corrected title/profile wrapping and shadow compositing. The native preview window opens with Idle selected. Logo artwork is exported from Pen's `zIunb` node.
