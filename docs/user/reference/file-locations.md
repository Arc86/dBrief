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
