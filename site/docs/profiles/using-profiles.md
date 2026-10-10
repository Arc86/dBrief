# Using Profiles

How to select, edit, and switch between meeting profiles.

Profiles live on the **Profiles** page in Settings (in the **Deliver** group of the sidebar).

## Selecting a profile for a recording

Before you record, pick a profile from the **Profile** menu under the Record button in the menu bar panel.

When you stop a recording, the post-recording sheet uses that profile. To change it for this recording only, open **Processing settings** and choose another **Profile**, then click **Process recording**.

## Setting the active profile

In **Settings → Profiles**, right-click a profile and choose **Make Active**, or select it and click **Use as saved profile**. The active profile is used when no automatic matching rule selects another profile.

The **Settings → After recording** page shows the active profile in its **Active profile** card. Click **Edit in Profiles** to open it.

## Editing a profile

1. Go to **Settings → Profiles**
2. Select the profile you want to edit
3. Turn on only the overrides you need in the **Transcription**, **AI analysis**, **Task defaults** and **Folders** cards. Anything you don't override uses the app default.

Selecting a profile to edit doesn't make it the active profile.

> **Note:** The Default profile cannot be deleted.

## Creating a custom profile

1. Go to **Settings → Profiles**
2. Click **Add profile** (**+**) under the profile list
3. Give it a name and configure your overrides

You can also right-click a profile and choose **Duplicate** to start from a copy.

## How overrides resolve

When a recording uses a profile, settings resolve in this order:
1. Profile override (if set)
2. Global app setting

So if a profile doesn't override the AI engine, the globally selected AI engine is used.

## Automatic matching

In **Settings → Profiles**, use the **Automatic selection** card to select a profile based on the recording title, call app, calendar details, or attendee email domain. The post-recording sheet shows why a profile matched. You can override the selection manually before continuing.

## Choose what happens after recording

Each profile's **After recording** card sets the **Action**: **Review before processing** (the default), **Process automatically**, or **Queue automatically**. Automatic actions have a cancellable ten-second countdown, giving you time to review the title, participants, and selected profile.

Queued work is managed in [Queue & Recovery](../history/queue-recovery.md).
