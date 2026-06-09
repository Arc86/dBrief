# Remote AI Endpoint

Connect dBrief to your own AI server for analysis.

## What it is

dBrief can send transcripts to any OpenAI-compatible `/v1/chat/completions` endpoint. This works with OpenAI's API, a local Ollama instance, or any other compatible server.

## Setting up an endpoint

1. Go to **Settings → AI & Models**
2. Under **AI Endpoint**, click **Add Endpoint**
3. Enter:
   - **Name** — a label for this endpoint (e.g. "GPT-4o" or "Local Ollama")
   - **Base URL** — the server URL (e.g. `https://api.openai.com` or `http://localhost:11434`)
   - **Model** — the model name (e.g. `gpt-4o` or `llama3`)
   - **API Key** — your API key, or leave empty for local servers that don't require one

## Privacy

Transcripts are sent to whichever server you configure. If you use OpenAI or another cloud provider, transcripts are subject to that provider's privacy policy. If you use a local server like Ollama, data stays on your machine.
