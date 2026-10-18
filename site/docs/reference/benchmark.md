# Performance

A settings page that tracks how fast each transcription and AI model runs, plus a
lifetime total of everything dBrief has transcribed for you.

## Where to find it

Open **Settings → Performance** (at the bottom of the Settings sidebar). Metrics are
recorded automatically every time a recording is transcribed or analyzed — there's
nothing to turn on.

## Fastest model

The **Fastest model** card shows the transcription model with the best speed. The
**big number** is how much faster than real-time the model itself runs — e.g. `21.6×`
means a 60-minute recording was transcribed in under three minutes of pure model time.

Below it, the card shows:

- **Avg. audio** and **Avg. processing** — the average audio length and processing
  time across all sessions for that model.
- **End-to-end** — the speed of the whole transcription step, including loading the
  model into memory, moving audio to the on-device helper, and (if enabled) speaker
  diarization.
- **Load / overhead** — the extra time between pure model time and end-to-end. This
  is what [model prewarming](../transcription/local-whisper.md#instant-starts-model-prewarming)
  hides behind your recording.

> Models without a separate inference time (Apple Speech, Remote) — or recordings made
> before this was measured — show only the end-to-end number.

## Transcription models

The **Transcription models** card compares every model you've used, with its
**Relative speed** and number of **Sessions**. The quickest is marked **Fastest**.
Click a column header to sort by it.

## AI analysis models

The **AI analysis models** card shows the average time each AI model takes to produce
a summary, action items, tags, and sentiment for a recording (**Avg. analysis**).

## Recent recordings

Below the model cards, **Recent recordings** lists your individual recent
recordings (newest first) so you can confirm whether a particular one was actually
slow — not just how the model averages out. Re-transcribing a saved recording also
adds a row here.

Each row collapses to the recording's title, date, the **audio length**, a **speed
badge** (⚡ fast, 🐢 slow) showing how far above or below real-time the transcription
ran, and the total processing time. Seeing the audio length next to the times makes
the speed concrete — e.g. 10:50 of audio processed in 2:34. Expand a row to see
exactly where the time went, step by step:

- **Finalize audio** — merging and encoding the recording before transcription.
- **Transcribe** — the transcription itself, with a caption splitting pure **model**
  time from **overhead** (model load, moving audio to the helper).
- **Diarize** — speaker identification, when enabled.
- **AI analysis** — summary, action items, tags, and sentiment.
- **Vocabulary fix** — spell-correcting your custom vocabulary terms, when set.
- **Title** — generating the recording's title.

Steps that didn't run are left out. A bar next to each step shows its share of the
total, so the biggest time sink is obvious at a glance.

If a recording ran much slower than that model usually does for you, it's tagged
**"slower than usual"** — a direct answer to "was that one actually sluggish, or did
it just feel that way?"

## Time range

Use the range menu in the header to filter the page to the **Last 7 Days**, **Last 30
Days**, **Last Year**, or **All Time**. Speeds are averaged over the sessions in the
selected range.

## Total transcribed by dBrief

The header shows a running total — e.g. **"12h 34m transcribed by dBrief"** — of all
the audio dBrief has turned into text on your Mac, including re-transcriptions. This
is a lifetime odometer: it only ever counts up.

## Clearing stats

The **trash** button in the header (**Clear benchmark stats**) clears the per-model
benchmark history after a confirmation. The lifetime *"transcribed by dBrief"* total
is **kept** — only the per-model stats are reset.

The benchmark log lives at
`~/Library/Application Support/com.dbrief.app/model-performance.json`.
