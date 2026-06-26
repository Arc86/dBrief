# Gemma 4 E4B Local

On-device AI analysis using Google's Gemma 4 E4B language model, running via MLX on Apple Silicon.

> **Requires:** Mac with Apple Silicon (M1 or later).

## What it is

Gemma 4 E4B Local runs a Gemma language model directly on your Mac using Apple's MLX framework and the GPU. No data leaves your device. The model is 4-bit quantized to keep it fast and memory-efficient.

## First use: model download

The first time you use Gemma 4 E4B Local, dBrief downloads the model. This happens once and the model is stored at:

```
~/Library/Application Support/dBrief/LocalAIPlugin/MLX/
```

You need a working internet connection for the initial download. After that, analysis works fully offline.

## Setup

1. Go to **Settings → AI Analysis**
2. Select **Gemma 4 E4B Local** as your AI engine
3. dBrief downloads the model on first use. With **Power User Mode** enabled, you can also use the **Download model** button to fetch it ahead of time (with progress and a cancel option)

## Streaming output

Results appear progressively as the model generates them — you'll see the summary build up as it's written rather than waiting for the full response.

## Deleting the model

To free up disk space, enable **Power User Mode** and use **Purge local Gemma model** in **Settings → AI Analysis**. You can re-download it at any time.

## Privacy

All processing happens on-device. Your transcripts are never sent to any server.
