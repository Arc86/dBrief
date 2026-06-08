# Installation

How to install dBrief and grant the permissions it needs to work.

> **Requires:** macOS 14 or later.

## Download

Download the latest release from the dBrief releases page and move `dBrief.app` to your `/Applications` folder.

## First launch

Double-click dBrief in Applications. Because dBrief is not yet distributed through the Mac App Store, macOS may show a security warning. To open it:

1. Open **System Settings → Privacy & Security**
2. Scroll down to the security section and click **Open Anyway**

The dBrief icon appears in your menu bar.

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
