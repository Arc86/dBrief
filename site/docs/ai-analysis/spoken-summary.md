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

After you save it, the button changes to **Play Spoken**. It replays the saved audio without generating it again.

## Choosing a language and voice

Spoken summaries are configured in **Settings → Spoken Summary**. Pick a **voice engine** first:

- **Kokoro** (default) — fast and on-device. Speaks **English, Spanish, French, and Japanese**, with 28 English voices (American and British; "Heart" is the default), 3 Spanish, 1 French, and 5 Japanese.
- **Qwen3** — speaks **10 languages** with a choice of **9 voices**, plus an editable voice-style instruction (calm, measured, etc.). The 1.7B model sounds the most natural and follows the style instruction; the 0.6B model is lighter on memory. (Qwen3 requires macOS 26 or later.)

Then choose a **Language**. It sets both the language the AI writes the briefing in and the language it's spoken in, whatever language the meeting was held in. The list shows the languages your voice engine speaks. If you switch to an engine that doesn't speak your chosen language, dBrief uses English and says so under the picker.

With Kokoro, the voice list shows only the voices for the chosen language, and changing the language moves you to that language's default voice. English voices download the first time you use them (about 510 KB each). Japanese uses its own voice model (about 217 MB), also downloaded on first use. After that, everything works offline. British voices currently use US pronunciation rules.

Use the **Preview voice** button to hear the current voice speak a short sample in the chosen language.

Power users can also edit the prompt that writes the spoken script under **Settings → Spoken Summary**. dBrief adds the language instruction to your prompt automatically, so a custom prompt still follows the **Language** setting.

## Which AI engine writes the script

The rewrite uses your currently selected [AI engine](ai-overview.md) (Apple Intelligence, Local Gemma, or a Remote Endpoint). If your engine is set to **Local CLI** — which can't generate here — dBrief falls back to your configured chat-fallback engine.

## Privacy

With Kokoro or an on-device AI engine, both the script generation and the speech synthesis happen entirely on your Mac — nothing leaves the device. With a remote AI endpoint, only the script-rewrite step is sent to your server; the speech synthesis is always on-device.

## Where the files live

A saved Spoken Summary is stored next to the recording as a `.spokensummary.m4a` audio file and a script sidecar. Both are removed when you delete the recording or when [auto-delete](../reference/file-locations.md) cleans it up.
