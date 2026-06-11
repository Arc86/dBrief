# Remote AI Endpoint

Connect dBrief to your own AI server for analysis.

## What it is

dBrief can send transcripts to any OpenAI-compatible `/v1/chat/completions` endpoint, or natively to Anthropic's Messages API. Built-in presets cover OpenAI, Anthropic (Claude), Google Gemini, Groq, and a local Ollama instance.

## Setting up an endpoint

1. Go to **Settings → AI & Models → AI Analysis**
2. Under the endpoint list, click the **+** menu and pick a provider preset (or **Custom…**)
3. The preset prefills the base URL and a default model — just add your **API Key**. For a custom server, also set:
   - **Name** — a label (e.g. "GPT-4o" or "Local Ollama")
   - **Base URL** — the server URL (e.g. `https://api.openai.com` or `http://localhost:11434`)
   - **Model** — the model name (e.g. `gpt-4o` or `llama3`)

## Provider presets

| Preset | Format |
|---|---|
| Anthropic (Claude) | Native Messages API (`/v1/messages`) |
| Google Gemini | OpenAI-compatible endpoint |
| OpenAI | OpenAI-compatible |
| Groq | OpenAI-compatible (fast inference) |
| Ollama (local) | OpenAI-compatible, no API key |

## Reasoning models

For models that emit "thinking"/chain-of-thought (GPT-5, o-series, gpt-oss, Qwen3, Gemini Flash), dBrief automatically asks the provider to skip or hide it — this lowers latency and keeps the structured output clean. Plain models are sent unchanged.

## Privacy

Transcripts are sent to whichever server you configure. If you use OpenAI or another cloud provider, transcripts are subject to that provider's privacy policy. If you use a local server like Ollama, data stays on your machine.
