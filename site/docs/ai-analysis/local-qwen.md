# Qwen3 4B Local

On-device AI analysis using the Qwen3 4B language model, running via MLX on Apple Silicon.

> **Requires:** Mac with Apple Silicon (M1 or later).

## What it is

Qwen3 4B Local runs a 4-billion-parameter language model directly on your Mac using Apple's MLX framework and the Neural Engine. No data leaves your device.

## First use: model download

The first time you select Qwen3 4B Local, dBrief downloads the model (approximately 2–3 GB). This happens once and the model is stored at:

```
~/Library/Application Support/dBrief/LocalAIPlugin/MLX/
```

You need a working internet connection for the initial download. After that, analysis works fully offline.

## Setup

1. Go to **Settings → AI & Models**
2. Select **Qwen3 4B Local** as your AI engine
3. dBrief will prompt you to download the model if it isn't already present

## Streaming output

Results appear progressively as the model generates them — you'll see the summary build up word by word rather than waiting for the full response.

## Deleting the model

To free up disk space, go to **Settings → AI & Models** and use the option to remove the Qwen model. You can re-download it at any time.

## Privacy

All processing happens on-device. Your transcripts are never sent to any server.
