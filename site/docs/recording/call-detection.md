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

In **Settings → Meetings → Call detection**:

- **Notice when a call starts** — turn the feature on or off.
- **When a call starts** — choose **Ask me** to show a prompt, or **Record automatically** to start recording as soon as a call is detected.
- **Dismiss the prompt after** — when you're using the prompt (**Ask me**), choose how long it stays on screen before dismissing itself: Never (the default), or after 10/15/30/60 seconds. Clicking the prompt cancels the timer, so it never disappears while you're deciding.
- **When a call ends** — what dBrief does once your meeting wraps up:
  - **Do nothing** — keep recording until you stop it yourself.
  - **Ask me** (the default) — show a prompt asking whether to stop the recording.
  - **Stop automatically** — stop the recording on its own.
- **Apply to** — which recordings the "when a call ends" behaviour applies to:
  - **Only recordings started for a call** (the default) — dBrief acts only when the meeting it's tracking is the one that started the recording.
  - **Any active recording** — dBrief acts when any watched meeting app ends, whatever started the recording.

dBrief detects a call ending by watching the meeting app's own microphone use, so leaving a Teams/Zoom/Slack/Meet meeting is noticed even if you leave the app open. A brief pause — muting yourself or switching audio devices — won't trigger it; only actually leaving the meeting does. (Detecting a call *ending* needs macOS 14.2 or later; on older versions dBrief only notices when the meeting app fully quits.)

## Choosing which apps to watch

With call detection on, an **Apps to watch** card appears in **Settings → Meetings**. Toggle off any app you don't want dBrief to react to — for example, if you use Slack for messages but never for calls.

## Calendar context

When a call is detected (or you start recording manually), dBrief can pull the matching event from your calendar to pre-fill the meeting title and participants. See [Calendar Integration](calendar.md).
