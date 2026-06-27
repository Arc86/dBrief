# Releasing dBrief

dBrief ships as an **Apple Silicon**, **Developer ID-signed & notarized** macOS app (notarized since **v1.3.1**). Releases are built locally and uploaded to GitHub by hand. The in-app updater uses [Sparkle](https://sparkle-project.org): it reads an EdDSA-signed `appcast.xml` published as a GitHub Release asset and downloads + installs the new DMG in-app. Publishing a release with its appcast is what makes existing installs offer the update. See [Sparkle in-app updates](#sparkle-in-app-updates).

There are two distribution paths, signed differently:

- **Notarized DMG** (what we upload to GitHub Releases) — hardened-runtime, signed with a **Developer ID** certificate and notarized + stapled by Apple, so it opens with **no Gatekeeper prompt** and no `xattr` workaround. This is the primary path; see [Cutting a notarized release](#cutting-a-notarized-release).
- **Homebrew-from-source** — the formula compiles on the user's machine and signs with a **stable per-machine self-signed cert**, so those installs are never quarantined and their TCC permissions survive `brew upgrade`. See [Self-signed signing for local dev and Homebrew](#self-signed-signing-for-local-dev-and-homebrew).

> **Why a stable signing identity (both paths).** macOS TCC (the Privacy database behind **Screen Recording**, etc.) pins each granted permission to the app's signing identity. Ad-hoc signing (`codesign --sign -`) produces a *different* identity on every build, so after each update the new binary no longer matches the stored grant — Screen Recording silently stops working, forcing a confusing toggle-off/on + restart. The notarized DMG anchors its identity to the **Team ID** (survives even cert renewal); the Homebrew path uses a stable self-signed cert per machine. Either way, permissions persist across updates.

## One-time prerequisites

- Xcode command-line toolchain (`xcode-select --install`)
- [GitHub CLI](https://cli.github.com) (`brew install gh`) authenticated to the `Arc86/dBrief` repo
- `hdiutil`, `codesign`, `security`, `openssl`, `xattr`, `/usr/libexec/PlistBuddy` — all built into macOS
- **Apple Developer Program** membership with a **Developer ID Application** certificate in your login keychain. dBrief's is `Developer ID Application: Jesper Mol (9WFDLY652Y)` (Team ID `9WFDLY652Y`).
- **notarytool credentials** stored once under the profile name `dbrief` (see [Notarization setup](#notarization-setup)).
- **Sparkle EdDSA private key** at `~/dbrief-sparkle-private-key.txt` (also backed up in your vault — see [Sparkle in-app updates](#sparkle-in-app-updates)).

## 1. Bump the version

The version lives in exactly one place: [`Sources/dBrief/Resources/Info.plist`](Sources/dBrief/Resources/Info.plist) — set **both** `CFBundleShortVersionString` and `CFBundleVersion` to the new number (e.g. `1.3.2`). Everything else (the bundle, the About screen, the updater, the DMG name) reads from there.

The git tag must be the same number prefixed with `v` (e.g. `v1.3.2`); the updater strips the leading `v`.

## 2. Smoke-test locally

A plain `make app` build is self-signed (fast, no notarization) — good enough for clicking through before you cut the real release:

```bash
make app
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dBrief.app/Contents/Info.plist   # expect the new version
make run                                                                                          # launch and click through About / Settings → Updates
```

> **Don't ship this bundle.** A self-signed `dBrief.app` cannot be notarized — `codesign --verify` passes on it, but notarization returns *Invalid* ("not signed with a valid Developer ID certificate / no secure timestamp / hardened runtime not enabled"). Always produce the release bundle with `make notarize`, which builds → Developer-ID-signs → submits atomically. (If you must re-submit an existing bundle, re-sign it first with `make sign CODESIGN_IDENTITY="Developer ID Application: Jesper Mol (9WFDLY652Y)"` and confirm `codesign -dvvv dBrief.app/Contents/MacOS/dBrief` shows `flags=0x10000(runtime)`, the Developer ID `Authority`, and a `Timestamp=` line.)

## 3. Cut a notarized release

First, curate the highlights for this version in [`RELEASE_NOTES.md`](RELEASE_NOTES.md) (headline user-facing changes — auto-generated commit lists read poorly on their own) and commit. Then build, sign, and notarize in one atomic step:

```bash
make notarize \
  CODESIGN_IDENTITY="Developer ID Application: Jesper Mol (9WFDLY652Y)" \
  NOTARY_PROFILE=dbrief
```

This hardened-signs the app (with the entitlements in [`packaging/dBrief.entitlements`](packaging/dBrief.entitlements)), notarizes & staples it, packages the DMG, then notarizes & staples the DMG (`xcrun notarytool … --wait` blocks until Apple finishes — usually a few minutes after the first submission on a given account). The result is a Gatekeeper-clean `dBrief-<version>.dmg`.

Verify the bundle came out hardened + notarized:

```bash
spctl -a -vv -t install dBrief.app                 # expect: source=Notarized Developer ID
codesign -dvvv dBrief.app/Contents/MacOS/dBrief 2>&1 | grep -E 'flags|Authority|Timestamp'
#   expect flags=0x10000(runtime), the Developer ID Authority, and a Timestamp= line
```

## 4. Generate the Sparkle appcast

`make notarize` produced the stapled `dBrief-<version>.dmg`. Sign it into an appcast (see [Sparkle setup](#sparkle-in-app-updates) for the one-time key install):

```bash
mkdir -p /tmp/dbrief-appcast
cp dBrief-<version>.dmg /tmp/dbrief-appcast/
/tmp/sparkle-tools/bin/generate_appcast \
  --ed-key-file ~/dbrief-sparkle-private-key.txt \
  --download-url-prefix "https://github.com/Arc86/dBrief/releases/download/v<version>/" \
  --full-release-notes-link "https://github.com/Arc86/dBrief/releases" \
  /tmp/dbrief-appcast
# → writes /tmp/dbrief-appcast/appcast.xml, EdDSA-signed with your private key
```

## 5. Tag and publish the GitHub release

```bash
git push origin main
git tag v<version>
git push origin v<version>
gh release create v<version> dBrief-<version>.dmg /tmp/dbrief-appcast/appcast.xml \
  --title "dBrief <version>" \
  --notes-file RELEASE_NOTES.md
```

Upload **both** the DMG and the `appcast.xml`. Because `SUFeedURL` points at `releases/latest/download/appcast.xml`, the feed always resolves to the newest release. Add `--draft` if you want to review before it goes live. Once published, existing installs detect it on their next check (auto, once/day) or via **Settings → General → Software update → Check Now**.

## 6. Update the Homebrew tap

The build-from-source formula lives at [`packaging/homebrew/dbrief.rb`](packaging/homebrew/dbrief.rb). Publishing it requires a **separate tap repo** named `Arc86/homebrew-dbrief` (Homebrew's naming convention) with the formula at `Formula/dbrief.rb`.

First time only — create the tap:

```bash
gh repo create Arc86/homebrew-dbrief --public
git clone https://github.com/Arc86/homebrew-dbrief.git
mkdir -p homebrew-dbrief/Formula
cp packaging/homebrew/dbrief.rb homebrew-dbrief/Formula/dbrief.rb
```

Each release — update the `url` and `sha256` for the new tag in **both** the tap's `Formula/dbrief.rb` and the in-repo `packaging/homebrew/dbrief.rb`:

```bash
curl -L -o /tmp/dbrief.tar.gz https://github.com/Arc86/dBrief/archive/refs/tags/v<version>.tar.gz
shasum -a 256 /tmp/dbrief.tar.gz
# edit the actual `url "..."` line and paste the new sha256
cd homebrew-dbrief && git commit -am "dbrief <version>" && git push
```

> **Gotcha:** the formula's comment block contains an *example* archive URL, so a blind `count=1` URL replace can hit the comment instead of the real `url "..."` line — leaving the old URL with the new sha256 (brew then fails the checksum). Edit the real `url` line explicitly.

Verify end to end:

```bash
brew install Arc86/dbrief/dbrief
ln -sf "$(brew --prefix)/opt/dbrief/dBrief.app" /Applications/dBrief.app
```

Because Homebrew compiles on the user's machine, the app is never quarantined and launches without a Gatekeeper prompt.

## Notarization setup

One-time, on the Mac you release from:

1. Enroll in the Apple Developer Program ($99/yr), then create a **Developer ID Application** certificate (Xcode → Settings → Accounts → Manage Certificates, or the Developer portal). It lands in your login keychain.
2. Make an [app-specific password](https://support.apple.com/102654) for your Apple ID, then store notarytool credentials under the profile name `dbrief`:
   ```bash
   xcrun notarytool store-credentials dbrief \
     --apple-id you@example.com --team-id 9WFDLY652Y --password APP-SPECIFIC-PASSWORD
   ```

Notes:

- **Hardened-runtime entitlements matter even though dBrief is not sandboxed.** The hardened runtime gates some privacy resources behind explicit entitlements. Microphone (`com.apple.security.device.audio-input`), Calendar (`com.apple.security.personal-information.calendars`), and Reminders (`com.apple.security.personal-information.reminders`) all need their entitlement in [`packaging/dBrief.entitlements`](packaging/dBrief.entitlements) — without it the System Settings toggle silently won't take, even with the Info.plist usage string present (this is what broke mic + calendar in the first 1.3.1 notarized build and was fixed in 1.3.2). Screen Recording and Speech Recognition are TCC-only and need no entitlement. The same file also carries the `cs.allow-jit` / `cs.allow-unsigned-executable-memory` / `cs.disable-library-validation` keys the MLX/WhisperKit ML stack requires. If a notarization run is rejected, read the log with `xcrun notarytool log <submission-id> --keychain-profile dbrief` and add any flagged capability there.
- **Signing order is inside-out.** The Makefile `sign` target's Developer ID branch codesigns the bundled `.metallib` files **before** the main executable `Contents/MacOS/dBrief`; signing the main executable first triggers a bundle seal that rejects the still-unsigned nested metallibs (`code object is not signed at all / In subcomponent: …/mlx.metallib`). Keep that order if you touch the bundle layout.
- `make notarize` does **not** notarize the Homebrew-from-source path (those users build self-signed locally) — it only produces the DMG you upload.
- After switching an existing install from a self-signed to a Developer ID identity, users re-grant Screen Recording once, then it's stable (TCC re-pins to the new, Team-anchored identity). `tccutil reset All com.dbrief.app` clears stale grants when debugging this.

## Self-signed signing for local dev and Homebrew

A plain `make app` (default `CODESIGN_IDENTITY=auto`) signs with a stable self-signed identity named **`dBrief Self-Signed`**, created automatically by [`scripts/ensure-signing-cert.sh`](scripts/ensure-signing-cert.sh) on the first build. The cert lives in a dedicated keychain, `~/Library/Keychains/dbrief-signing.keychain-db` (separate from your login keychain, with its own password so signing stays non-interactive). This path covers **local dev builds** and **Homebrew-from-source** installs — *not* the notarized DMG, which uses the Developer ID identity above.

> The very first build *may* show one macOS prompt — "codesign wants to sign using key … in your keychain." Click **Always Allow** once; it won't ask again.

For **Homebrew-from-source** users this is automatic: the formula runs `make app`, which creates a stable per-machine cert on first install and reuses it on every `brew upgrade`, so their Screen Recording grant survives rebuilds. If you build a *self-signed* release on a different Mac, back up and restore the keychain so downloaders don't re-grant:

```bash
# Back up (keep this file safe / in your password manager vault)
cp ~/Library/Keychains/dbrief-signing.keychain-db ~/dbrief-signing.keychain-db.bak

# Restore on another Mac, then `make app` picks it up automatically
cp ~/dbrief-signing.keychain-db.bak ~/Library/Keychains/dbrief-signing.keychain-db
```

Escape hatches via `make app CODESIGN_IDENTITY=…`:

- `CODESIGN_IDENTITY=-` — pure ad-hoc (permissions reset every release; for throwaway builds only).
- `CODESIGN_IDENTITY="Developer ID Application: Jesper Mol (9WFDLY652Y)"` — Developer ID signing (what `make notarize` uses).

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
2. `generate_keys` once (already done — `SUPublicEDKey` is set in Info.plist and the private key lives at `~/dbrief-sparkle-private-key.txt`). If you ever regenerate, **back up the private key** to your vault:
   ```bash
   /tmp/sparkle-tools/bin/generate_keys -x ~/dbrief-sparkle-private-key.txt   # then move into your vault
   ```
   This is a second irreplaceable secret alongside the signing identity — losing it strands all existing installs.

The per-release appcast generation is [step 4](#4-generate-the-sparkle-appcast) above. The feed is latest-only (one `<item>`) — sufficient for Sparkle's "is there something newer?" check.

### Manual smoke test (do this once after wiring Sparkle, and when bumping Sparkle)

1. Build + notarize version N, install it to /Applications, and launch it.
2. Build + notarize version N+1, generate its appcast, and publish it to a test
   release (or point `SUFeedURL` at a scratch feed).
3. In the running N, **Settings → General → Software update → Check Now**.
   Confirm Sparkle shows the update, downloads it, verifies the EdDSA signature,
   installs, and relaunches into N+1 with no Gatekeeper prompt.

## Installing the DMG (what end users do)

The notarized `.dmg` is **not** quarantined: drag `dBrief.app` to `/Applications` and launch it — no `xattr` step, no Gatekeeper prompt. See [README](README.md#install) and the [docs install page](site/docs/getting-started/installation.md) for the user-facing version.

> Pre-1.3.1 (un-notarized) builds required clearing quarantine once with `xattr -dr com.apple.quarantine /Applications/dBrief.app` or **System Settings → Privacy & Security → Open Anyway**. That's no longer needed for notarized releases.
