# File Locations

Where dBrief stores your recordings, exports, models, and settings.

## Recordings

Audio files are saved in dated subfolders inside your output folder (set during onboarding or in **Settings → Recording**):

```
~/Documents/Recordings/
└── 2026/
    └── 04/
        └── 2026-04-06_1430_team-standup.flac
```

You can change the output folder in **Settings → Recording**.

## Markdown exports

Markdown files are saved in the same dated subfolder as the audio file, unless you've configured an Obsidian vault folder — in which case they go there instead.

## AI models

Local AI models (Whisper and Qwen) are stored in Application Support:

```
~/Library/Application Support/dBrief/LocalAIPlugin/
├── WhisperKit/    ← Local Whisper model (~150 MB)
└── MLX/           ← Qwen3 4B model (~2–3 GB)
```

To remove models, use the options in **Settings → AI & Models**.

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
