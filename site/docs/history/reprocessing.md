# Reprocessing a Recording

Change a recording's transcription or analysis without recording the meeting again. In the [transcript viewer](transcript-viewer.md), open **Reprocess** (or use the **Recording** menu). In the menu bar's [Recent recordings](recording-history.md) list, expand the recording and open **Reprocess**, or right-click it and choose **Reprocess**.

| Action | When to use it |
|---|---|
| **Link Calendar Meeting…** | Attach the matching calendar event, optionally using its title and attendees. Shown when a calendar source is set up |
| **Retranscribe…** (or **Transcribe…**) | Use saved audio with a different transcription engine, model, or spoken language |
| **Re-run AI Analysis…** | Generate new analysis from the saved transcript |
| **Detect Speakers Again…** | Redetect speakers while keeping the transcript words and timing |
| **Restore Previous Results** | Restore the previous saved result set when one is available |

Review the options, then click **Start** (or **Add to queue** while another recording is processing). Retranscription shows the current processing step and progress while it runs.

## Pick any engine for one run

The options start from your current settings, but you can change them for this run only. Your Settings stay as they are.

- **Transcription** — choose **On this Mac** (with the engine and model, and **Change model…** for Whisper) or any service under **Remote services**, plus the **Spoken language** and whether to **Detect speakers**.
- **AI analysis** — choose any **AI engine**, or any configured endpoint under **Remote endpoints**, and the **AI output language** for this run.

The **Processing destinations** card shows where the audio and transcript will be sent, so you can check before you start. If a list is empty, add a provider first in **Settings → Transcription** or **Settings → AI analysis**.

## Your existing results stay available

Replacement results are staged separately and only replace the saved result after success. If an attempt fails or stops, open [Queue & Recovery](queue-recovery.md) to resume or discard it. While an attempt is pending, the current results are read-only, and **Reprocess** says why; it offers **Show in Queue & Recovery** and **Discard Run and Retranscribe…**.

If you retain existing AI analysis after replacing the transcript, dBrief marks that analysis as based on the old transcript. Re-run AI analysis when you want the summary and action items to reflect the new words.

## Exports and voices

Reprocessing does not automatically rewrite exported notes, resend integrations, or enroll voices in the Voice Library. Review the new result before choosing any follow-up export or delivery.
