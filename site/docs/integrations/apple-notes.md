# Apple Notes

Create a note in Apple Notes for each recording.

## Setup

1. Go to **Settings → Integrations** and click **Apple Notes**
2. Turn on **Send to Apple Notes**
3. Choose which fields to include in the **Send fields** card
4. Optionally click **Test connection** to check that dBrief can reach Apple Notes

No API key or account setup is needed — dBrief asks Notes to create the note in whichever Apple Notes account is active on your Mac.

## Allow dBrief to control Notes

The first time dBrief sends a note (or you click **Test connection**), macOS asks whether dBrief may control Notes. Click **Allow**. You're only asked once.

If you clicked **Don't Allow**, notes can't be created. To fix it, open **System Settings → Privacy & Security → Automation**, find dBrief and turn on **Notes**.

## What the note looks like

Notes look like notes, not Markdown: headings, bold text and lists come through as formatting.

- The note's title is the meeting title, followed by the date, time and duration.
- Sections follow in this order: **Summary**, **Meeting info**, **Action items**, **Tags**, **Sentiment**, then the full Markdown export (if selected) and the **Transcript** last, so the long part doesn't push your notes out of view.
- Placeholder action items such as "No action items identified" are left out.

## What gets sent

Choose from: transcript, summary, action items, tags, sentiment, the full Markdown export, and meeting info from your calendar.

## Where notes appear

Notes are created in the default Apple Notes account and folder. To use a specific folder, fill in both **Account name** and **Folder name**. You can move notes within Apple Notes after they're created.
