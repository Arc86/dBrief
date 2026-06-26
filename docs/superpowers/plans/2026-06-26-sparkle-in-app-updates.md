# Sparkle In-App Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace dBrief's notify-only `UpdateService` with Sparkle 2.x so users download + install updates in-app (verify, download, relaunch) instead of being sent to GitHub for a manual DMG download.

**Architecture:** Add Sparkle as an SPM dependency on the app target. A thin `@MainActor @Observable UpdaterController` wraps `SPUStandardUpdaterController` and exposes `canCheckForUpdates`, `checkForUpdates()`, and the auto-check toggle to SwiftUI. The custom poller/popup/overlay are deleted; the three former entry points (Settings, About, menu bar) just call Sparkle's standard UI. The `make app` bundle embeds + codesigns `Sparkle.framework`; releases publish an EdDSA-signed `appcast.xml` as a GitHub Release asset alongside the existing DMG.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Observation (`@Observable`), Sparkle 2.x (SPM binary framework), Make-based bundling, GitHub Releases, EdDSA (ed25519) update signing.

## Global Constraints

- Sparkle version floor: `from: "2.6.0"`; added to the **`dBrief` app target only** (never `dBriefWire` / `dBriefMLHost`).
- Owner/repo: `Arc86/dBrief`. Feed URL: `https://github.com/Arc86/dBrief/releases/latest/download/appcast.xml`.
- Update artifact is the **existing `dBrief-<version>.dmg`** — no separate ZIP, no delta updates.
- Version source of truth stays `Sources/dBrief/Resources/Info.plist` (`CFBundleShortVersionString` + `CFBundleVersion`); git tag is `v<version>`.
- Sparkle's seamless install requires the **Developer ID + notarized** path (`make notarize`); the self-signed/ad-hoc path still compiles and launches but is not the shipping update path.
- All UI/state classes are `@MainActor @Observable`; follow the existing BrandKit styling and `Logger.app` logging conventions.
- The signing keychain note in RELEASING.md now has a sibling: the **EdDSA private key** is a second irreplaceable secret that must be backed up.

---

### Task 1: Add the Sparkle SPM dependency

**Files:**
- Modify: `Package.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: the `Sparkle` product is linkable from the `dBrief` target (`import Sparkle` compiles).

- [ ] **Step 1: Add the package dependency**

In `Package.swift`, add to the top-level `dependencies:` array (after the FluidAudio line):

```swift
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
```

- [ ] **Step 2: Add the product to the `dBrief` target**

In the `dBrief` executable target's `dependencies:` array, add:

```swift
                .product(name: "Sparkle", package: "Sparkle"),
```

(Leave `dBriefWire` and `dBriefMLHost` untouched.)

- [ ] **Step 3: Resolve and build**

Run: `swift build`
Expected: dependency resolves and the project compiles (Sparkle linked but not yet referenced). Note the resolved Sparkle version for later: `grep -A2 '"sparkle"' Package.resolved` — you'll match the appcast tools to it in Task 8.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build: add Sparkle SPM dependency to the dBrief app target"
```

---

### Task 2: Generate EdDSA keys and add the Sparkle Info.plist keys

This produces a real artifact (the public key) that the app needs, and a private key that must be backed up. It is one-time setup the implementer performs locally.

**Files:**
- Modify: `Sources/dBrief/Resources/Info.plist`

**Interfaces:**
- Consumes: nothing.
- Produces: `SUFeedURL` + `SUPublicEDKey` present in the bundle's Info.plist so Sparkle can verify and locate updates.

- [ ] **Step 1: Download the matching Sparkle tools**

Use the same version `swift build` resolved in Task 1 (call it `X.Y.Z`):

```bash
SPARKLE_VER=X.Y.Z
curl -L -o /tmp/Sparkle-$SPARKLE_VER.tar.xz \
  https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VER/Sparkle-$SPARKLE_VER.tar.xz
mkdir -p /tmp/sparkle-tools && tar -xf /tmp/Sparkle-$SPARKLE_VER.tar.xz -C /tmp/sparkle-tools
# tools are in /tmp/sparkle-tools/bin/ : generate_keys, generate_appcast, sign_update
```

