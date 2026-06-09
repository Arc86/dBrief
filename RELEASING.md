# Releasing dBrief

dBrief ships as an **Apple Silicon**, **unsigned / un-notarized** macOS app (we are not in the Apple Developer Program). Releases are built locally and uploaded to GitHub by hand. The in-app updater ([`UpdateService`](Sources/dBrief/Services/UpdateService.swift)) polls the GitHub Releases API, so publishing a release is what makes the update prompt appear for existing users.

## One-time prerequisites

- Xcode command-line toolchain (`xcode-select --install`)
- [GitHub CLI](https://cli.github.com) (`brew install gh`) authenticated to the `Arc86/dBrief` repo
- `hdiutil`, `codesign`, `xattr`, `/usr/libexec/PlistBuddy` — all built into macOS

## 1. Bump the version

The version lives in exactly one place: [`Sources/dBrief/Resources/Info.plist`](Sources/dBrief/Resources/Info.plist) — set **both** `CFBundleShortVersionString` and `CFBundleVersion` to the new number (e.g. `1.0.0`). Everything else (the bundle, the About screen, the updater, the DMG name) reads from there.

The git tag must be the same number prefixed with `v` (e.g. `v1.0.0`); the updater strips the leading `v`.

## 2. Build & smoke-test locally

```bash
make app
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dBrief.app/Contents/Info.plist   # expect the new version
codesign --verify --deep --strict --verbose=2 dBrief.app                                         # ad-hoc signature OK
make run                                                                                          # launch and click through About / Settings → Updates
```

## 3. Build the DMG

```bash
make dmg        # produces dBrief-<version>.dmg (e.g. dBrief-1.0.0.dmg)
```

## 4. Tag and publish the GitHub release

```bash
git push origin main
git tag v1.0.0
git push origin v1.0.0
gh release create v1.0.0 dBrief-1.0.0.dmg \
  --title "dBrief 1.0.0" \
  --generate-notes
```

Add `--draft` if you want to review the notes before it goes live. Once published, existing installs detect it on their next check (auto, once/day) or via **Settings → General → Updates → Check Now**.

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

## Installing the DMG (what end users do)

A downloaded `.dmg` is quarantined. After dragging `dBrief.app` to `/Applications`, clear it once:

```bash
xattr -dr com.apple.quarantine /Applications/dBrief.app
```

…or use **System Settings → Privacy & Security → Open Anyway**. See [README](README.md#install) and the [docs install page](site/docs/getting-started/installation.md) for the user-facing version.
