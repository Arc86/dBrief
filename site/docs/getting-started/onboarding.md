# Onboarding Wizard

A walkthrough of the setup wizard that appears when you first launch dBrief.

## What the wizard covers

The onboarding wizard walks you through a few short steps.

### 1. Welcome

A quick introduction. You're reminded that you can press the global record shortcut (**⌃⌥⌘R** by default) to start and stop recording from anywhere on your Mac.

### 2. Permissions

dBrief asks for the permissions it uses. You can grant them here or skip and grant them later:

- **Microphone** — records your voice.
- **Screen Recording** — for capturing system audio (what your Mac plays out loud), such as other people on a call.

dBrief needs at least one of these two to record, so you can continue once **Microphone**, **Screen Recording**, or both are granted.
- **Speech Recognition** — for the built-in Apple Speech transcription engine.
- **Calendar** — lets dBrief pre-fill the meeting title and participants from the calendar event that matches your recording.

### 3. Transcription & AI

Pick how recordings are turned into text and summaries. Each option shows a one-line description, and the **Recommended** choice is labelled for you:

- **Transcription** defaults to **Local Whisper** — accurate, multilingual, and fully on-device (it downloads a model the first time you transcribe).
- **AI Analysis** defaults to the best on-device option for your Mac — **Apple Intelligence** on macOS 26+, otherwise the local **Gemma** model.

Both defaults run entirely on your Mac with no account or server to set up. If you choose **Remote Endpoint** for either, the wizard reminds you to add your server URL and key in **Settings → Transcription** or **Settings → AI analysis** before recording.

### 4. Prepare your models

If the engines you picked need on-device models that aren't on your Mac yet, the wizard offers to download them now — for example the Whisper model for transcription, or the Gemma model for AI analysis and chat. Each model shows its download progress, with **Cancel** and **Retry** controls. Models you've already downloaded are skipped, and if everything is ready, this step doesn't appear at all.

Choose **Set up later** to skip it; dBrief then downloads the models in Settings or the first time you need them.

### 5. Before you record

A reminder to let everyone know before you record a meeting or call. You're responsible for how you use dBrief, including informing participants, getting any required consent, and following applicable laws and your organisation's policies — dBrief doesn't notify participants or ask for consent on your behalf.

Tick **I understand my responsibility to use dBrief lawfully and obtain any required consent**, then click **Start using dBrief**. dBrief lives in your menu bar — click the **dB** icon any time to record or open Settings.

## Changing your choices later

Everything the wizard covers can be changed at any time:

- **Transcription engine** — **Settings → Transcription**
- **AI engine** — **Settings → AI analysis**
- **Output folders** — **Settings → Storage → Folders**

## Revisiting the wizard

Every setting the wizard covers is also available directly in **Settings** — open it with **Settings…** in the gear menu of the dBrief menu bar panel. To see the wizard itself again, go to **Settings → General → Setup** and click **Show again** next to **Welcome and setup guide**. The setup guide opens the next time you open the menu bar panel.