- [ ] **Step 2: Generate the key pair**

```bash
/tmp/sparkle-tools/bin/generate_keys
```

Expected: it stores the **private** key in your login keychain and prints a line like
`<string>BASE64PUBLICKEY==</string>` (the public key). Copy that base64 value.

- [ ] **Step 3: Back up the private key (do not skip)**

```bash
/tmp/sparkle-tools/bin/generate_keys -x ~/dbrief-sparkle-private-key.txt
# Move this file into your password manager / vault, then delete the local copy.
```

Losing this key means existing installs can never verify a future release.

- [ ] **Step 4: Add the keys to Info.plist**

In `Sources/dBrief/Resources/Info.plist`, add these entries inside the top-level `<dict>` (e.g. right after the `CFBundleVersion` pair), replacing the placeholder with the real base64 public key from Step 2:

```xml
	<key>SUFeedURL</key>
	<string>https://github.com/Arc86/dBrief/releases/latest/download/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>BASE64PUBLICKEY==</string>
```

- [ ] **Step 5: Verify the plist still parses**

Run: `plutil -lint Sources/dBrief/Resources/Info.plist`
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add Sources/dBrief/Resources/Info.plist
git commit -m "feat: add Sparkle SUFeedURL + SUPublicEDKey to Info.plist"
```

---

### Task 3: Create the `UpdaterController` wrapper

**Files:**
- Create: `Sources/dBrief/Services/UpdaterController.swift`

**Interfaces:**
- Consumes: `Sparkle` (`SPUStandardUpdaterController`, `SPUUpdater`).
- Produces:
  - `@MainActor @Observable final class UpdaterController`
  - `var canCheckForUpdates: Bool` (private(set), KVO-mirrored)
  - `func checkForUpdates()`
  - `var automaticallyChecksForUpdates: Bool` (get/set, persisted by Sparkle)
  - `var lastUpdateCheckDate: Date?`

- [ ] **Step 1: Write the controller**

Create `Sources/dBrief/Services/UpdaterController.swift`:

```swift
import AppKit
import Foundation
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController`. Owns the updater,
/// mirrors its `canCheckForUpdates` flag into an `@Observable` property so SwiftUI
/// buttons can disable themselves while a check is in flight, and exposes the
/// standard "check now" + auto-check toggle. Sparkle owns all update UI, download,
/// EdDSA verification, and relaunch.
///
/// All Sparkle/feed specifics live here (and in Info.plist's SUFeedURL /
/// SUPublicEDKey), so the rest of the app stays update-mechanism-agnostic.
@MainActor
@Observable
final class UpdaterController {
    private let controller: SPUStandardUpdaterController
    private var canCheckObservation: NSKeyValueObservation?

    /// Mirrors `SPUUpdater.canCheckForUpdates`.
    private(set) var canCheckForUpdates = false

    init() {
        // startingUpdater: true → Sparkle starts its scheduler immediately, so the
        // automatic launch / once-per-day checks happen without extra wiring.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

        canCheckForUpdates = controller.updater.canCheckForUpdates
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    /// Sparkle's standard "check for updates" — shows the full update UI.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// Whether Sparkle automatically checks on its schedule. Persisted by Sparkle
    /// itself (UserDefaults `SUEnableAutomaticChecks`).
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Date of the last update check, for a "Last checked" caption.
    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }
}
```

- [ ] **Step 2: Build (controller compiles, not yet referenced)**

