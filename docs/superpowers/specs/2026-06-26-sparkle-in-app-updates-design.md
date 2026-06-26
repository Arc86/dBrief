# Sparkle In-App Updates — Design

**Date:** 2026-06-26
**Status:** Approved, ready for implementation plan
**Author:** Jesper Mol (with Claude)

## Goal

Replace dBrief's notify-only updater with **Sparkle 2.x**, giving users true
in-app download + install of new releases (verify, download, relaunch) instead
of being sent to the GitHub release page for a manual DMG download.

This depends on the app being **Developer ID signed + notarized** — which is now
in order. Sparkle's seamless auto-install requires it: Gatekeeper blocks a
relaunched, un-notarized update, and Sparkle's installer XPC services must be
properly signed.

## Current state (what we're replacing)

A notify-only `UpdateService` (`Sources/dBrief/Services/UpdateService.swift`)
polls the GitHub Releases API, compares versions, and opens the browser for a
manual download. Its header comment already anticipated this migration ("a
future Sparkle migration only touches this file"). It is wired into four entry
points:

- `DBriefApp.swift` — silent launch check, menu-bar "update available" dot,
  launch overlay configuration.
- `SettingsGeneralTab.swift` — Settings → General → Updates section.
- `AboutTab.swift` — "Check for Updates" button.
- `UpdateAvailablePopup.swift` / `UpdateAvailableOverlayController.swift` —
  branded launch toast/overlay.

## Decisions (locked)

| Decision | Choice |
|----------|--------|
| Update UI | **Sparkle standard UI** — rip out the custom poller/popup/overlay; keep only "Check for Updates…" entry points that drive Sparkle. |
| Appcast hosting | **GitHub Releases** — `appcast.xml` uploaded as a release asset; `SUFeedURL` points at `releases/latest/download/appcast.xml`. |
| Update artifact | **Reuse the existing DMG** — Sparkle mounts `dBrief-<version>.dmg` and installs the `.app` inside. One artifact for both manual install and auto-update. |

## Design

### 1. Dependency & framework packaging

- Add **Sparkle 2.x** (`https://github.com/sparkle-project/Sparkle`, from
  `2.6.0`) as an SPM dependency on the **`dBrief` app target only** (not
  `dBriefWire` / `dBriefMLHost`).
- Sparkle is distributed as a binary `Sparkle.xcframework` that bundles XPC
  installer services and the `Autoupdate` / `Updater.app` helpers. Because
  `make app` assembles the bundle by hand (not via Xcode), the Makefile gains a
  step to **copy `Sparkle.framework` into `dBrief.app/Contents/Frameworks/`**
  and codesign it.
- **Signing order is load-bearing**: sign the nested `Sparkle.framework`
  (including its nested XPC services and `Autoupdate`/`Updater.app` helpers)
  **first** with hardened runtime, then sign the outer app **last**. This slots
  into the existing `make sign` / `make notarize` flow with the Developer ID
  identity and `packaging/dBrief.entitlements`. Reference: Sparkle's
  "Sandboxing"/"Code Signing" docs for non-sandboxed apps.

### 2. App code

- New small `UpdaterController` wrapping
  `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
  userDriverDelegate: nil)`, created in `AppContext` / `DBriefApp` and exposed
  via `.environment()`.
- A small `@Observable` `UpdaterViewModel` exposing `canCheckForUpdates`
  (bridged from Sparkle's KVO-observable property) and `checkForUpdates()`, so
  SwiftUI buttons enable/disable correctly.
- **Remove** the custom poller + its UI: `UpdateService.swift`,
  `UpdateAvailablePopup.swift`, `UpdateAvailableOverlayController.swift`, the
  launch-check overlay wiring in `DBriefApp`, and the menu-bar "update
  available" dot.
- **Replace** every former entry point with a Sparkle-driven "Check for
  Updates…" action:
  - **Settings → General → Updates**: "Check for Updates…" button + an
    "Automatically check for updates" toggle bound to Sparkle's
    `automaticallyChecksForUpdates`.
  - **About tab**: "Check for Updates…" drives Sparkle.
  - **Menu-bar menu**: a "Check for Updates…" item.
- Sparkle's built-in behavior then handles: launch check, once-per-day
  scheduling (with the first-run permission prompt), download progress UI,
  EdDSA signature verification, release-notes display, and relaunch.

### 3. Info.plist

`Sources/dBrief/Resources/Info.plist` gains:

- `SUFeedURL` = `https://github.com/Arc86/dBrief/releases/latest/download/appcast.xml`
- `SUPublicEDKey` = the base64 EdDSA public key (generated one-time, see §4).
- Automatic-check enablement left to Sparkle's first-run consent prompt (default
  on after the user agrees).

### 4. Release flow (Makefile + RELEASING.md)

**One-time setup:**

- Run Sparkle's `generate_keys` → the private EdDSA key is stored in the
  keychain; paste the printed public key into Info.plist as `SUPublicEDKey`.
- **Back up the private EdDSA key** the same way RELEASING.md already documents
  for the signing keychain. Losing it means no future release can be verified by
  existing installs (they'd be stuck until a manual reinstall with a new key).

**Each release** (after `make notarize` produces the notarized DMG):

- Run Sparkle's `generate_appcast` over the DMG → emits an EdDSA-signed
  `appcast.xml` carrying the version, minimum-system-version, length, and
  signature. Release notes are linked via `sparkle:releaseNotesLink` to the
  GitHub release page.
- Upload **both** the DMG and `appcast.xml` to the GitHub release:
  `gh release create vX.Y.Z dBrief-X.Y.Z.dmg appcast.xml …`.
- The feed is intentionally **latest-only** (one `<item>`, served from the
  latest release) — standard and sufficient for Sparkle's "is there something
  newer than me" check.

### 5. Testing

- Little pure logic survives this change: the old `UpdateService.isNewer` /
  `normalize` helpers are deleted along with the service, and there are no
  existing tests pinned to them. Sparkle owns the version comparison now.
- Verification is primarily a **manual end-to-end smoke test**, documented in
  RELEASING.md: build + notarize `vN`, publish a `vN+1` test appcast, and
  confirm a running `vN` detects, downloads, verifies (EdDSA), installs, and
  relaunches into `vN+1`.

## Trade-offs / call-outs

- **DMG-as-update** keeps the release flow to a single artifact at the cost of
  ruling out Sparkle **delta updates** (which need ZIPs). Acceptable for an app
  of this release cadence; revisitable later by adding a ZIP artifact.
- **Notarization is a hard prerequisite** for the auto-install path. All code,
  Makefile, and docs are built to be merge-ready now, but full end-to-end
  install can only be validated against a notarized build.
- **Nested-framework signing** is the riskiest implementation step; the plan
  must verify `codesign --verify --deep --strict` and a real notarization run
  pass with Sparkle embedded before declaring done.

## Out of scope

- Sparkle delta updates, update channels (beta/stable), and automatic silent
  background installs.
- Migrating the Homebrew-from-source path (those users update via `brew
  upgrade`, unaffected by Sparkle).
