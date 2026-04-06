# Webhook

Send an HTTP POST request to any URL after each recording.

## What it's for

Use the webhook integration to connect dBrief to any service that accepts HTTP requests — Zapier, Make (Integromat), a custom backend, or anything else.

## Setup

1. Go to **Settings → Integrations**
2. Enable **Webhook**
3. Enter your webhook URL
4. Choose which fields to include in the payload

## Payload format

dBrief sends the selected fields as a JSON body or multipart/form-data (if audio upload is enabled).

## Including the audio file

Enable **Include audio** in the webhook settings to attach the recording as a file upload. The request is sent as `multipart/form-data` when audio is included.

> **Note:** Audio files can be large (tens of MB for longer recordings). Make sure your webhook endpoint can handle the payload size.

## What gets sent

Choose from: transcript, summary, action items, tags, sentiment, the full Markdown export, and optionally the audio file.
