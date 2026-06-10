# Onboarding Wizard

A walkthrough of the setup wizard that appears when you first launch dBrief.

## What the wizard covers

The onboarding wizard walks you through four short steps.

### 1. Welcome

A quick introduction. You're reminded that you can press the global record shortcut (**⌃⌥⌘R** by default) to start and stop recording from anywhere on your Mac.

### 2. Permissions

dBrief asks for the permissions it uses. You can grant them here or skip and grant them later:

- **Microphone** — required for all recording. You can't continue past this step without it.
- **Screen Recording** — for capturing system audio (what your Mac plays out loud) alongside your mic.
- **Speech Recognition** — for the built-in Apple Speech transcription engine.
- **Calendar** — lets dBrief pre-fill the meeting title and participants from your calendar when a recording starts.

### 3. Transcription & AI

Pick how recordings are turned into text and summaries. Each option shows a one-line description, and the **Recommended** choice is labelled for you:

- **Transcription** defaults to **Local Whisper** — accurate, multilingual, and fully on-device (it downloads a model the first time you transcribe).
- **AI Analysis** defaults to the best on-device option for your Mac — **Apple Intelligence** on macOS 26+, otherwise the local **Gemma** model.

Both defaults run entirely on your Mac with no account or server to set up. If you choose **Remote Endpoint** for either, the wizard reminds you to add your server URL and key in **Settings → AI & Models** before recording.

### 4. Ready

You're all set. dBrief lives in your menu bar — click the **dB** icon any time to record or open Settings.

## Changing your choices later

Everything the wizard covers can be changed at any time:

- **Transcription engine** — **Settings → AI & Models → Transcription**
- **AI engine** — **Settings → AI & Models → AI Analysis**
- **Output folders** — **Settings → General → Folders**

## Revisiting the wizard

Every setting the wizard covers is also available directly in **Settings** — open Settings from the dBrief menu bar window. To see the wizard itself again, use **Reset Onboarding** in **Settings → General**, which re-shows the setup guide on next launch.
