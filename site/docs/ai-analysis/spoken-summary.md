# Spoken Summary

Turn a recording's summary into a short, natural-sounding audio briefing you can listen to.

## What it is

A Spoken Summary takes the written summary and action items dBrief already generated and has the AI rewrite them into a flowing, conversational narration — then reads it aloud with an on-device text-to-speech voice. It's meant for catching up on a meeting hands-free: on a walk, a commute, or while doing something else.

The audio and its script are saved alongside the recording, so you can replay them any time.

## Generating one

Open a recording in the [transcript viewer](../history/transcript-viewer.md) and go to the **Summary** tab. If the recording has a summary, you'll see a **Generate Spoken** button.

1. Click **Generate Spoken**. dBrief rewrites the summary into a spoken script, then synthesizes it to audio. The first run also downloads the voice model, so it takes a little longer.
2. A player appears with the script and playback controls. Listen to the result.
3. Click **Save** to keep it, or **Discard** to throw it away.

Once saved, the button becomes **Play Spoken** — clicking it replays the saved audio instantly without regenerating.

## Choosing a voice

Voices are configured in **Settings → Spoken Summary**. Pick a **voice engine** first:

- **Kokoro** (default) — fast, on-device, and **English-only**. A single natural voice ("Heart"). Best if your summaries are in English.
- **Qwen3** — multilingual, with a choice of **9 voices** and **10 languages**, plus an editable voice-style instruction (calm, measured, etc.). The 1.7B model sounds the most natural and follows the style instruction; the 0.6B model is lighter on memory. (Qwen3 requires macOS 26 or later.)

Use the **Preview voice** button to audition the current voice with a short sample before committing.

> **Language note:** Multi-language TTS support is still limited, so by default the spoken script is written in **English** regardless of the meeting's language. Power users can edit the Spoken Summary prompt under Settings → Spoken Summary to change this.

## Which AI engine writes the script

The rewrite uses your currently selected [AI engine](ai-overview.md) (Apple Intelligence, Local Gemma, or a Remote Endpoint). If your engine is set to **Local CLI** — which can't generate here — dBrief falls back to your configured chat-fallback engine.

## Privacy

With Kokoro or an on-device AI engine, both the script generation and the speech synthesis happen entirely on your Mac — nothing leaves the device. With a remote AI endpoint, only the script-rewrite step is sent to your server; the speech synthesis is always on-device.

## Where the files live

A saved Spoken Summary is stored next to the recording as a `.spokensummary.m4a` audio file and a script sidecar. Both are removed when you delete the recording or when [auto-delete](../reference/file-locations.md) cleans it up.
