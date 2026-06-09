# Recording Basics

How to start, pause, resume, and stop a recording.

## Starting a recording

Click the dBrief icon in the menu bar, then click **Record**.

Or press **⌃⌥⌘R** from anywhere on your Mac — you don't need to open dBrief first. (You can change this shortcut in **Settings → General → Shortcuts**.)

## Pausing and resuming

Click **Pause** to pause the recording. The timer stops and audio capture halts. Click **Resume** to continue from where you left off.

> **Note:** Pausing does not split the recording. When you stop, you get one file covering the whole session.

## Stopping a recording

Click **Stop** (or press **⌃⌥⌘R**). A sheet appears where you can:

- Edit the recording title (pre-filled from your calendar if a matching event is found)
- Choose what to process (transcribe, summarise, generate action items, tags)
- Enter participant names (used to label speakers when diarization is on)
- Select a meeting profile (with Power User Mode)

Click **Done** to start processing, or **Discard** to delete the recording.

## Naming your recording

When you stop, you can give the recording a title. This becomes part of the filename:

```
2026-04-06_1430_team-standup.m4a
```

Titles are sanitised automatically — special characters and spaces are replaced.

## What happens after you stop

1. The audio is transcoded and saved to your output folder
2. If the recording is longer than 30 minutes, it's split into 30-minute chunks automatically
3. Transcription runs (if enabled)
4. AI analysis runs (if enabled)
5. Results are saved as a Markdown file and sent to any integrations you've configured

## Settings

Audio settings (input device, echo cancellation) are in **Settings → Recording**. Output folders, the record shortcut, call detection, and calendar are in **Settings → General**. Transcription and AI engines are in **Settings → AI & Models**.
