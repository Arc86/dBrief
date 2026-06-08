# Remote Transcription Endpoint

Connect dBrief to your own transcription server for maximum accuracy and control.

## What it is

dBrief can send audio to any OpenAI-compatible `/v1/audio/transcriptions` endpoint, or to a [whisper-asr-webservice](https://github.com/ahmetoner/whisper-asr-webservice) instance. This lets you use larger Whisper models or cloud-hosted transcription services.

## Setting up an endpoint

1. Go to **Settings → AI & Models → Transcription**
2. Under the endpoint list, click **Add Endpoint**
3. Enter:
   - **Name** — a label for this endpoint (e.g. "Local Whisper Large")
   - **Base URL** — the server URL (e.g. `http://localhost:8080`)
   - **Model** — the model name (e.g. `whisper-1` or `large-v3`)
   - **API Key** — leave empty if your server doesn't require one

## Supported server formats

dBrief supports two server formats:

| Format | Endpoint path | Detection |
|---|---|---|
| OpenAI-compatible | `/v1/audio/transcriptions` | Default |
| whisper-asr-webservice | `/asr` | Auto-detected by URL pattern (port 8080 or 9000, or path contains `/asr`) |

dBrief auto-detects whisper-asr-webservice based on the URL — you don't need to configure this manually.

## Large files

For recordings that exceed typical size limits, dBrief automatically splits the audio into chunks and sends them sequentially, then combines the results.

## Privacy

Audio is sent to whichever server you configure. If you use a local server, audio stays on your network. If you use a cloud service, it is subject to that service's privacy policy.
