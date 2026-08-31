# Calendar Integration

dBrief can match a recording to the meeting on your calendar and use it to pre-fill details — so you don't have to type the title or participant names yourself.

## What you get

When a recording **stops**, dBrief finds the calendar event that best fits the recording and uses it to pre-fill:

- **Title** — the meeting name, used in the filename and Markdown header
- **Participants** — attendee names (used to label speakers when [diarization](../transcription/local-whisper.md) is on)
- **Agenda context** — the event notes, used to give the AI more context for the summary

The match is chosen by how closely an event's time window fits the recording's actual span, with a preference for meetings that have invitees and a strong penalty for all-day blocks — so a day-long "Focus time" block never wins over the real 30-minute meeting it overlaps.

In **Settings → General → Calendar**, use **Automatic match window** to decide how close a non-overlapping event's start time must be to the recording start. Choose **Only overlapping** for strict matching, or a window from 5 to 60 minutes. The default is 15 minutes.

## Picking a different meeting

If more than one event is nearby, the post-recording sheet shows a **Meeting** picker listing the candidates (best match first) with a **None** option. Choosing one fills the title, participants, and AI context from that event; choosing **None** clears the calendar context without wiping anything you've typed. You can always edit any field in the post-recording sheet before processing.

Enable **Show all meetings from the recording day** to add the day's other events to this picker. Suggested matches remain at the top, followed by the remaining timed events in chronological order and all-day events last. Events outside the automatic match window are available for manual selection but are never linked automatically.

## Calendar sources

Configure this in **Settings → General → Calendar** with the **Source** picker:

| Source | Description |
|---|---|
| **Off** | No calendar lookup |
| **iCal** | Your macOS Calendar (Apple Calendar), via the Calendar permission |
| **Outlook (Microsoft)** | Microsoft 365 calendar — only appears when the app is built with a Microsoft client ID |

### iCal

Pick **iCal** and grant **Calendar** access when prompted (or from **Settings → Permissions**). dBrief reads your local macOS Calendar events — nothing is sent anywhere.

Use the **Calendars** menu to choose which iCal calendars can provide meeting context. **All Calendars** is the default and automatically includes calendars added later. To limit matching, select any combination of calendars; dBrief then considers only events from that allow-list for both automatic matching and the post-recording Meeting picker. Calendars are shown with their account name so identically named work and personal calendars remain distinguishable.

If a selected calendar becomes unavailable, dBrief keeps the filter in place and ignores that calendar rather than silently falling back to all calendars. Choose **All Calendars** from the menu to clear the filter.

### Outlook

If available, choose **Outlook (Microsoft)** and click **Sign in with Microsoft**. dBrief reads your calendar through the Microsoft Graph API using read-only access, and your sign-in is stored securely in the Keychain. You can sign out at any time.

> **Note:** The Outlook option only shows up in builds configured with a Microsoft Azure client ID. If you only see **Off** and **iCal**, your build uses iCal only.
