# Local vs Remote AI

dBrief lets you choose where transcription and AI analysis happen: **on your Mac** (local) or **on a server** (remote). Both work the same way from your side — the difference is the trade-off between privacy, quality, speed, and cost. This page helps you decide.

This choice applies in two places, and you can mix them — for example, transcribe locally but analyse remotely:

- **Transcription** — Apple Speech, Local Whisper, and Parakeet run locally; a Remote Endpoint runs on a server. See [Transcription Overview](../transcription/transcription-overview.md).
- **AI Analysis** — Apple Intelligence and Gemma 4 E4B Local run locally; a Remote Endpoint runs on a server. See [AI Analysis Overview](ai-overview.md).

## The short version

| | Local (on your Mac) | Remote (a server) |
|---|---|---|
| **Privacy** | Best — nothing leaves your device | Depends on the provider |
| **Quality** | Good; limited by your hardware | Can be the highest, with large models |
| **Speed** | Depends on your Mac | Fast, even on older Macs |
| **Cost** | Free after download | Often pay-per-use (cloud APIs) |
| **Internet** | Only for first-time model download | Required for every recording |
| **Disk space** | Models stored locally | None used |

## Local AI

Local engines run entirely on your Mac. Apple Intelligence and Apple Speech use built-in models (on macOS 26+, Apple Speech downloads a small language model the first time you use a given language); Local Whisper, Parakeet, and Gemma download a model once and then run on your Apple Silicon GPU and Neural Engine.

**Benefits**

- **Privacy** — your audio and transcripts never leave your Mac. Nothing is uploaded to any server. This is the main reason to choose local.
- **Works offline** — after the one-time model download, no internet connection is needed.
- **No ongoing cost** — there's no API key, no per-recording charge, and no rate limits.
- **Always available** — no server outages or usage quotas to worry about.

**Limitations**

- **Quality can be lower** — local models are smaller than the largest cloud models. Summaries may be less nuanced and transcripts less accurate, especially for technical content, accents, or noisy audio. A larger Local Whisper model improves accuracy at the cost of speed and memory.
- **Depends on your hardware** — performance scales with your Mac. On Apple Silicon with plenty of RAM it's fast; on older or memory-constrained machines it can be slow, and some engines (Gemma, MLX) require Apple Silicon.
- **Uses your Mac's resources** — transcription and analysis use the GPU and Neural Engine, which can heat up the machine and drain battery during long recordings.
- **Disk space** — downloaded models take up storage (from a few hundred MB to several GB). You can purge models you no longer use.

## Remote AI

Remote engines send your transcript (and, for transcription, your audio) to a server over the internet. "Remote" doesn't always mean a big cloud provider — it can also be a server you run yourself.

**Benefits**

- **Highest quality** — cloud providers offer large, state-of-the-art models that typically produce the most accurate transcripts and the most polished summaries.
- **Fast on any Mac** — the heavy work happens on the server, so even an older or low-memory Mac gets quick results.
- **No local download or disk use** — nothing is stored on your machine, and your Mac stays free for other work.

**Limitations**

- **Privacy depends on the provider** — your data is sent to whichever endpoint you configure. With a cloud provider like OpenAI, your transcripts are subject to **that provider's privacy policy** and may be processed or retained on their servers. Don't send sensitive or confidential recordings to a third-party service you don't trust.
- **Requires internet** — every recording needs a working connection; there's no offline fallback.
- **Can cost money** — commercial APIs usually charge per use, and may apply rate limits or quotas.
- **Relies on the service** — outages, model changes, or deprecations on the provider's side affect you.

### A middle ground: your own server

If you want cloud-style speed and quality but local-style privacy, you can point a Remote Endpoint at a server **you** run — for example a local [Ollama](https://ollama.com) instance or a self-hosted Whisper server. The data goes to that machine and no further, so it stays under your control. See [Remote AI Endpoint](remote-endpoint.md) and [Remote Endpoint (transcription)](../transcription/remote-endpoint.md).

## Which should I choose?

- **Choose local** if privacy matters most, you record sensitive conversations, you're often offline, or you'd rather not pay per use — and you accept that quality is bound by your Mac's hardware.
- **Choose remote (cloud)** if you want the best possible quality and speed, you have a reliable connection, and you're comfortable with the provider's handling of your data.
- **Choose remote (your own server)** if you want strong quality and speed *and* want your data to stay on hardware you control.

You can change engines at any time in **Settings → AI Analysis**, and try a different one on a past recording from the [Recording History](../history/recording-history.md).
