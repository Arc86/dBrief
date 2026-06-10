## dBrief 1.1.1

**Highlights**

- **Bundled ffmpeg** — the `.dmg` now ships a static `ffmpeg` inside the app, so DMG users get full audio mixing, filtering, and AAC encoding with **no separate Homebrew install**. (Homebrew installs still use the system `ffmpeg` the formula depends on.)
- **Faster transcription start** — on Apple Silicon the local Whisper model is now **prewarmed while you record** (plus opt-in launch/wake prewarm), so transcription begins the moment you hit Stop instead of waiting on a model load.
- **Performance benchmark panel** (Power User) — per-model transcription/AI speed with **pure-inference vs end-to-end** realtime ratios, a **lifetime "transcribed by dBrief"** odometer, and a **Clear Stats** action.

**Improvements**

- **Auto-delete (retention)** — independently purge old recordings and/or transcripts after a chosen age (off by default); runs at launch or on demand via **Run Cleanup Now**.
- **Start at login** toggle.
- **Permissions** consolidated into their own top-level Settings page.
- **Reset Onboarding** to re-run the setup wizard.
- Model Performance panel in the transcript viewer.
