# Call Detection

dBrief can watch for meeting apps and automatically start recording when a call begins — and stop when it ends — or just be ready and let you decide.

## Supported apps

dBrief recognises these meeting apps:

- Zoom
- Microsoft Teams (classic and new)
- Slack
- Webex
- FaceTime
- Google Meet (in Chrome)

## How it works

When a supported app is running and your microphone becomes active, call detection fires.

## Settings

In **Settings → General → Call Detection**:

- **Enable call detection** — turn the feature on or off.
- **Auto-start recording when call detected** — when on, dBrief starts recording automatically as soon as a call is detected. When off, detection still runs but won't start a recording on its own.
- **Auto-dismiss prompt** — when you're using the prompt (i.e. auto-start is off), choose how long it stays on screen before dismissing itself: Never (the default), or after 10/15/30/60 seconds. Clicking the prompt cancels the timer, so it never disappears while you're deciding.
- **When a call ends** — what dBrief does once your meeting wraps up:
  - **Do nothing** — keep recording until you stop it yourself.
  - **Ask me** (the default) — show a prompt asking whether to stop the recording.
  - **Stop automatically** — stop the recording on its own.
- **Apply to** — which recordings the "when a call ends" behaviour applies to:
  - **Only recordings a call started** (the default) — dBrief acts only when the meeting it's tracking is the one that started the recording.
  - **Any active recording** — dBrief acts when any watched meeting app ends, whatever started the recording.

dBrief detects a call ending by watching the meeting app's own microphone use, so leaving a Teams/Zoom/Slack/Meet meeting is noticed even if you leave the app open. A brief pause — muting yourself or switching audio devices — won't trigger it; only actually leaving the meeting does. (Detecting a call *ending* needs macOS 14.2 or later; on older versions dBrief only notices when the meeting app fully quits.)

## Choosing which apps to watch

With call detection enabled, a **Call Platforms** list appears in **Settings → General**. Toggle off any app you don't want dBrief to react to — for example, if you use Slack for messages but never for calls.

## Calendar context

When a call is detected (or you start recording manually), dBrief can pull the matching event from your calendar to pre-fill the meeting title and participants. See [Calendar Integration](calendar.md).
