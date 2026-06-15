# Live Transcription

See a running transcript while you record, and chat with it before the recording even finishes.

## What it is

Live Transcription shows a real-time, on-device transcript as you record — using Apple's built-in Speech framework, separately from whichever engine produces your final transcript. Your microphone and the meeting audio are transcribed as two channels and labelled separately:

- **You** — your microphone
- **Participant** — the system/meeting audio (the other people on the call)

It's a **preview**: the text appears quickly but is rougher than the final result. When you stop recording, dBrief still produces the authoritative transcript with your chosen [transcription engine](transcription-overview.md) (Apple Speech, Local Whisper, Parakeet, or a remote endpoint), which replaces the live preview.

## Turning it on

Go to **Settings → AI & Models → Transcription → Live Transcription** and enable **Transcribe live while recording**. It's off by default.

There's nothing else to configure — it uses the same input language as your transcription settings, and runs entirely on your Mac.

## Watching the live transcript

Start a recording, then open the **Transcripts** window. The in-progress recording is pinned at the top of the sidebar under **In Progress** (with a pulsing red dot) and is selected automatically. You'll see:

- A status banner — *Recording — live transcript* (or *Processing…*) and a running segment count.
- Finalized lines as they're confirmed, labelled **You** / **Participant**.
- The current in-progress phrase shown in lighter italic text until it's confirmed.

The **Live Transcript** button on the recording controls and the processing screen also jumps straight here.

When the recording finishes, the view automatically swaps the live preview for the final, higher-quality transcript.

## Chatting with the live transcript

While recording, click the **chat** button in the toolbar. Unlike a finished recording — where chat replaces the transcript — the live view opens chat as a **side panel on the right**, so you can keep watching the transcript grow while you ask questions about what's been said so far. Click the toggle (or the panel's **✕**) to hide it again.

Chat reads the transcript *as it currently stands* on each question, so answers reflect everything captured up to that moment. See [Transcript Chat](../ai-analysis/transcript-chat.md) for engines and example prompts.

**Your conversation carries over.** When the recording finishes, an in-progress chat isn't thrown away — it's kept and re-pointed at the final transcript, so the questions and answers from during the meeting are still there, and new questions use the polished text. (Chat history lives for the current app session; it isn't yet saved across app restarts.)

## Requirements & privacy

- Live Transcription runs **fully on-device** — audio never leaves your Mac.
- On **macOS 26+** it uses Apple's modern speech model (better accuracy and word timing). On **macOS 14–25** it falls back to the classic recognizer.
- The first time you use a given language, macOS may download a small speech asset — you'll briefly see **Preparing language…** in the live view.

## Things to know

- It's a **preview**, optimised for speed — expect the occasional misheard word. The final transcript from your chosen engine is the accurate one.
- The live preview itself isn't saved to disk; it's replaced by the final transcript once processing finishes.
- It adds a little CPU work during recording. If you don't need it, leave it off and rely on the post-recording transcript.
