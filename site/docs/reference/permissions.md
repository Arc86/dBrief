# Permissions

dBrief needs certain macOS permissions to work. Here's what each one is for and how to grant it if you declined it at first launch.

## Microphone

**Required for:** All recording.

If microphone access is denied, dBrief cannot record anything.

**To grant:** Open **System Settings → Privacy & Security → Microphone** and enable dBrief.

## Screen Recording

**Required for:** Mixed audio mode (capturing system sound alongside your mic).

Without this permission, dBrief can still record your microphone. It falls back to mic-only mode automatically.

**To grant:** Open **System Settings → Privacy & Security → Screen Recording** and enable dBrief. You may need to restart dBrief after granting this.

## Speech Recognition

**Required for:** The Apple Speech transcription engine and the live transcript preview.

Without this permission, Apple Speech is unavailable. Local Whisper and remote endpoints don't need it.

**To grant:** Open **System Settings → Privacy & Security → Speech Recognition** and enable dBrief, or use the **Request** button in **Settings → Permissions**.

## Calendar

**Required for:** Calendar integration — pre-filling the meeting title and participants from the calendar event that matches your recording.

Without this permission, dBrief still records normally; it just can't pull in calendar details. See [Calendar Integration](../recording/calendar.md).

**To grant:** Open **System Settings → Privacy & Security → Calendars** and enable dBrief, or use the **Request** button in **Settings → Permissions**.

## Reminders

**Required for:** The Apple Reminders integration.

**To grant:** Use the **Request** button in **Settings → Permissions**, or click **Test connection** on the Apple Reminders integration page. If you denied it earlier, open **System Settings → Privacy & Security → Reminders** and enable dBrief. The integration tells you when it needs access.

## Automation (Notes)

**Required for:** The [Apple Notes](../integrations/apple-notes.md) integration.

The first time dBrief creates a note, macOS asks whether dBrief may control Notes. Click **Allow**; you're asked only once.

**To grant later:** Open **System Settings → Privacy & Security → Automation**, find dBrief, and turn on **Notes**.

---

> **Tip:** **Settings → Permissions** shows the live status of Microphone, Screen recording, Speech recognition, Calendar, and Reminders, each with a button to request access or open the right System Settings pane. A badge on **Permissions** in the Settings sidebar shows when something needs attention.
