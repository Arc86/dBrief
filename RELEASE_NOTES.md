## dBrief 1.1.4

Hotfix for **Homebrew-from-source** installs (1.1.2/1.1.3 failed to build at the
code-signing step). The stable self-signed cert can't be resolved inside
Homebrew's build environment, so signing now **falls back to ad-hoc** there
instead of failing the build — `brew install`/`upgrade` completes again. DMG
downloads are unaffected and keep the stable cert (so Screen Recording survives
updates); Homebrew rebuilds sign ad-hoc, as they did before 1.1.2. Everything
below (the 1.1.2 feature set) is included.

**Highlights**

- **More transcription & AI providers** — native **Anthropic Claude** for AI analysis, plus **Deepgram** and **ElevenLabs Scribe** as cloud transcription engines (with word-level timestamps and diarization where supported). All added through the curated provider picker in Settings.
- **More reliable remote AI analysis** — works gracefully with small-context and reasoning models: chain-of-thought output is suppressed and stripped, responses are capped to avoid context overflow on strict servers (vLLM/llama.cpp), and a context-window error now surfaces a clear "increase your server's context size" hint instead of a cryptic failure.
- **Screen Recording permission now survives updates** — releases are signed with a stable certificate, so macOS no longer silently drops your Screen Recording grant after each update. Upgrading from an earlier build you'll re-grant once; it stays put from then on.

**Improvements**

- **Live microphone switching** — change input device mid-recording without stopping.
- **Cleaner transcripts** — automatic removal of hallucinated tags/markup and non-speech annotations on every engine, plus an optional filler-word ("um", "uh") cleanup toggle.
- **Custom vocabulary in AI analysis** — your domain-specific terms now bias the AI summaries and action items too, not just Whisper.
- **Better Parakeet endings** — trailing-silence padding keeps sentence-final punctuation from being dropped.
- **Calendar participants** flow into recordings — attendees pre-fill diarization speaker names and meeting metadata is saved alongside the output.
- **In-app "Update available" popup** when a new version is published.
- **Local CLI** AI engine — longer default timeout (180s, with a 600s option) and reliable login-shell PATH resolution so tools like `claude` are found in the DMG build.
- Per-track capture now uses Apple Lossless; Settings, transcript, and live-transcript windows are singletons (no more duplicate windows).
