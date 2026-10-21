# Notion

Send each meeting to Notion as its own page: the summary, action items as to-dos, tags and sentiment, and optionally the transcript.

## Setup

### 1. Create a Notion integration

1. In dBrief, go to **Settings → Integrations**, click **Notion** and turn on **Send to Notion**
2. Click **Open Notion** next to **Where to get it**. This opens Notion's integrations page.
3. Create a new **internal** integration for your workspace (for example, name it "dBrief") and copy its **secret**
4. Paste the secret into **Integration secret** in dBrief. It's stored in your Mac's Keychain.

### 2. Connect a page or database

Notion only lets the integration see what you share with it. In Notion, open the page or database where meetings should go, click **•••** → **Connections**, and add your integration.

### 3. Choose the destination

Back in dBrief, open the **Destination** menu. It lists the pages and databases connected to your integration, each marked **Page** or **Database**. Pick one, then optionally click **Test connection**.

- **A page:** each meeting becomes a sub-page of it.
- **A database:** each meeting becomes a new entry. dBrief fills the title, and also a date column and a tags column when the database has them.

Don't see your page? Check that it's connected to the integration, then reopen the menu.

## What gets sent

The **Include in the page** card chooses what goes on each page:

| Option | On by default |
|---|---|
| **Summary** | Yes |
| **Action Items** | Yes, as to-do checkboxes |
| **Tags** | Yes |
| **Sentiment** | Yes |
| **Attendees** | Yes, from the matching calendar event |
| **Transcript** | No. It goes at the end of the page; long meetings make long pages. |

The page is named after the meeting. It starts with a line showing the date, the duration and a short `ref` code, then a heading for each section. The summary's formatting carries over as real Notion headings, lists and bold text. Placeholders such as "No action items identified" are left out.

## A different destination per profile

A [meeting profile](../profiles/using-profiles.md) can send its meetings to its own Notion page or database. In **Settings → Profiles**, select the profile and, in its **Integrations** card, turn on **Notion destination** and pick one.

## Retrying

If a delivery fails or only part of a long page arrived, open the recording's **Integrations…** action to send it again. See [Queue & Recovery](../history/queue-recovery.md#retry-an-integration). Retrying never creates a second page: dBrief finds the page it already started (by its `ref` code) and only adds what's missing.

## Privacy

The content you choose is sent to Notion over the internet, under your Notion workspace.
