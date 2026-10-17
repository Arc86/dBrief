# Calendar Integration

dBrief can match a recording to the meeting on your calendar and use it to pre-fill details — so you don't have to type the title or participant names yourself.

## What you get

When a recording **stops**, dBrief finds the calendar event that best fits the recording and uses it to pre-fill:

- **Title** — the meeting name, used in the filename and Markdown header
- **Participants** — attendee names (used to label speakers when [diarization](../transcription/local-whisper.md) is on)
- **Agenda context** — the event notes, used to give the AI more context for the summary

The match is chosen by how closely an event's time window fits the recording's actual span, with a preference for meetings that have invitees and a strong penalty for all-day blocks — so a day-long "Focus time" block never wins over the real 30-minute meeting it overlaps.

In **Settings → Meetings → Meeting matching**, use **Match window** to decide how close a non-overlapping event's start time must be to the recording start. Choose **Only overlapping** for strict matching, or a window from 5 to 60 minutes. The default is 15 minutes.

## Picking a different meeting

If one or more events are nearby, the panel you see after you stop recording shows a meeting picker under **Meeting details**, listing the candidates (best match first) with a **None** option. Choosing one fills the title, participants, and AI context from that event; choosing **None** clears the calendar context without wiping anything you've typed. You can always edit any field there before processing.

Turn on **Show all meetings from that day** (in **Settings → Meetings → Meeting matching**) to add the day's other events to this picker. Suggested matches remain at the top, followed by the remaining timed events in chronological order and all-day events last. Events outside the automatic match window are available for manual selection but are never linked automatically.

## Calendar sources

Configure this in **Settings → Meetings → Calendar** with the **Source** picker:

| Source | Description |
|---|---|
| **Off** | No calendar lookup |
| **Calendar app** | Your macOS Calendar (Apple Calendar), via the Calendar permission |
| **Outlook** | Microsoft 365 calendar — only appears when the app is built with a Microsoft client ID |
| **Claude CLI** | Your Microsoft 365 calendar through the Claude command-line tool — see [Claude CLI Calendar](../integrations/claude-cli-calendar.md) |

### Calendar app

Pick **Calendar app** and grant **Calendar** access when prompted (or from **Settings → Permissions**). dBrief reads your local macOS Calendar events — nothing is sent anywhere.

Use the **Calendars** menu to choose which calendars can provide meeting context. **All calendars** is the default and automatically includes calendars added later. To limit matching, select any combination of calendars; dBrief then considers only events from that allow-list for both automatic matching and the meeting picker you see after recording. Calendars are shown with their account name so identically named work and personal calendars remain distinguishable.

If a selected calendar becomes unavailable, dBrief keeps the filter in place and ignores that calendar rather than silently falling back to all calendars. Choose **All calendars** from the menu to clear the filter.

### Outlook

If available, choose **Outlook** and click **Sign in with Microsoft**. dBrief reads your calendar through the Microsoft Graph API using read-only access, and your sign-in is stored securely in the Keychain. You can sign out at any time.

> **Note:** The Outlook option only shows up in builds configured with a Microsoft Azure client ID. If you don't see **Outlook**, your build doesn't include it; use **Calendar app** or **Claude CLI** instead.
