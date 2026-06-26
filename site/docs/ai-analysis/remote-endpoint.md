# Remote AI Endpoint

Connect dBrief to your own AI server for analysis.

## What it is

dBrief can send transcripts to any OpenAI-compatible `/v1/chat/completions` endpoint, or natively to Anthropic's Messages API. Built-in presets cover OpenAI, Anthropic (Claude), Google Gemini, Groq, and a local Ollama instance.

## Setting up an endpoint

1. Go to **Settings → AI Analysis**
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

For models that emit "thinking"/chain-of-thought (GPT-5, o-series, gpt-oss, Qwen3, Gemini Flash, minimax, gemma, DeepSeek-R1-style), dBrief:

- Asks the provider to skip or hide the reasoning where supported (lower latency, cleaner structured output). Plain models are sent unchanged.
- Strips any `<think>…</think>` block that still comes back before parsing the summary, action items, and tags (so the JSON-based tags step doesn't choke on the reasoning).
- Requests an output-token limit so a server with a tiny default doesn't truncate the answer.

If a step fails with **"The model returned no answer — it likely ran out of output tokens while thinking"**, the model spent its whole output budget reasoning. Pick a non-reasoning model, or one with a larger output limit.

## Context window (large transcripts)

dBrief sends the **entire transcript** to your endpoint for analysis. Long meetings produce large transcripts (often 10,000–20,000+ tokens), and the request fails if it exceeds your server's configured context window.

If an AI step fails with **"The transcript is larger than the model's context window…"**, increase the context your server allocates:

- **llama.cpp / llama-server**: launch with a larger `--ctx-size` (e.g. `-c 32768`). Note the server may load a model far below its trained capacity by default — e.g. it logs `n_ctx_seq (8192) < n_ctx_train (262144)`, meaning the model supports 262K but is capped at 8K until you raise `--ctx-size`.
- **vLLM**: raise `--max-model-len`.
- **Ollama**: raise `num_ctx`.

Alternatively, pick an endpoint/model with a larger context window.

## Privacy

Transcripts are sent to whichever server you configure. If you use OpenAI or another cloud provider, transcripts are subject to that provider's privacy policy. If you use a local server like Ollama, data stays on your machine.