Run: `swift build`
Expected: compiles with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/dBrief/Services/UpdaterController.swift
git commit -m "feat: add UpdaterController wrapping Sparkle's standard updater"
```

---

### Task 4: Migrate all consumers to `UpdaterController` and delete the old updater

This is one atomic change: it swaps the environment type across `DBriefApp`, `SettingsGeneralTab`, and `AboutTab`, removes the launch-check/overlay/menu-bar-dot, deletes the three old files, and removes the now-dead `AppSettings` keys. It is the smallest unit that compiles.

**Files:**
- Modify: `Sources/dBrief/App/DBriefApp.swift`
- Modify: `Sources/dBrief/UI/SettingsGeneralTab.swift`
- Modify: `Sources/dBrief/UI/AboutTab.swift`
- Modify: `Sources/dBrief/App/AppSettings.swift`
- Delete: `Sources/dBrief/Services/UpdateService.swift`
- Delete: `Sources/dBrief/UI/UpdateAvailablePopup.swift`
- Delete: `Sources/dBrief/UI/UpdateAvailableOverlayController.swift`

**Interfaces:**
- Consumes: `UpdaterController` from Task 3.
- Produces: a build with Sparkle as the sole update mechanism; `UpdateService` no longer exists.

- [ ] **Step 1: Swap the AppContext field**

In `Sources/dBrief/App/DBriefApp.swift`, replace line 22:

```swift
    let updateService = UpdateService()
```

with:

```swift
    let updaterController = UpdaterController()
```

- [ ] **Step 2: Remove the overlay configuration**

In `Sources/dBrief/App/DBriefApp.swift`, delete this line (currently line 41):

```swift
        UpdateAvailableOverlayController.shared.configure(updateService: updateService)
```

- [ ] **Step 3: Remove the launch-time silent check + popup**

In `Sources/dBrief/App/DBriefApp.swift`, in `ensureReady()`, delete the entire silent-check and popup blocks (currently lines 93–110):

```swift
        // Silent update check on launch, throttled to once per 24h
        if appSettings.autoCheckUpdates {
            let last = appSettings.lastUpdateCheckTime
            let due = last == nil || Date().timeIntervalSince(last!) >= 24 * 60 * 60
            if due {
                await updateService.checkForUpdates(manual: false)
                appSettings.lastUpdateCheckTime = Date()
            }
        }

        // Surface the "Update available" popup once per new release. The menu-bar
        // badge and Settings → Updates section remain as the persistent affordance.
        if updateService.updateAvailable,
           let latest = updateService.latestVersion,
           latest != appSettings.lastNotifiedUpdateVersion {
            appSettings.lastNotifiedUpdateVersion = latest
            UpdateAvailableOverlayController.shared.show()
        }
```

(Sparkle's `startingUpdater: true` + auto-checks replace this. Leave the surrounding `runRetentionCleanupIfNeeded()` / prewarm lines intact.)

- [ ] **Step 4: Update the Settings-scene injection; drop the menu-bar one**

In `Sources/dBrief/App/DBriefApp.swift`, in the `Window("Settings", …)` scene, replace:

```swift
                .environment(context.updateService)
```

with:

```swift
                .environment(context.updaterController)
```

In the `MenuBarExtra` scene, **delete** its `.environment(context.updateService)` line entirely — the menu-bar popover no longer references the updater (the dot is removed in Step 5).

- [ ] **Step 5: Remove the updater from `MenuBarView` (env + update dot)**

In `Sources/dBrief/App/DBriefApp.swift`, in `MenuBarView`, **delete** the environment line:

```swift
    @Environment(UpdateService.self) private var updateService
```

Then in the `header` view, delete the update-dot block (currently lines 422–431):

```swift
            if updateService.updateAvailable {
                Button {
                    updateService.openReleasePage()
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Update available\(updateService.latestVersion.map { " — version \($0)" } ?? "")")
            }
```

Net: the menu-bar popover references the updater nowhere. Update checks live in Settings + About only (plus Sparkle's automatic launch/scheduled checks).

- [ ] **Step 6: Rewrite the Settings "Software update" section**

In `Sources/dBrief/UI/SettingsGeneralTab.swift`, replace the environment declaration (line 8):

```swift
    @Environment(UpdateService.self) private var updateService
```

with:

```swift
    @Environment(UpdaterController.self) private var updaterController
```

Then replace the entire `Section("Software update")` block (currently lines 213–262) with:

```swift
            Section("Software update") {
                LabeledContent("Check for updates") {
                    Button("Check Now") {
                        updaterController.checkForUpdates()
                    }
                    .disabled(!updaterController.canCheckForUpdates)
                }

                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updaterController.automaticallyChecksForUpdates },
                    set: { updaterController.automaticallyChecksForUpdates = $0 }
                ))

                if let lastCheck = updaterController.lastUpdateCheckDate {
                    Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.clear)
