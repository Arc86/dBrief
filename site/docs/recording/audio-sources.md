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

### Automatic device follow

dBrief also adapts on its own when your audio devices change mid-recording, so you never silently lose your voice:

- If your selected microphone **disappears** (e.g. AirPods run out of battery or disconnect), dBrief automatically falls back to the system default input and keeps recording.
- If you're on **System Default**, it follows the new default device when you connect one.
- A microphone you've explicitly picked stays selected as long as it's still connected.

When an automatic switch happens, a brief note appears in the floating recorder (e.g. "Switched to MacBook Pro Microphone") so you know what changed. This works alongside the manual **Mic** chip — both share the same seamless, single-track switch.

## Echo cancellation

**Settings → Recording → Echo Cancellation** has a **Remove meeting audio from microphone** toggle. It's recommended when using laptop speakers: it uses the captured system audio as a reference to suppress speaker bleed picked up by your mic. When recording mic-only, it falls back to macOS real-time voice processing.

> **Headphones & earphones:** when your audio output is headphones, earphones (including AirPods), or any non-built-in device, there's no speaker bleed to cancel, so dBrief **automatically skips** echo cancellation — even with the toggle on. This keeps the audio you hear at full volume (real-time voice processing would otherwise duck output and lower the level). dBrief re-checks the output route **continuously during recording**: switch from speakers to headphones (or back) mid-recording and echo cancellation turns off or on to match, automatically.

## Technical details

Recordings are captured per track (mic and system audio separately) and mixed down to a single **M4A / AAC** file at 48 kHz stereo, with light post-processing (high-pass filtering, ducking, and loudness normalization). You can review these details under **Settings → Recording → Audio Quality** with Power User Mode enabled.
