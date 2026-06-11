# Releasing dBrief

dBrief ships as an **Apple Silicon**, **self-signed / un-notarized** macOS app (we are not in the Apple Developer Program). Releases are built locally and uploaded to GitHub by hand. The in-app updater ([`UpdateService`](Sources/dBrief/Services/UpdateService.swift)) polls the GitHub Releases API, so publishing a release is what makes the update prompt appear for existing users.

> **Why self-signed instead of ad-hoc.** macOS TCC (the Privacy database behind **Screen Recording**, etc.) pins each granted permission to the app's signing identity. Ad-hoc signing (`codesign --sign -`) produces a *different* identity on every build, so after each release the new binary no longer matches the stored grant — Screen Recording silently stops working even though its toggle still looks enabled, forcing a confusing toggle-off/on + restart. Signing every release with the **same self-signed certificate** gives TCC a stable identity to match, so permissions survive updates. `make app` handles this automatically (see [The signing certificate](#the-signing-certificate)). It does **not** affect Gatekeeper — the app is still un-notarized and quarantined on download.

## One-time prerequisites

- Xcode command-line toolchain (`xcode-select --install`)
- [GitHub CLI](https://cli.github.com) (`brew install gh`) authenticated to the `Arc86/dBrief` repo
- `hdiutil`, `codesign`, `security`, `openssl`, `xattr`, `/usr/libexec/PlistBuddy` — all built into macOS

## 1. Bump the version

The version lives in exactly one place: [`Sources/dBrief/Resources/Info.plist`](Sources/dBrief/Resources/Info.plist) — set **both** `CFBundleShortVersionString` and `CFBundleVersion` to the new number (e.g. `1.0.0`). Everything else (the bundle, the About screen, the updater, the DMG name) reads from there.

The git tag must be the same number prefixed with `v` (e.g. `v1.0.0`); the updater strips the leading `v`.

## 2. Build & smoke-test locally

```bash
make app
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dBrief.app/Contents/Info.plist   # expect the new version
codesign --verify --deep --strict --verbose=2 dBrief.app                                         # self-signed signature OK
codesign -dvv dBrief.app 2>&1 | grep Authority                                                   # expect "dBrief Self-Signed" (not "(unsigned)")
make run                                                                                          # launch and click through About / Settings → Updates
```

The first `make app` after adopting this creates the signing certificate (see below); later builds reuse it silently.

## 3. Build the DMG

```bash
make dmg        # produces dBrief-<version>.dmg (e.g. dBrief-1.0.0.dmg)
```

## 4. Tag and publish the GitHub release

First, curate the highlights for this version in [`RELEASE_NOTES.md`](RELEASE_NOTES.md) (headline user-facing changes — auto-generated commit lists read poorly on their own). Then:

```bash
git push origin main
git tag v1.0.0
git push origin v1.0.0
gh release create v1.0.0 dBrief-1.0.0.dmg \
  --title "dBrief 1.0.0" \
  --notes-file RELEASE_NOTES.md
```

`RELEASE_NOTES.md` is the curated body. Swap in `--generate-notes` instead if you'd rather GitHub list every commit/PR title, or pass both files by appending the auto-notes manually. Add `--draft` if you want to review before it goes live. Once published, existing installs detect it on their next check (auto, once/day) or via **Settings → General → Updates → Check Now**.

## 5. Update the Homebrew tap

The build-from-source formula lives at [`packaging/homebrew/dbrief.rb`](packaging/homebrew/dbrief.rb). Publishing it requires a **separate tap repo** named `Arc86/homebrew-dbrief` (Homebrew's naming convention) with the formula at `Formula/dbrief.rb`.

First time only — create the tap:

```bash
gh repo create Arc86/homebrew-dbrief --public
git clone https://github.com/Arc86/homebrew-dbrief.git
mkdir -p homebrew-dbrief/Formula
cp packaging/homebrew/dbrief.rb homebrew-dbrief/Formula/dbrief.rb
```

Each release — update the `url` and `sha256` for the new tag:

```bash
curl -L -o /tmp/dbrief.tar.gz https://github.com/Arc86/dBrief/archive/refs/tags/v1.0.0.tar.gz
shasum -a 256 /tmp/dbrief.tar.gz
# edit Formula/dbrief.rb: bump the version in `url` and paste the new sha256
cd homebrew-dbrief && git commit -am "dbrief 1.0.0" && git push
```

Verify end to end:

```bash
brew install Arc86/dbrief/dbrief
ln -sf "$(brew --prefix)/opt/dbrief/dBrief.app" /Applications/dBrief.app
```

Because Homebrew compiles on the user's machine, the app is never quarantined and launches without a Gatekeeper prompt.

## The signing certificate

`make app` signs with a stable self-signed code-signing identity named **`dBrief Self-Signed`**, created automatically by [`scripts/ensure-signing-cert.sh`](scripts/ensure-signing-cert.sh) on the first build. The cert lives in a dedicated keychain, `~/Library/Keychains/dbrief-signing.keychain-db` (separate from your login keychain, with its own password so signing stays non-interactive). Every later build reuses it — no prompts, nothing to do.

> The very first build *may* show one macOS prompt — "codesign wants to sign using key … in your keychain." Click **Always Allow** once; it won't ask again.

**Reuse the same certificate for every public release.** The cert's public half is embedded in each DMG we ship, and downloaders' Screen Recording grants are pinned to it. As long as every release is signed with this one cert, their permissions persist across updates. If the keychain is deleted or you build the next release on a **different Mac**, a *new* cert is generated and every existing downloader has to re-grant Screen Recording once. So when releasing from a new machine, copy the keychain over first:

```bash
# Back up (keep this file safe / in your password manager vault)
cp ~/Library/Keychains/dbrief-signing.keychain-db ~/dbrief-signing.keychain-db.bak

# Restore on another Mac, then `make app` picks it up automatically
cp ~/dbrief-signing.keychain-db.bak ~/Library/Keychains/dbrief-signing.keychain-db
```

Escape hatches via `make app CODESIGN_IDENTITY=…`:

- `CODESIGN_IDENTITY=-` — old ad-hoc behavior (permissions reset every release).
- `CODESIGN_IDENTITY="Developer ID Application: …"` — if you ever enroll in the Apple Developer Program (also enables notarization).

**Homebrew-from-source** users get the same protection automatically: the formula runs `make app`, which creates a stable per-machine cert on first install and reuses it on every `brew upgrade`, so their permissions survive rebuilds too.

## Installing the DMG (what end users do)

A downloaded `.dmg` is quarantined. After dragging `dBrief.app` to `/Applications`, clear it once:

```bash
xattr -dr com.apple.quarantine /Applications/dBrief.app
```

…or use **System Settings → Privacy & Security → Open Anyway**. See [README](README.md#install) and the [docs install page](site/docs/getting-started/installation.md) for the user-facing version.