```

- [ ] **Step 7: Rewire the About tab update card**

In `Sources/dBrief/UI/AboutTab.swift`:

a) Replace the two `@State` lines (11–12):

```swift
    @State private var update = UpdateService()
    @State private var phase: UpdatePhase = .idle
```

with:

```swift
    @Environment(UpdaterController.self) private var updaterController
```

b) Delete the now-unused enum (line 15):

```swift
    enum UpdatePhase { case idle, checking, upToDate, available }
```

c) Replace the entire update-card cluster — the members `updateCard`, `updateIcon`, `updateButton`, `runCheck`, `updateTitle`, `updateSubtitle`, `updateIconTint`, `updateCardTint`, `updateCardStroke` (currently lines 150–270) — with this simpler, Sparkle-driven card:

```swift
    private var updateCard: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 38, height: 38)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Keep dBrief up to date")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("You're on v\(shortVersion)")
                    .font(.brandMono(12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Check for updates") { updaterController.checkForUpdates() }
                .buttonStyle(.plain)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Color.primary, in: Capsule())
                .disabled(!updaterController.canCheckForUpdates)
        }
        .padding(16)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
```

(The `updateCard` call site at line 72 is unchanged. Sparkle now shows checking/available/up-to-date state in its own dialog, so the `phase` state machine is gone.)

- [ ] **Step 8: Remove the dead AppSettings keys**

In `Sources/dBrief/App/AppSettings.swift`, delete the three update-related members that only served `UpdateService`:

- The `Keys` constants (lines 84–86): `autoCheckUpdates`, `lastUpdateCheckTime`, `lastNotifiedUpdateVersion`.
- The stored property `autoCheckUpdates` + its `didSet` (lines ~345–347).
- The stored property `lastUpdateCheckTime` + its `didSet` (lines ~350–360).
- The stored property `lastNotifiedUpdateVersion` + its `didSet` (lines ~362–369).
- The three matching initializer lines in `init` (lines ~883–889).

(Use `grep -n "autoCheckUpdates\|lastUpdateCheckTime\|lastNotifiedUpdateVersion" Sources/dBrief/App/AppSettings.swift` to confirm every reference is gone afterward.)

- [ ] **Step 9: Delete the three obsolete files**

```bash
git rm Sources/dBrief/Services/UpdateService.swift \
       Sources/dBrief/UI/UpdateAvailablePopup.swift \
       Sources/dBrief/UI/UpdateAvailableOverlayController.swift
```

- [ ] **Step 10: Build and confirm no stragglers**

Run: `swift build`
Expected: compiles. Then:
Run: `grep -rn "UpdateService\|UpdateAvailable\|updateService\|autoCheckUpdates" Sources/dBrief`
Expected: no matches (every reference migrated or removed).

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "feat: drive updates through Sparkle; remove notify-only UpdateService"
```

---

### Task 5: Embed `Sparkle.framework` in the app bundle (`make app`)

**Files:**
- Modify: `Makefile` (`app:` target)

**Interfaces:**
- Consumes: `Sparkle.framework` produced under `.build/` by `swift build`.
- Produces: `dBrief.app/Contents/Frameworks/Sparkle.framework` present, with the main executable carrying an `@executable_path/../Frameworks` rpath.

- [ ] **Step 1: Add the embed + rpath block**

In `Makefile`, in the `app:` target, immediately **before** the `@$(MAKE) sign` line (currently line 100), insert:

