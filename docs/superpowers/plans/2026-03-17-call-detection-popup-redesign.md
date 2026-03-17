# Call Detection Popup Redesign — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the call detection popup so it appears automatically on top of all windows (no menu bar click required), and redesign it as a compact branded notification banner.

**Architecture:** Two focused changes — (1) fix `CallDetectedOverlayController` window management by switching to `.nonactivatingPanel` and rebuilding the panel fresh on each show, (2) replace `CallDetectedPopup` with a compact notification-style SwiftUI view using material background and dBrief's orange brand.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit (`NSPanel`, `NSHostingController`), `@Observable`, `@MainActor`

**Spec:** `docs/superpowers/specs/2026-03-17-call-detection-popup-redesign.md`

---

## Chunk 1: Fix the overlay controller

### Task 1: Rewrite `CallDetectedOverlayController.show()` and `hide()`

**Files:**
- Modify: `Sources/dBrief/UI/CallDetectedOverlayController.swift`

This is a pure AppKit change. No SwiftUI layout changes yet — just the window management fix.

The current `show()` creates a `520×220` panel with `[.titled, .fullSizeContentView]` and reuses it across calls. The fix:
- Use `[.borderless, .nonactivatingPanel]` so the panel displays from a background LSUIElement process without requiring app activation
- Make the panel transparent (`isOpaque = false`, `backgroundColor = .clear`) — SwiftUI will paint the background
- Disable drag (`isMovableByWindowBackground = false`)
- Resize to `320×90`, position top-right (12pt from screen edge)
- Nil out `self.panel` in `hide()` so each subsequent show creates a fresh panel — without this, the second detection reuses the old panel with the old style mask and the bug recurs

- [ ] **Step 1: Replace `show()` and `hide()` in `CallDetectedOverlayController.swift`**

  Replace the entire `show()` method and `hide()` method with:

  ```swift
  func show() {
      guard let appState, let appSettings, let recordingManager else { return }

      let hosting = NSHostingController(
          rootView: CallDetectedPopup()
              .environment(appState)
              .environment(appSettings)
              .environment(recordingManager)
      )

      let newPanel = NSPanel(
          contentRect: NSRect(x: 0, y: 0, width: 320, height: 90),
          styleMask: [.borderless, .nonactivatingPanel],
          backing: .buffered,
          defer: true
      )
      newPanel.isOpaque = false
      newPanel.backgroundColor = .clear
      newPanel.hasShadow = true
      newPanel.isMovableByWindowBackground = false
      newPanel.level = .floating
      newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      newPanel.contentViewController = hosting
      self.panel = newPanel

      if let screen = NSScreen.main {
          let frame = screen.visibleFrame
          let size = NSSize(width: 320, height: 90)
          let origin = NSPoint(
              x: frame.maxX - size.width - 12,
              y: frame.maxY - size.height - 12
          )
          newPanel.setFrame(NSRect(origin: origin, size: size), display: true)
      }

      newPanel.orderFrontRegardless()
  }

  func hide() {
      panel?.orderOut(nil)
      panel = nil
  }
  ```

  Note: the `if panel == nil` creation guard is gone — panel is always created fresh.

- [ ] **Step 2: Build to confirm no compile errors**

  ```bash
  swift build 2>&1 | grep -E "error:|warning:" | head -30
  ```

  Expected: no errors. Warnings about unused imports are fine.

- [ ] **Step 3: Commit**

  ```bash
  git add Sources/dBrief/UI/CallDetectedOverlayController.swift
  git commit -m "fix: use nonactivatingPanel for call detection popup — appears without app activation"
  ```

---

## Chunk 2: Redesign the popup view

### Task 2: Replace `CallDetectedPopup` with compact notification banner

**Files:**
- Modify: `Sources/dBrief/UI/CallDetectedPopup.swift`

Replace the current large `VStack` layout with a compact notification banner. Key layout:
- `ZStack` — glass background behind content
- `HStack` — orange mic circle | text+buttons | xmark dismiss
- Background: `.regularMaterial` clipped to `RoundedRectangle(cornerRadius: 12)` with a 0.5pt `.quaternary` stroke overlay
- The panel is `320×90` — the SwiftUI view must fit within that without scrolling. Use fixed frame.

