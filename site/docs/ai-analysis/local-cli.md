# Local CLI

Run your own command-line AI tool to analyse transcripts — for example Claude Code (`claude`), Ollama, or the `llm` CLI.

> **Requires:** the command-line tool you want to use must be installed and on your `PATH` (e.g. installed via Homebrew).

## What it is

Instead of calling a built-in model or a remote server, dBrief runs a shell command you configure and reads the result back from its output. This lets you reuse any AI CLI you already have set up — including agentic tools like Claude Code — without exposing an API endpoint.

dBrief invokes the command **once per recording** and asks it to return the summary, action items, tags, sentiment, and a title all together.

## Setup

1. Go to **Settings → AI & Models**
2. Select **Local CLI** as your AI engine
3. Under **Local CLI**, enter your **Command**, or pick one from the **Load Template** menu:
   - **Claude Code** — `claude -p "$DBRIEF_FULL_PROMPT"`
   - **Gemini CLI** — `gemini -p "$DBRIEF_FULL_PROMPT"`
   - **Codex CLI** — `codex exec "$DBRIEF_FULL_PROMPT"`
   - **GitHub Copilot CLI** — `copilot -p "$DBRIEF_FULL_PROMPT"`
   - **Ollama** — `ollama run llama3`
   - **llm CLI** — `llm "$DBRIEF_FULL_PROMPT"`
4. Set a **Timeout** (how long to wait before giving up)
5. Click **Test command** to confirm it runs

## How the prompt is passed

When dBrief runs your command it provides the prompt in two ways, so most CLI tools work with little or no extra wiring:

| Method | Detail |
|---|---|
| **Environment variables** | `DBRIEF_SYSTEM_PROMPT`, `DBRIEF_USER_PROMPT`, and `DBRIEF_FULL_PROMPT` are set for the command |
| **Standard input** | The full prompt is also piped to the command's `stdin` |

So a tool that reads stdin (like `ollama run llama3`) needs no placeholder, while a tool that takes the prompt as an argument can reference `"$DBRIEF_FULL_PROMPT"`.

The command must print a single JSON object to standard output containing `title_concept`, `summary`, `action_items`, `tags`, and `sentiment`. dBrief tells the model exactly this format in the prompt, so capable tools return it automatically. Any `<think>…</think>` reasoning before the JSON is ignored.

## Chat fallback

The transcript **Chat** window streams replies as you type, but a one-shot CLI command can't stream. So when your AI engine is **Local CLI**, the chat window uses a separate **Chat fallback engine** that you choose just below the command field.

By default this is set to an on-device engine that needs no extra setup — **Apple Intelligence** if your Mac supports it, otherwise **Gemma 4 E4B Local**. You can change it to a Remote Endpoint if you prefer.

> Everything else — summary, action items, tags, sentiment, and title — is produced by your CLI command. The fallback only affects the interactive chat window.

## Troubleshooting

- **"command not found"** — the tool isn't on your `PATH`. Install it (e.g. `brew install …`) and make sure it runs in a normal Terminal first. dBrief runs your command through a login shell so Homebrew paths are picked up.
- **Times out** — increase the **Timeout**, or check that the command isn't waiting for interactive input.
- **"output was not valid JSON"** — the tool printed something other than the requested JSON. Use **Test command** to see its raw output, and make sure it isn't printing extra log lines to standard output.

## Privacy

Where your transcript goes depends on the command you run. A local tool like Ollama keeps everything on your machine; a tool that calls a cloud service sends the transcript to that provider under their privacy policy.