```make
	@set -e; \
	SPARKLE_FW="$$(find .build -type d -name 'Sparkle.framework' -path '*release*' | head -n 1)"; \
	if [ -z "$$SPARKLE_FW" ]; then SPARKLE_FW="$$(find .build -type d -name 'Sparkle.framework' | head -n 1)"; fi; \
	if [ -z "$$SPARKLE_FW" ]; then \
		echo "ERROR: Sparkle.framework not found under .build — run 'swift build' first." >&2; exit 1; fi; \
	echo "Embedding Sparkle.framework from $$SPARKLE_FW"; \
	mkdir -p "$(CONTENTS)/Frameworks"; \
	rm -rf "$(CONTENTS)/Frameworks/Sparkle.framework"; \
	cp -R "$$SPARKLE_FW" "$(CONTENTS)/Frameworks/Sparkle.framework"; \
	if ! otool -l "$(MACOS)/$(EXECUTABLE_NAME)" | grep -q "@executable_path/../Frameworks"; then \
		install_name_tool -add_rpath "@executable_path/../Frameworks" "$(MACOS)/$(EXECUTABLE_NAME)"; \
	fi
```

- [ ] **Step 2: Build the bundle**

Run: `make app`
Expected: build succeeds; "Embedding Sparkle.framework from …" printed; `codesign --verify --deep --strict` (run by the existing `sign:` target via `--deep` on the self-signed path) passes with Sparkle nested inside.

- [ ] **Step 3: Verify the framework and rpath are present**

```bash
ls -d dBrief.app/Contents/Frameworks/Sparkle.framework
otool -l dBrief.app/Contents/MacOS/dBrief | grep -A2 LC_RPATH | grep Frameworks
```

Expected: the framework directory exists and an rpath containing `@executable_path/../Frameworks` is listed.

- [ ] **Step 4: Launch-smoke the self-signed build**

