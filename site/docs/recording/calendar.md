# Calendar Integration

dBrief can look up the meeting on your calendar when a recording starts and use it to pre-fill details — so you don't have to type the title or participant names yourself.

## What you get

When a recording starts, dBrief finds the calendar event happening around that time and uses it to pre-fill:

- **Title** — the meeting name, used in the filename and Markdown header
- **Participants** — attendee names (used to label speakers when [diarization](../transcription/local-whisper.md) is on)
- **Agenda context** — the event notes, used to give the AI more context for the summary

You can always edit these in the post-recording sheet before processing.

## Calendar sources

Configure this in **Settings → General → Calendar** with the **Source** picker:

| Source | Description |
|---|---|
| **Off** | No calendar lookup |
| **iCal** | Your macOS Calendar (Apple Calendar), via the Calendar permission |
| **Outlook (Microsoft)** | Microsoft 365 calendar — only appears when the app is built with a Microsoft client ID |

### iCal

Pick **iCal** and grant **Calendar** access when prompted (or from **Settings → General → Permissions**). dBrief reads your local macOS Calendar events — nothing is sent anywhere.

### Outlook

If available, choose **Outlook (Microsoft)** and click **Sign in with Microsoft**. dBrief reads your calendar through the Microsoft Graph API using read-only access, and your sign-in is stored securely in the Keychain. You can sign out at any time.

> **Note:** The Outlook option only shows up in builds configured with a Microsoft Azure client ID. If you only see **Off** and **iCal**, your build uses iCal only.
