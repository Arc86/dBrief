# Import & Watched Folders

Watched Folders turn dBrief into a drop-in transcription queue. Point it at one or more folders, and any audio file you drop in is automatically transcribed, analyzed, and exported — no recording required.

It's perfect for batch-processing existing audio: voice memos, podcast episodes, call exports, or anything your other tools save to disk.

## Turning it on

Open **Settings → Import** and turn on **Watch folders for new audio**, then click **Add folder…** and pick a folder to watch. You can add several, and toggle each one on or off without removing it.

## How it works

- When you **add** a folder, the files already in it are left alone — only files dropped in *afterwards* are processed. (This keeps dBrief from transcribing an entire existing library the moment you point it at one.)
- A new file is picked up once it has finished copying in. dBrief waits until the file stops changing before it starts, so a large file still being written won't be grabbed half-finished.
- Your original file stays exactly where it is. dBrief imports a copy into your recordings, so the result shows up in History like any other recording, with transcripts and exports landing in your normal output folders.
- Processing happens one file at a time and politely waits while you're recording or while another transcription is running.

New files use your default tasks from **Settings → After recording**, with the engines from **Settings → Transcription** and **Settings → AI analysis** (transcription engine, AI analysis, output language, integrations, and so on).

## Notifications

With **Notify when a file is detected** turned on, dBrief posts a notification as it picks up each file. You'll also get the usual completion notification when processing finishes.

## Supported formats

Watched folders pick up common audio files: `m4a`, `mp3`, `wav`, `flac`, `aac`, `ogg`, `opus`, `m4b`, `aiff`, `caf`, and `wma`. Subfolders are not scanned — only files placed directly in a watched folder.

## Importing a single file

To transcribe one file without watching a folder, open the dBrief menu bar panel and choose **Import… → Audio file…**, or drop an audio file on the menu bar icon.
