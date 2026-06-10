# Benchmark & Performance

A Power User panel that tracks how fast each transcription and AI model runs, plus a
lifetime total of everything dBrief has transcribed for you.

## Where to find it

Enable **Power User Mode** in **Settings → General**, then open the **Benchmark**
tab in Settings. Metrics are recorded automatically every time a recording is
transcribed or analyzed — there's nothing to turn on.

## Transcription cards

Each transcription model gets a card. The **big number** is how much faster than
real-time the model itself runs — e.g. `21.6x` means a 60-minute recording was
transcribed in under three minutes of pure model time.

Underneath, a smaller line shows the **end-to-end** speed and the **load/overhead**
that sits between the two:

- **Model** (the headline) — pure inference time, just the model crunching audio.
- **End-to-end** — the whole transcription step, including loading the model into
  memory, moving audio to the on-device helper, and (if enabled) speaker
  diarization.
- **load/overhead** — the difference between them. This is what
  [model prewarming](../transcription/local-whisper.md#instant-starts-model-prewarming)
  hides behind your recording.

The card also shows the average audio length and average processing time across all
sessions for that model.

> Cards for recordings made before this feature — or with engines that don't report
> a separate inference time (Apple Speech, Remote) — show only the end-to-end number.

## AI analysis cards

Each AI model gets a card showing the average time it takes to produce a summary,
action items, tags, and sentiment for a recording.

## Time range

Use the menu in the top-right to filter the cards to the **last 7 days**, **30
days**, **last year**, or **all time**. Speeds are averaged over the sessions in the
selected range.

## Total transcribed by dBrief

The header shows a running total — e.g. **"12h 34m transcribed by dBrief"** — of all
the audio dBrief has turned into text on your Mac. This is a lifetime odometer: it
only ever counts up.

## Clearing stats

The **trash** button in the header clears the per-model benchmark history after a
confirmation. The lifetime *"transcribed by dBrief"* total is **kept** — only the
per-model cards are reset.

The benchmark log lives at
`~/Library/Application Support/com.dbrief.app/model-performance.json`.
