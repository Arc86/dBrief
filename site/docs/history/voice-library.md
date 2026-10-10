# Voice Library

The Voice Library lets dBrief recognize the people you record **by name, across recordings** — not just tell speakers apart within a single one. Once you've named someone, dBrief remembers their voice and labels them automatically the next time they show up.

It's fully on-device and private: each person is stored as a mathematical "voiceprint" in a single local library file on your Mac. Voiceprints are never uploaded, never attached to a recording, and aren't touched by auto-delete.

## Requirements

The Voice Library only works when **speaker detection (diarization)** is on — turn on **Settings → Speakers → Identify speakers**. It isn't available with Apple Speech. Speakers are detected on-device after transcription, and a voiceprint is extracted for each one.

## How recognition works

1. You record and transcribe a meeting with diarization on.
2. dBrief detects the distinct speakers and extracts a voiceprint for each.
3. Each voiceprint is compared against the people already in your library.
4. A speaker is auto-labelled **only** when there's a confident match *and* that person is plausibly in the meeting — judged from the participants you entered or the attendees on the matching calendar event.
5. When dBrief isn't sure, it leaves a neutral "Speaker 1" rather than guess. You can name them yourself, and that name is what teaches the library.

This conservative behaviour is deliberate: a neutral, unnamed speaker is better than a confidently wrong name.

## Teaching the library

You don't enrol voices manually — naming a speaker is what does it. Whenever you give a speaker a real name (in the post-recording sheet, in the **Who's speaking?** review, or by [renaming a speaker](transcript-viewer.md#renaming-speakers) in the transcript viewer), dBrief saves that voiceprint under that person. The more times you confirm someone, the more reliably they're recognized — and dBrief keeps a varied set of samples per person rather than many near-duplicates.

## Managing it — Settings → Speakers

The **Known people** card on the **Speakers** settings page lists everyone dBrief knows, with their company, how many voiceprints each holds, and when that person was first and last heard. Search by name or company, sort by any column, or turn on **Group by company**. Select a person to see their voiceprints and recognition strength. From here you can:

- **Rename…** a person. If the new name already belongs to someone in the library, dBrief offers to **Merge** the two into one person (keeping all their samples).
- **Merge into…** another person you know is the same — handy if the same person was learned under two spellings. Select several people to merge them at once; dBrief tells you when their voices are probably the same person.
- **Forget voice** to remove a person entirely, with all their voiceprints.
- **Forget a single voiceprint** from a person's details — useful if one bad sample is causing mistaken matches.

Right-click a person for **Rename…**, **Merge into…**, and **Forget voice**.

## Privacy

- The library is a single `library.json` file under your Mac's Application Support folder, outside your recordings and transcripts.
- It's never uploaded and isn't included in any export or integration.
- Auto-delete (**Settings → Storage → Auto-delete**, see [File Locations](../reference/file-locations.md)) never removes it — forgetting people is always a deliberate action you take on the **Speakers** settings page.

## Related

- [Transcript Viewer → Renaming speakers](transcript-viewer.md#renaming-speakers) — name and reassign speakers, which is how the library learns.
- [Confirm-first speaker review](transcript-viewer.md#confirming-speakers-before-analysis) — check who's who before the AI runs.
