# File Locations

Where dBrief stores your recordings, exports, models, and settings.

## Recordings

Audio files are saved in dated subfolders inside your recordings folder (set with **Recordings** in **Settings → Storage → Folders**):

```
~/Documents/Recordings/
└── 2026/
    └── 04/
        └── 2026-04-06_1430_team-standup.m4a
```

Recordings are saved as **M4A / AAC**. You can change the folder in **Settings → Storage → Folders**.

## Markdown exports

Markdown files are saved in your **Transcripts** folder (**Settings → Storage → Folders**), unless you've configured an Obsidian vault folder — in which case they go there instead. Small JSON sidecars are written next to the Markdown file: `.richtranscript.json` (speaker names and word timing for the [transcript viewer](../history/transcript-viewer.md)), `.insights.json` (the AI summary, action items, and tags), and `.chat.json` (your [Transcript Chat](../ai-analysis/transcript-chat.md) conversation). They travel with the recording and are removed when it's deleted.

## AI and transcription models

On-device models are stored in Application Support:

```
~/Library/Application Support/com.dbrief.app/LocalAIPlugin/
├── WhisperKit/    ← Local Whisper model (size depends on chosen model)
├── SpeakerKit/    ← Speaker diarization model
└── MLX/           ← Gemma 4 E4B model
```

Parakeet and other FluidAudio models use the shared `~/Library/Application Support/FluidAudio/Models/` cache. Beta builds use `com.dbrief.app.beta` for their own app data and preferences, while the FluidAudio cache is shared.

To remove a model, open the **…** menu on its model card in **Settings → Transcription** or **Settings → AI analysis** and choose **Remove downloaded model**.

## Auto-delete (retention)

dBrief can automatically remove old files so your recordings folder doesn't grow forever. In **Settings → Storage → Auto-delete** there are two independent policies:

- **Delete old recordings** — removes audio files older than the chosen age; transcripts and notes are kept.
- **Delete old transcripts** — removes transcript, insights, and Markdown note files older than the chosen age; audio recordings are kept.

Cleanup only removes files recognized as dBrief outputs; unrelated files in shared folders are left alone.

Both are **off by default**. When enabled, you pick an age (1 day, 1 week, 2 weeks, 30, 60, 90 or 180 days, or 1 year — 30 days by default), and each file is judged by its own creation date. Cleanup runs when dBrief launches and then daily while it's open. To run it right away, use the **Clean up now** row (**Delete old recordings…** or **Delete old transcripts…**) and confirm. The **Last clean-up** row shows when it last ran. Deletion is permanent and can't be undone.

## Settings

App preferences are stored in `UserDefaults` under the `com.dbrief.app` domain. You can reset all settings by deleting this domain with `defaults delete com.dbrief.app` in Terminal — but this also resets your output folder path and engine choices.

## API keys and tokens

Remote endpoint API keys, integration tokens, and webhook credentials are stored securely in the macOS Keychain under `com.dbrief.app`.

## Uninstalling completely

To remove everything dBrief has written to your Mac:

1. Delete `dBrief.app` from `/Applications`
2. Delete `~/Library/Application Support/com.dbrief.app/`
3. Run `defaults delete com.dbrief.app` in Terminal
4. Open Keychain Access and delete any entries for `com.dbrief.app`
5. Optionally delete your recording and transcription folders, and notes in any configured export destination
6. Remove the shared FluidAudio model cache only if no other app or dBrief build needs it
