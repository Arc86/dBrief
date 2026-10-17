# Webhook

Send an HTTP POST request to any URL after each recording.

## What it's for

Use the webhook integration to connect dBrief to any service that accepts HTTP requests — Zapier, Make (Integromat), a custom backend, or anything else.

## Setup

1. Go to **Settings → Integrations** and click **Webhook**
2. Turn on **Send to a webhook**
3. Enter your webhook **URL**
4. Optionally set a **Timeout** and add headers in the **Headers** card
5. Choose which fields to include in the **Send fields** card
6. Optionally click **Test connection** to check that the URL is valid (no request is sent)

## Payload format

dBrief sends the selected fields as a JSON body or multipart/form-data (if audio upload is enabled).

## Including the audio file

Turn on **Audio** in the **Send fields** card to attach the recording as a file upload. The request is sent as `multipart/form-data` when audio is included.

> **Note:** Audio files can be large (tens of MB for longer recordings). Make sure your webhook endpoint can handle the payload size.

## What gets sent

Choose from: transcript, summary, action items, tags, sentiment, the full Markdown export, meeting info from your calendar, and optionally the audio file.