- [ ] **Step 1: Replace `CallDetectedPopup.swift` body**

  Full replacement of the view file:

  ```swift
  import SwiftUI

  struct CallDetectedPopup: View {
      @Environment(AppState.self) private var appState
      @Environment(AppSettings.self) private var appSettings
      @Environment(RecordingManager.self) private var recordingManager

      var body: some View {
          ZStack(alignment: .topTrailing) {
              // Glass background
              RoundedRectangle(cornerRadius: 12)
                  .fill(.regularMaterial)
                  .overlay(
                      RoundedRectangle(cornerRadius: 12)
                          .strokeBorder(.quaternary, lineWidth: 0.5)
                  )

              // Dismiss button
              Button {
                  appState.showCallDetectedPopup = false
              } label: {
                  Image(systemName: "xmark")
                      .font(.system(size: 9, weight: .semibold))
                      .foregroundStyle(.tertiary)
                      .padding(10)
              }
              .buttonStyle(.plain)

              // Content
              HStack(spacing: 10) {
                  // Branded icon
                  ZStack {
                      Circle()
                          .fill(
                              LinearGradient(
                                  colors: [Color(hex: "#FF6B00"), Color(hex: "#FF9500")],
                                  startPoint: .topLeading,
                                  endPoint: .bottomTrailing
                              )
                          )
                          .frame(width: 36, height: 36)
                      Image(systemName: "mic.fill")
                          .font(.system(size: 15, weight: .semibold))
                          .foregroundStyle(.white)
                  }

                  VStack(alignment: .leading, spacing: 3) {
                      Text("dBrief")
                          .font(.system(size: 10, weight: .semibold))
                          .foregroundStyle(.secondary)

                      Text("\(appState.detectedCallApp.map { "\($0) call" } ?? "A call") detected")
                          .font(.system(size: 13, weight: .medium))
                          .lineLimit(1)

                      HStack(spacing: 6) {
                          Button("Not Now") {
                              appState.showCallDetectedPopup = false
                          }
                          .buttonStyle(.bordered)
                          .controlSize(.mini)

                          Button("Record") {
                              appState.showCallDetectedPopup = false
                              Task {
                                  try? await recordingManager.startRecording(
                                      associatedApp: appState.detectedCallApp
                                  )
                              }
                          }
                          .buttonStyle(.borderedProminent)
                          .controlSize(.mini)
                          .tint(Color(hex: "#FF6B00"))
                      }
                  }

                  Spacer()
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
          }
          .frame(width: 320, height: 90)
      }
  }

  private extension Color {
      init(hex: String) {
          let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
          var int: UInt64 = 0
          Scanner(string: hex).scanHexInt64(&int)
          let r = Double((int >> 16) & 0xFF) / 255
          let g = Double((int >> 8) & 0xFF) / 255
          let b = Double(int & 0xFF) / 255
          self.init(red: r, green: g, blue: b)
      }
  }
  ```

- [ ] **Step 2: Build to confirm no compile errors**

  ```bash
  swift build 2>&1 | grep -E "error:|warning:" | head -30
  ```

  Expected: no errors.

- [ ] **Step 3: Commit**

  ```bash
  git add Sources/dBrief/UI/CallDetectedPopup.swift
  git commit -m "feat: redesign call detection popup as compact branded notification banner"
  ```

---

## Chunk 3: Build, verify, wrap up

### Task 3: Full build and manual smoke test

- [ ] **Step 1: Build the app bundle**

  ```bash
  make app
  ```

  Expected: successful build, `dBrief.app` updated.

- [ ] **Step 2: Manual smoke test**

  Launch the app and trigger a call detection scenario:
  1. Enable Call Detection in Settings → General if not already on
  2. **To simulate**: launch Zoom or Teams (so it is the frontmost app), then open QuickTime Player and start a new Audio Recording — this activates the default input device, which triggers `MicActivityMonitor`. Alternatively, use any app that activates the mic while a known call app is frontmost. Stop the QuickTime recording after the popup appears.
  3. Verify the popup appears in the **top-right corner** without clicking the dBrief menu bar icon
  4. Verify it sits **above** the call app window (not buried behind it)
  5. Verify the popup shows the orange mic icon, "dBrief" label, and app name
  6. Verify "Not Now" and "Record" buttons are present; "Don't Ask Again" is gone
  7. Dismiss the popup and trigger detection again — verify the popup appears again (fresh panel, no regression from panel reuse fix)
  8. Click "Record" — verify recording starts correctly
  9. **Full-screen check**: put any app in full-screen mode (Mission Control → drag to full-screen Space), then trigger detection again — verify the popup appears in that Space above the full-screen app

- [ ] **Step 3: Commit build artifact**

  ```bash
  git add dBrief.app/Contents/MacOS/dBrief
  git commit -m "build: rebuild app bundle with call detection popup fix"
  ```
