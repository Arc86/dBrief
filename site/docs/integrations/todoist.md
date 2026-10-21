# Todoist

Turn each action item from a meeting into a Todoist task.

## Setup

1. In Todoist, open **Settings → Integrations → Developer** and copy your **API token**. In dBrief, the **Open Todoist** button takes you there.
2. In dBrief, go to **Settings → Integrations** and click **Todoist**
3. Turn on **Send to Todoist**
4. Paste the token into **API token**
5. Under **Project**, choose where tasks go. The default is your **Inbox**.
6. Optionally click **Test connection** to check that the token works

The token is stored in your Mac's Keychain. It doesn't expire, so you only set it up once. If you reset the token in Todoist, paste the new one here.

## What gets sent

Only action items are sent, one task each. The task is the action item's text, with a short note underneath saying which meeting it came from and when, for example:

> From "Weekly planning" · Oct 21, 2026 — added by dBrief

Summaries, transcripts and tags are not sent to Todoist. Placeholders such as "No action items identified" are never turned into tasks, so a meeting without action items creates nothing.

## A different project per profile

A [meeting profile](../profiles/using-profiles.md) can send its tasks to its own Todoist project. In **Settings → Profiles**, select the profile and, in its **Integrations** card, turn on **Todoist project** and pick the project. Other profiles keep using the project chosen on the Todoist page.

## Retrying

If a delivery fails (for example, you were offline), open the recording's **Integrations…** action to send it again. See [Queue & Recovery](../history/queue-recovery.md#retry-an-integration). Retrying never creates duplicate tasks: Todoist ignores tasks dBrief already added, so only the missing ones are created.

## Privacy

Action items are sent to Todoist over the internet, under your Todoist account.
