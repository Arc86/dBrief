# Call Detection Popup Redesign

**Date:** 2026-03-17
**Status:** Approved

## Problem

Two bugs, one design issue:

1. **Popup requires menu bar click to appear.** The `NSPanel` in `CallDetectedOverlayController` is missing `.nonactivatingPanel` in its style mask. Without it, `orderFrontRegardless()` does not work for a background LSUIElement app — the window is created but only becomes visible after the user activates dBrief by clicking its menu bar icon.

2. **Popup appears below other windows.** Same root cause: without `.nonactivatingPanel`, the panel cannot assert display priority while the app is inactive.

3. **Popup is too large and unbranded.** Current size is 520×220px, centered on screen, with a generic phone icon. It should feel like a native macOS notification — compact, recognisable, and non-intrusive.

## Root Cause

`NSPanel` style mask is `[.titled, .fullSizeContentView]`. Adding `.nonactivatingPanel` is the idiomatic macOS fix for utility panels from accessory/LSUIElement apps that need to surface without activating the owning application.

## Design

### Technical Fix

In `CallDetectedOverlayController.show()`:

- Change style mask from `[.titled, .fullSizeContentView]` to `[.borderless, .nonactivatingPanel]`
- Set `panel.isOpaque = false` and `panel.backgroundColor = .clear` to support the glass background rendered by SwiftUI
- Resize panel to 320×90
- Reposition to top-right corner: `x = screen.visibleFrame.maxX - 320 - 12`, `y = screen.visibleFrame.maxY - 90 - 12`
- Keep `panel.level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`
- Keep `panel.orderFrontRegardless()` — now works correctly with `.nonactivatingPanel`

### Visual Design

Notification banner style matching Option A:

| Property | Value |
|----------|-------|
| Size | 320 × 90 pt |
| Position | Top-right, 12pt margin from screen edge |
| Background | `.regularMaterial` in `RoundedRectangle(cornerRadius: 12)` |
| Border | 0.5pt `.quaternary` stroke |
| Shadow | System default (`hasShadow = true`) |
| Icon | 36×36 circle, orange gradient (`#FF6B00 → #FF9500`), `mic.fill` SF Symbol in white |
| Label | "dBrief" — 10pt semibold, `.secondary` color |
| Body text | "\<AppName\> call detected" — 13pt medium, primary |
| Buttons | "Not Now" (`.bordered`, `.mini`) + "Record" (`.borderedProminent`, `.mini`, `.tint(.orange)`) — left-aligned below text |
| Dismiss | `xmark` icon button top-right — same action as "Not Now" |

### Behaviour

- Appears automatically when a call is detected — no menu bar interaction required
- Does not steal keyboard focus from the call app
- Visible across all Spaces and full-screen apps
- SwiftUI provides the rounded glass background; the NSPanel itself is transparent and borderless

### Removed: "Don't Ask Again" button

The "Don't Ask Again" button is removed from the popup. Users can still add apps to the call detection blocklist via Settings → General → Call Detection. This keeps the popup focused on the immediate decision (record or dismiss) and avoids a three-button layout in a 320px banner.

## Files Changed

| File | Change |
|------|--------|
| `Sources/dBrief/UI/CallDetectedOverlayController.swift` | Style mask, opacity, size, position |
| `Sources/dBrief/UI/CallDetectedPopup.swift` | New compact notification layout; remove "Don't Ask Again" button |

## Out of Scope

- Animation (slide-in/out) — not required, can be added later
- Auto-dismiss timer — not requested
- Changes to `CallDetectionService` — detection logic is correct, only presentation is affected
