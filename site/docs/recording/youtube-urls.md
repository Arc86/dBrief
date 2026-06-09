# Transcribe a Video or YouTube URL

You can transcribe audio from a YouTube link — or any URL supported by `yt-dlp` — without recording anything yourself.

## How it works

1. Open the dBrief menu bar window and find the **YouTube / Video URL** input.
2. Paste a video URL and start it.
3. dBrief downloads the audio, then opens the same post-recording sheet you'd see after a normal recording, where you choose what to transcribe and analyse.

The downloaded audio runs through the same transcription and AI pipeline as a recording, and produces the same Markdown output and integrations.

## Requirement: yt-dlp

This feature needs the `yt-dlp` tool. dBrief looks for it in your `PATH` and common Homebrew locations. If it isn't found, the panel offers to:

- **Download yt-dlp** (~15 MB) into dBrief's own support folder, or
- Install it yourself with Homebrew:

```
brew install yt-dlp
```

## Notes

- Any site `yt-dlp` supports works, not just YouTube.
- Audio is downloaded and re-encoded locally; transcription then follows your selected engine's privacy behaviour (on-device engines keep everything local).
