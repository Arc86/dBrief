# Installation

How to install dBrief and grant the permissions it needs to work.

> **Requires:** macOS 14 or later, Apple Silicon.

The `.dmg` is signed with a Developer ID and **notarized by Apple**, so it opens like any other Mac app — no Gatekeeper workaround. Pick whichever install path you prefer.

## Download the .dmg (recommended)

Download the latest `.dmg` from the [dBrief releases page](https://github.com/Arc86/dBrief/releases), open it, and drag `dBrief.app` into `/Applications`.

Because the download is notarized, macOS opens it without a Gatekeeper prompt — dBrief launches straight away and its icon appears in your menu bar. From there, in-app updates keep it current (see [Updating dBrief](#updating-dbrief)).

## Install with Homebrew

Homebrew builds dBrief from source on your Mac, so the app is never quarantined and macOS opens it normally — no Gatekeeper step.

```bash
brew install Arc86/dbrief/dbrief
ln -sf "$(brew --prefix)/opt/dbrief/dBrief.app" /Applications/dBrief.app
```

Requires the Xcode command-line tools (`xcode-select --install`).

## Build from source

```bash
git clone https://github.com/Arc86/dBrief.git
cd dBrief
make run
```

Locally built apps aren't quarantined, so there's no Gatekeeper step.

## Updating dBrief

dBrief updates itself in-app via [Sparkle](https://sparkle-project.org), so you don't have to watch the releases page.

- **Automatic checks** — by default, dBrief checks once when it launches (at most once a day). It stays quiet unless a newer version exists. You can turn this off in **Settings → General → Software update**.
- **Check manually** — open **Settings → General → Software update** and click **Check Now**. The last-checked time is shown there.
- **One-click install** — when a newer version is available, dBrief offers to download and install it for you, verifies the signed download, and relaunches into the new version — no Gatekeeper prompt, no manual re-download.

If you installed via **Homebrew**, update with `brew upgrade dbrief` instead (it rebuilds from source). Your recordings and settings are stored separately and are kept across updates either way.

## Permissions

dBrief will ask for permissions as you use it. You can also review and grant them in **Settings → Permissions**.

| Permission | When it's needed |
|---|---|
| **Microphone** | Required for all recording |
| **Screen Recording** | Required for mixed audio (system sound + mic) |
| **Speech Recognition** | Required if you use the Apple Speech transcription engine |
| **Calendar** | Optional — lets dBrief pre-fill the meeting title and participants from your calendar |
| **Reminders** | Required if you use the Apple Reminders integration |

**Settings → Permissions** shows the live status of Microphone, Screen Recording, and Calendar, with buttons to request or open the relevant System Settings pane.

If you accidentally denied a permission, open **System Settings → Privacy & Security**, find the relevant section, and enable dBrief there.

## Start at login

To have dBrief launch automatically when you log in, turn on **Start at login** in **Settings → General**. It runs quietly in the menu bar (no Dock icon), ready to record.

## Uninstalling

Drag `dBrief.app` from `/Applications` to the Trash. Recordings and settings are stored separately — see [File Locations](../reference/file-locations.md) if you want to remove those too.