Run: `make run`
Expected: the app launches (menu-bar icon appears) with Sparkle loaded — no dyld "Library not loaded: @rpath/Sparkle.framework" crash. Open **Settings → General → Software update** and confirm "Check Now" is enabled. (On a self-signed build the check may report it can't verify/secure-update — that is expected; the notarized path in Task 8 is the real one.)

- [ ] **Step 5: Commit**

```bash
git add Makefile
git commit -m "build: embed Sparkle.framework into the app bundle with Frameworks rpath"
```

---

### Task 6: Sign `Sparkle.framework` inside-out on the Developer ID path

**Files:**
- Modify: `Makefile` (`sign:` target, Developer ID branch)

**Interfaces:**
- Consumes: the embedded `Sparkle.framework` from Task 5.
- Produces: a hardened-runtime-signed Sparkle framework (XPC services + helpers + framework) signed **before** the main executable, so notarization accepts the bundle.

- [ ] **Step 1: Add nested Sparkle signing before the main-exe sign**

In `Makefile`, in the `sign:` target's `"Developer ID Application:"*)` branch, immediately **before** the line that signs the main executable —

```make
			codesign --force --options runtime --timestamp --entitlements "$(ENTITLEMENTS)" --sign "$$IDENTITY" "$(MACOS)/$(EXECUTABLE_NAME)"; \
```

— insert:

```make
			: 'Sign the embedded Sparkle.framework inside-out (XPC services, Autoupdate/Updater.app helpers, then the framework) BEFORE the main executable, so the bundle-level seal accepts it. The self-signed branch below relies on --deep instead.'; \
			if [ -d "$(CONTENTS)/Frameworks/Sparkle.framework" ]; then \
				SPK="$(CONTENTS)/Frameworks/Sparkle.framework"; \
				find "$$SPK" -name '*.xpc' -exec codesign --force --options runtime --timestamp --sign "$$IDENTITY" {} \;; \
				find "$$SPK" -name 'Autoupdate' -type f -exec codesign --force --options runtime --timestamp --sign "$$IDENTITY" {} \;; \
				find "$$SPK" -name 'Updater.app' -exec codesign --force --options runtime --timestamp --sign "$$IDENTITY" {} \;; \
				codesign --force --options runtime --timestamp --sign "$$IDENTITY" "$$SPK"; \
			fi; \
```

(The `*)` self-signed/ad-hoc branch already uses `codesign --force --deep`, which signs nested Sparkle code automatically; no change needed there.)

- [ ] **Step 2: Verify the Developer ID signing path (if a Developer ID identity is available)**

If you have the Developer ID identity locally:

```bash
make app CODESIGN_IDENTITY="Developer ID Application: <Your Name> (TEAMID)"
codesign --verify --deep --strict --verbose=2 dBrief.app
codesign -dvv dBrief.app/Contents/Frameworks/Sparkle.framework 2>&1 | grep -E "Authority|flags"
```

Expected: `--verify --deep --strict` passes; the Sparkle framework's authority is your Developer ID and `flags=…(runtime)` is set.

If no Developer ID identity is available in this environment, skip the live run and rely on Task 8's notarization run; record that this step is deferred.

- [ ] **Step 3: Commit**

```bash
git add Makefile
git commit -m "build: sign embedded Sparkle.framework inside-out on the Developer ID path"
```

---

### Task 7: Document the release flow + manual smoke test (RELEASING.md)

**Files:**
- Modify: `RELEASING.md`

**Interfaces:**
- Consumes: the `make notarize` DMG output and the Sparkle tools from Task 2.
- Produces: written one-time setup, per-release appcast steps, and an end-to-end smoke-test procedure.

- [ ] **Step 1: Add a "Sparkle in-app updates" section**

In `RELEASING.md`, after the existing "Notarized Developer ID release" section, add:

```markdown
## Sparkle in-app updates

Updates are delivered in-app by [Sparkle](https://sparkle-project.org). The app
reads `SUFeedURL` (an `appcast.xml` published as a GitHub Release asset) and
verifies each download against the `SUPublicEDKey` baked into Info.plist.

### One-time setup

1. Install the Sparkle tools matching the resolved package version (`grep -A2 '"sparkle"' Package.resolved`):
   ```bash
   SPARKLE_VER=X.Y.Z
   curl -L -o /tmp/Sparkle-$SPARKLE_VER.tar.xz \
     https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VER/Sparkle-$SPARKLE_VER.tar.xz
   mkdir -p /tmp/sparkle-tools && tar -xf /tmp/Sparkle-$SPARKLE_VER.tar.xz -C /tmp/sparkle-tools
   ```
2. `generate_keys` once (already done if `SUPublicEDKey` is set in Info.plist). **Back up the private key** to your vault:
   ```bash
   /tmp/sparkle-tools/bin/generate_keys -x ~/dbrief-sparkle-private-key.txt   # then move into your vault
   ```
   This is a second irreplaceable secret alongside the signing keychain — losing it strands all existing installs.

### Each release (after `make notarize`)

`make notarize` produces the stapled `dBrief-<version>.dmg`. Then:

```bash
mkdir -p /tmp/dbrief-appcast
cp dBrief-<version>.dmg /tmp/dbrief-appcast/
/tmp/sparkle-tools/bin/generate_appcast \
  --download-url-prefix "https://github.com/Arc86/dBrief/releases/download/v<version>/" \
  --full-release-notes-link "https://github.com/Arc86/dBrief/releases" \
  /tmp/dbrief-appcast
# → writes /tmp/dbrief-appcast/appcast.xml, EdDSA-signed with your private key
```

Upload **both** the DMG and the appcast to the GitHub release:

```bash
gh release create v<version> dBrief-<version>.dmg /tmp/dbrief-appcast/appcast.xml \
  --title "dBrief <version>" --notes-file RELEASE_NOTES.md
# (or `gh release upload v<version> …` if the release already exists)
```

Because `SUFeedURL` points at `releases/latest/download/appcast.xml`, the feed
always resolves to the newest release's appcast. The feed is latest-only (one
`<item>`) — sufficient for Sparkle's "is there something newer?" check. Richer
multi-version notes are a possible follow-up.

### Manual smoke test (do this once after wiring Sparkle, and when bumping Sparkle)

1. Build + notarize version N, install it to /Applications, and launch it.
2. Build + notarize version N+1, generate its appcast, and publish it to a test
   release (or point `SUFeedURL` at a scratch feed).
3. In the running N, **Settings → General → Software update → Check Now**.
   Confirm Sparkle shows the update, downloads it, verifies the EdDSA signature,
   installs, and relaunches into N+1 with no Gatekeeper prompt.
```

- [ ] **Step 2: Update the intro paragraph**

In `RELEASING.md`, update the first paragraph (line 3) so it no longer says the updater is GitHub-API-polling/manual-download. Replace:

```markdown
Releases are built locally and uploaded to GitHub by hand. The in-app updater ([`UpdateService`](Sources/dBrief/Services/UpdateService.swift)) polls the GitHub Releases API, so publishing a release is what makes the update prompt appear for existing users.
```

with:

```markdown
Releases are built locally and uploaded to GitHub by hand. The in-app updater uses [Sparkle](https://sparkle-project.org): it reads an EdDSA-signed `appcast.xml` published as a GitHub Release asset and downloads + installs the new DMG in-app. Publishing a release with its appcast is what makes existing installs offer the update. See [Sparkle in-app updates](#sparkle-in-app-updates).
```

- [ ] **Step 3: Commit**

```bash
git add RELEASING.md
git commit -m "docs: document Sparkle appcast release flow + update smoke test"
```

---

### Task 8: End-to-end notarized verification

This is the real validation of the seamless-install path. Requires the Developer ID identity + notarytool profile.

**Files:** none (verification only).

- [ ] **Step 1: Notarize a build**

Run:
```bash
make notarize CODESIGN_IDENTITY="Developer ID Application: <Your Name> (TEAMID)" NOTARY_PROFILE=dbrief
```
Expected: notarization succeeds and `dBrief-<version>.dmg` is stapled. (If rejected, read `xcrun notarytool log <id> --keychain-profile dbrief`; Sparkle's helpers are the usual suspect — confirm they were signed with `-o runtime` per Task 6.)

- [ ] **Step 2: Generate + publish a test appcast**

Follow RELEASING.md "Each release" against a scratch/test GitHub release one minor version above the currently-installed app.

- [ ] **Step 3: Run the smoke test**

Follow RELEASING.md "Manual smoke test". Confirm detect → download → EdDSA verify → install → relaunch end to end with no Gatekeeper prompt.

- [ ] **Step 4: Record the result**

Note the outcome in the PR description / commit trailer. No code commit unless the smoke test surfaces a fix (in which case fix, then re-run from Step 1).

---

## Self-Review

**1. Spec coverage**
- Dependency on app target only → Task 1. ✅
- Framework packaging + signing order → Tasks 5, 6. ✅
- `UpdaterController` + `@Observable` KVO bridge → Task 3. ✅
- Remove UpdateService/popup/overlay + launch check + menu-bar dot → Task 4. ✅
- Sparkle standard UI at all three entry points (Settings, About, menu bar) → Task 4 (menu bar: dot removed, no item added — matches "keep only Check-for-Updates entry points"; Settings + About have the buttons). ✅
- Info.plist `SUFeedURL` + `SUPublicEDKey` → Task 2. ✅
- GitHub Releases appcast, DMG artifact, latest-only feed → Task 7. ✅
- EdDSA key gen + backup → Tasks 2, 7. ✅
- Testing = manual smoke test, little pure logic → Tasks 7, 8 (honest: no xunit tests added; the wrapper is a thin Sparkle shim and the deleted helpers had no tests). ✅
- Notarization as hard prerequisite → Task 8. ✅
- Out of scope (deltas, channels, Homebrew path) → untouched. ✅

**2. Placeholder scan:** `BASE64PUBLICKEY==`, `X.Y.Z`, `<version>`, and `TEAMID` are real values the implementer fills from `generate_keys` / the version bump / their Developer ID — each step says exactly how to obtain them. No "TBD"/"handle edge cases"/"similar to Task N" placeholders.

**3. Type consistency:** `UpdaterController` members (`canCheckForUpdates`, `checkForUpdates()`, `automaticallyChecksForUpdates`, `lastUpdateCheckDate`) are defined in Task 3 and used with those exact names/types in Task 4. The AppContext field is `updaterController` everywhere; the environment type is `UpdaterController`. Makefile var `SPK`/`SPARKLE_FW` are local to their steps.
