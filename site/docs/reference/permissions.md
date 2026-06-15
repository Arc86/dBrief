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

**Required for:** The Apple Speech transcription engine.

Without this permission, Apple Speech is unavailable. Local Whisper and remote endpoints don't need it.

**To grant:** Open **System Settings → Privacy & Security → Speech Recognition** and enable dBrief.

## Calendar

**Required for:** Calendar integration — pre-filling the meeting title and participants from the calendar event that matches your recording.

Without this permission, dBrief still records normally; it just can't pull in calendar details. See [Calendar Integration](../recording/calendar.md).

**To grant:** Open **System Settings → Privacy & Security → Calendars** and enable dBrief, or use the **Request** button in **Settings → Permissions**.

## Reminders

**Required for:** The Apple Reminders integration.

**To grant:** Open **System Settings → Privacy & Security → Reminders** and enable dBrief.

---

> **Tip:** **Settings → Permissions** shows the live status of Microphone, Screen Recording, and Calendar, each with a button to request access or open the right System Settings pane. Speech Recognition and Reminders are requested on demand the first time you use the feature that needs them.
