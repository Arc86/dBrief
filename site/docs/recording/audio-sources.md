# Audio Sources

dBrief records your microphone, and — when it can — mixes in your Mac's system audio (the sound your Mac plays out loud) so remote participants on a call are captured too.

## How dBrief picks sources

There's no manual "mic vs. mixed" switch. dBrief chooses automatically based on permissions:

- **Microphone + system audio (mixed)** — used when **Screen Recording** permission is granted. macOS requires this permission to capture system audio. This captures both your voice and everything your Mac plays, including remote participants, shared audio, and video playback.
- **Microphone only** — used as a fallback when Screen Recording permission isn't granted.

To capture remote participants on a Zoom, Teams, or other call, grant **Screen Recording** permission (see [Permissions](../reference/permissions.md)).

## Input device

Choose which microphone dBrief records from in **Settings → Recording → Audio Input**. Leave it on **System Default** to follow your Mac's current input device, or pick a specific one. Use **Refresh device list** if you've just plugged in a new device.

### Switching device mid-recording

You can change the microphone **while a recording is in progress** — useful if you plug in headphones or a USB mic partway through. Click the **Mic** chip in the recording controls and pick a different input device. dBrief switches the live input without interrupting the recording, keeping a single continuous track (it converts the new device's audio to match the recording's format when needed).

## Echo cancellation

**Settings → Recording → Echo Cancellation** has a **Remove meeting audio from microphone** toggle. It's recommended when using laptop speakers: it uses the captured system audio as a reference to suppress speaker bleed picked up by your mic. When recording mic-only, it falls back to macOS real-time voice processing.

## Technical details

Recordings are captured per track (mic and system audio separately) and mixed down to a single **M4A / AAC** file at 48 kHz stereo, with light post-processing (high-pass filtering, ducking, and loudness normalization). You can review these details under **Settings → Recording → Audio Quality** with Power User Mode enabled.
