# Using Profiles

How to select, edit, and switch between meeting profiles.

> **Requires:** Power User Mode enabled in **Settings → General**.

## Selecting a profile for a recording

When you stop a recording, the post-recording sheet shows a profile selector. Choose the profile that fits the meeting before clicking **Done**.

## Setting a default profile

In **Settings → Profiles**, you can set any profile as your default. The default is used when no automatic matching rule selects another profile.

## Editing a profile

1. Go to **Settings → Profiles**
2. Select the profile you want to edit
3. Configure overrides — leave any setting blank to inherit from global settings

> **Note:** The Default profile cannot be deleted or renamed.

## Creating a custom profile

1. Go to **Settings → Profiles**
2. Click **Add Profile**
3. Give it a name and configure your overrides

## How overrides resolve

When a recording uses a profile, settings resolve in this order:
1. Profile override (if set)
2. Global app setting

So if a profile doesn't override the AI engine, the globally selected AI engine is used.

## Automatic matching

Configure matching rules in **Settings → Profiles** to select profiles based on the recording title, call app, calendar details, or attendee email domain. The post-recording sheet shows why a profile matched. You can override the selection manually before continuing.

## Choose what happens after recording

Each profile can keep the review screen open (the default), process automatically, or queue automatically. Automatic actions have a cancellable ten-second countdown, giving you time to review the title, participants, and selected profile.

Queued work is managed in [Queue & Recovery](../history/queue-recovery.md).
