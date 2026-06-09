# Installation

How to install dBrief and grant the permissions it needs to work.

> **Requires:** macOS 14 or later, Apple Silicon.

dBrief is distributed outside the Apple Developer Program, so it is unsigned and un-notarized. That changes only how you open it the first time — pick whichever install path you prefer.

## Install with Homebrew (recommended)

Homebrew builds dBrief from source on your Mac, so the app is never quarantined and macOS opens it normally — no Gatekeeper step.

```bash
brew install Arc86/dbrief/dbrief
ln -sf "$(brew --prefix)/opt/dbrief/dBrief.app" /Applications/dBrief.app
```

Requires the Xcode command-line tools (`xcode-select --install`).

## Download the .dmg

Download the latest `.dmg` from the dBrief releases page, open it, and drag `dBrief.app` into `/Applications`.

Because the download is un-notarized, macOS blocks it on first launch. Clear it **once**, either way:

- Open **System Settings → Privacy & Security**, scroll to the security note about dBrief, and click **Open Anyway**, **or**
- Run this in **Terminal** (most reliable — the `-r` flag also clears the bundled `dBriefMLHost` helper):
  ```bash
  xattr -dr com.apple.quarantine /Applications/dBrief.app
  ```

After that, dBrief launches normally and its icon appears in your menu bar.

## Build from source

```bash
git clone https://github.com/Arc86/dBrief.git
cd dBrief
make run
```

Locally built apps aren't quarantined, so there's no Gatekeeper step.

## Updating dBrief

dBrief checks GitHub for new versions so you don't have to watch the releases page.

- **Automatic checks** — by default, dBrief checks once when it launches (at most once a day). It stays quiet unless a newer version exists. You can turn this off in **Settings → General → Updates**.
- **Check manually** — open **Settings → General → Updates** and click **Check Now**. The last-checked time is shown there.
- **When an update is available** — an orange ⬇︎ badge appears in the menu bar header, and the Updates section shows the new version number. Click the badge (or **View Release**) to open the release page in your browser.

dBrief does not install updates for you. Download the new `.dmg` from the release page and replace the copy in `/Applications` — you'll clear quarantine again the same way as in [Download the .dmg](#download-the-dmg). (On Homebrew, `brew upgrade dbrief` rebuilds the new version with no Gatekeeper step.) Your recordings and settings are stored separately and are kept across updates.

## Permissions

dBrief will ask for permissions as you use it. You can also review and grant them in **Settings → General → Permissions**.

| Permission | When it's needed |
|---|---|
| **Microphone** | Required for all recording |
| **Screen Recording** | Required for mixed audio (system sound + mic) |
| **Speech Recognition** | Required if you use the Apple Speech transcription engine |
| **Calendar** | Optional — lets dBrief pre-fill the meeting title and participants from your calendar |
| **Reminders** | Required if you use the Apple Reminders integration |

**Settings → General → Permissions** shows the live status of Microphone, Screen Recording, and Calendar, with buttons to request or open the relevant System Settings pane.

If you accidentally denied a permission, open **System Settings → Privacy & Security**, find the relevant section, and enable dBrief there.

## Uninstalling

Drag `dBrief.app` from `/Applications` to the Trash. Recordings and settings are stored separately — see [File Locations](../reference/file-locations.md) if you want to remove those too.
