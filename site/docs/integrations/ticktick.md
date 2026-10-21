# TickTick

Turn each action item from a meeting into a TickTick task.

> **Availability:** TickTick appears in **Settings → Integrations** in the official dBrief downloads. If you build dBrief yourself, it only appears when the build includes TickTick sign-in credentials.

## Setup

1. Go to **Settings → Integrations** and click **TickTick**
2. Turn on **Send to TickTick**
3. Click **Sign in with TickTick**. Your browser opens TickTick's sign-in page.
4. Sign in and allow access. When the browser says you're done, return to dBrief; the **TickTick account** row shows **Connected**.
5. Under **List**, choose where tasks go. The default is your **Inbox**.
6. Optionally click **Test connection** to check that everything works

While dBrief waits for the browser, you can click **Cancel**. If you don't finish within five minutes, sign-in stops and you can try again.

Your sign-in is stored in your Mac's Keychain. To disconnect, click **Sign out**.

## When the sign-in expires

TickTick sign-ins don't last forever. When yours expires, the TickTick page says **Your TickTick sign-in expired. Sign in again.** Click **Sign in with TickTick** to reconnect, then retry any deliveries that failed in the meantime.

## What gets sent

Only action items are sent, one task each. The task title is the action item. Underneath, a short line says which meeting it came from and when, for example:

> From "Weekly planning" · Oct 21, 2026 — added by dBrief (ref 1a2b3c4d)

The `ref` code links the tasks to that meeting's delivery, so a retry knows which tasks already exist. Placeholders such as "No action items identified" are never turned into tasks.

## A different list per profile

A [meeting profile](../profiles/using-profiles.md) can send its tasks to its own TickTick list. In **Settings → Profiles**, select the profile and, in its **Integrations** card, turn on **TickTick list** and pick the list.

## Retrying

If a delivery fails, open the recording's **Integrations…** action to send it again. See [Queue & Recovery](../history/queue-recovery.md#retry-an-integration). Retrying never creates duplicate tasks: dBrief checks which tasks for that meeting are already in TickTick and only adds the missing ones.

## Privacy

Action items are sent to TickTick over the internet, under your TickTick account.
