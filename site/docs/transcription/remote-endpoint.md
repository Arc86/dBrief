# Remote Transcription Endpoint

Connect dBrief to your own transcription server for maximum accuracy and control.

## What it is

dBrief can send audio to any OpenAI-compatible `/v1/audio/transcriptions` endpoint, to a [whisper-asr-webservice](https://github.com/ahmetoner/whisper-asr-webservice) instance, or to a built-in cloud provider (Groq Whisper, Deepgram, ElevenLabs Scribe). This lets you use larger Whisper models or fast cloud-hosted transcription services.

## Setting up an endpoint

1. Go to **Settings → AI & Models → Transcription**
2. Under the endpoint list, click the **+** menu and pick a provider preset (or **Custom…**)
3. The preset prefills the base URL and a default model — just add your **API Key**. For a custom server, also set:
   - **Name** — a label for this endpoint (e.g. "Local Whisper Large")
   - **Base URL** — the server URL (e.g. `http://localhost:8080`)
   - **Model** — the model name (e.g. `whisper-1` or `large-v3`)

## Provider presets

| Preset | Format | Notes |
|---|---|---|
| Groq Whisper | OpenAI-compatible | `whisper-large-v3-turbo` — fast and low-cost |
| Deepgram | Native `/v1/listen` | `nova-3`; word timestamps and (with diarization on) speaker labels, handled server-side |
| ElevenLabs Scribe | Native `/v1/speech-to-text` | `scribe_v1`; 90+ languages |
| OpenAI / Whisper API | OpenAI-compatible | `whisper-1` |
| Custom… | OpenAI-compatible or whisper-asr-webservice | whisper-asr is auto-detected by URL (port 8080/9000 or `/asr`) |

For Deepgram and ElevenLabs you only need a valid API key — there's no model list to fetch.

## Large files

For OpenAI-compatible/whisper-asr endpoints, dBrief automatically splits oversized audio into chunks and combines the results. Deepgram and ElevenLabs accept long audio directly, so chunking is skipped for them.

## Privacy

Audio is sent to whichever server you configure. If you use a local server, audio stays on your network. If you use a cloud service, it is subject to that service's privacy policy.
