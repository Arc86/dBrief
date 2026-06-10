# File Locations

Where dBrief stores your recordings, exports, models, and settings.

## Recordings

Audio files are saved in dated subfolders inside your output folder (set in **Settings → General → Folders**):

```
~/Documents/Recordings/
└── 2026/
    └── 04/
        └── 2026-04-06_1430_team-standup.m4a
```

Recordings are saved as **M4A / AAC**. You can change the output folder in **Settings → General → Folders**.

## Markdown exports

Markdown files are saved in the same dated subfolder as the audio file, unless you've configured an Obsidian vault folder — in which case they go there instead. A `.richtranscript.json` sidecar (storing speaker names and word timing for the [transcript viewer](../history/transcript-viewer.md)) is written next to the Markdown file.

## AI and transcription models

On-device models are stored in Application Support:

```
~/Library/Application Support/dBrief/LocalAIPlugin/
├── WhisperKit/    ← Local Whisper model (size depends on chosen model)
├── SpeakerKit/    ← Speaker diarization model
├── FluidAudio/    ← Parakeet model (~1.5–1.8 GB)
└── MLX/           ← Gemma 4 E4B model
```

To remove models, use the **Purge** options in **Settings → AI & Models** (Power User Mode for the Gemma model).

## Auto-delete (retention)

dBrief can automatically remove old files so your recordings folder doesn't grow forever. In **Settings → General → Privacy** there are two independent policies:

- **Auto-delete recordings** — removes audio files older than the chosen age; transcripts and notes are kept.
- **Auto-delete transcripts** — removes transcript, insights, and Markdown note files older than the chosen age; audio recordings are kept.

Both are **off by default**. When enabled, you pick an age (1, 7, 14, 30, 60, 90, 180, or 365 days — 30 by default), and each file is judged by its own creation date. Cleanup runs automatically when dBrief launches, and you can trigger it immediately with **Run Cleanup Now**. Deletion is permanent and can't be undone.

## Settings

App preferences are stored in `UserDefaults` under the `com.dbrief.app` domain. You can reset all settings by deleting this domain with `defaults delete com.dbrief.app` in Terminal — but this also resets your output folder path and engine choices.

## API keys and tokens

Integration tokens (Notion, Evernote, etc.) are stored securely in the macOS Keychain under `com.dbrief.app`.

## Uninstalling completely

To remove everything dBrief has written to your Mac:

1. Delete `dBrief.app` from `/Applications`
2. Delete `~/Library/Application Support/dBrief/`
3. Run `defaults delete com.dbrief.app` in Terminal
4. Open Keychain Access and delete any entries for `com.dbrief.app`
5. Optionally delete your recordings folder
