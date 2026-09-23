# Claude CLI Calendar

Fetch Microsoft 365 meetings through your own [Claude CLI](https://docs.claude.com/en/docs/claude-code) install, cache them locally, and use them to pre-fill meeting titles and participants — without sending your calendar anywhere new and without downloading anything after each recording.

Unlike the direct Outlook integration, this source needs **no Azure app registration**: it rides on the Microsoft 365 connector of your logged-in Claude CLI (a Claude subscription).

## Setup

1. Install the Claude CLI and sign in (`claude` once in a Terminal). Your account needs the **Microsoft 365 connector** connected and authorized.
2. In dBrief, go to **Settings → Calendar** and pick **Claude CLI** as the source.
3. Enter your **mailbox email** — it is passed to the connector explicitly, so a connector login change can never silently redirect queries to a different mailbox.
4. Optionally enter a **calendar name** (leave empty for the default calendar).
5. Press **Test connection**. This performs one small bounded read around the current time — it never fetches full meeting resources.

First use may prompt you once in Terminal to approve the calendar tool. dBrief deliberately runs the CLI with an **explicit allowlist**: list refreshes may only use `outlook_calendar_search`, and an attendee load you request may only use `read_resource`. Shell, file, browser, mail and calendar *write* tools are denied.

## How fresh is the data?

| Concern | Behavior |
|---|---|
| Day list | Cached per local calendar day; refreshed when a recording starts or the meeting picker opens if absent or older than the freshness setting (default 60 minutes). No background polling. |
| Attendees | Never fetched automatically. Only when you press **Load attendees** for a specific meeting, and only if the cached roster is older than the attendee freshness window. |
| Manual refresh | The post-recording picker **Refresh** button forces that recording day's list; Settings **Refresh** forces today's list. Both work inside the freshness interval. |
| True delta sync | Not available — the connector exposes no change cursor. A 60-minute-old snapshot can miss last-minute changes until you force a refresh. |

## Current-day snapshot semantics

A recording matches against a **snapshot of the recording day** taken at refresh time. An event you accept, move or cancel in Outlook after the last refresh appears only after the next refresh. Overnight recordings load every local calendar day they touch, and a recording near midnight also considers the neighbouring day's edge.

Choose **List refresh** from 5 minutes through 24 hours, enter a custom interval from 5–1,440 minutes, or select **Manual only**. Longer intervals reduce Claude calls but leave the list stale longer. Manual only makes no automatic list calls, including on an empty cache; press **Refresh** in the picker to load the latest meetings. The picker shows its last successful update. If a refresh fails, it keeps saved meetings visible and offers Retry via **Refresh**. A selected meeting that disappears from a new list stays selected for review rather than being silently replaced.

## Attendees, on your terms

Attendee loading is **on demand** or **never**:

- Matching, selecting, starting/stopping a recording never fetch attendees.
- **Load attendees** (post-recording sheet) fetches one meeting's roster, within your attendee limit (1–100, default 20).
- Meetings whose verified count already exceeds your limit omit the **entire** roster — you'll see "Attendees omitted" rather than a truncated list. A small-looking title proves nothing; unknown counts are treated as unknown.

**Privacy boundary to know about:** the connector's resource read shows Claude the full invite (body included) before dBrief extracts only names and emails. dBrief never stores, displays, or analyzes the body — but if you don't want that upstream retrieval at all, leave attendees unloaded or set **Attendees: Never**. The field list of the connector's own responses cannot be reduced from dBrief's side.

## Model and timeout

Calendar calls are independent of AI analysis settings:

- **Model**: Claude default (recommended), Haiku, Sonnet, or a custom model ID.
- **Timeout**: 30–300 seconds per CLI invocation (default 90) — one call covers all connector pages plus structured output.
- **Advanced command**: leave empty to use the managed command; custom commands must not redeclare output/tool flags.

## Offline and account switching

- **Offline / CLI unavailable**: cached day lists remain readable, marked by their last successful refresh. Nothing is lost; refreshes fail softly.
- **Switching Claude accounts**: the connector login isn't observable offline. Clear the cache and re-run **Test connection** after switching accounts so stale data from the old mailbox can't be presented.
- **Clear cache** removes cached day lists and rosters. Metadata already attached to saved recordings is untouched.

## Privacy receipt

Calendar fetches are recorded in the privacy trace as a `Calendar fetch` stage with an externally-managed destination (the Claude CLI connector).
