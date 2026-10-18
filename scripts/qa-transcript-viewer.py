#!/usr/bin/env python3
"""Create disposable, synthetic dBrief viewer fixtures under /tmp.

This script writes real PCM WAV audio and the app's existing JSON sidecars. It
does not launch dBrief, write preferences, or touch any files outside its output
directory. Existing files are not deleted; only the named QA fixture files are
created or replaced.
"""

from __future__ import annotations

import argparse
from array import array
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import re
import sys
import wave
import uuid


DEFAULT_OUTPUT = Path("/tmp/dbrief-transcript-viewer-qa")
SAMPLE_RATE = 16_000
SPEAKERS = [
    ("speaker-1", "Alex Morgan"),
    ("speaker-2", "Samira Khan"),
    ("speaker-3", "Chris O'Neill"),
    ("speaker-4", "Jordan Lee"),
]


SUMMARY_TOPICS = [
    ("Purpose and scope", "The participants agreed to review a fictional transcript workspace using only generated words and a generated tone recording. The exercise focuses on how a person reads, searches, edits, and compares meeting information, rather than on evaluating an AI model or making product claims."),
    ("Meeting navigation", "The recording title, meeting date, and duration should remain easy to find while someone moves between Summary, Transcript, Actions, and Meeting Insights. Each tab should feel like a different view of one recording, with the document column keeping a common left and right edge."),
    ("Reading the summary", "This deliberately long summary gives the reviewer enough material to scroll through more than one screen. Paragraphs should remain readable without a fixed-height card cutting them off, and copy should include the complete text even when only part of the summary is visible."),
    ("Transcript structure", "The synthetic transcript contains many separate speaker turns so scrolling, selection, speaker labels, and search can be checked in a realistic list. Every sentence is fabricated for this review and is not a quotation from a real meeting or a real person."),
    ("Search and selection", "A reviewer should be able to search for a recurring phrase, move between its matches, and select transcript text without losing the current result. Search navigation should keep its current recording context and should not recreate the assistant conversation or reset audio playback."),
    ("Speaker identity", "Four invented speaker names make the speaker legend and color mapping visible. The same speaker should keep the same color in transcript labels, waveform bars, and the legend; changing a display name should not silently assign a different color."),
    ("Gaps in the recording", "Several transcript intervals leave intentional silence between turns, including longer pauses between discussion blocks. The waveform should show those gaps neutrally, and the visualizer should not stretch one speaker across a pause simply because another speaker spoke before it."),
    ("Overlapping speech", "Some transcript intervals intentionally overlap to represent two people speaking at once. The viewer should keep both transcript entries visible and avoid inventing one exclusive speaker for the overlapped waveform region."),
    ("Audio controls", "The generated WAV contains a deterministic low-volume tone, not speech. It provides a valid playable recording for seeking, elapsed-time display, speed controls, and waveform inspection while keeping the fixture independent of user recordings."),
    ("Action ownership", "The action list includes individual tasks and shared tasks assigned to two invented people. A shared task should appear once with both owners shown, and completion should remain attached to the exact raw action text after a view refresh."),
    ("Action completion", "One sample action begins as completed and the others remain unfinished. The reviewer can inspect the selected count, completed grouping, checkbox contrast, and full-list copy behavior without relying on a live service or changing any real sidecar."),
    ("Meeting information", "The metadata sidecar supplies a generated title, participants, duration, and a fictional recording application label. Missing optional values should be omitted or described as unavailable rather than presented as a measured zero or as a fabricated attendee statistic."),
    ("Appearance choices", "Light, Dark, Paper, and Dark Paper should each use their own readable surface and text colors. Non-neon should replace brand gradients with the chosen accent while leaving the four speaker identities distinct."),
    ("Accent readability", "The accent is intentionally purple so it can be checked against each surface. Review the actual text contrast for controls and selected states, then repeat with the black and white accent examples in the dedicated appearance controls."),
    ("Reading preferences", "The display controls should expose the supported font, size, density, and speaker-name choices. Default should follow the selected appearance's intended system font behavior, while explicit reading choices remain selected when the appearance changes."),
    ("Keyboard and accessibility", "New controls should have clear accessibility names, values, and focus order. The reviewer should be able to use keyboard activation, Escape to dismiss transient UI, and VoiceOver without relying on color alone to identify speakers or completion state."),
    ("Layout resilience", "The same content should remain usable at the narrow and wide window sizes in the approved design. The assistant and library panes should resize independently, the document should shrink to available space, and tools may wrap when the window becomes narrow."),
    ("Assistant behavior", "The assistant column is a separate panel that may open or close beside the meeting. Switching tabs should preserve its conversation and draft, while the close controls and resize handle should remain reachable when the window is resized."),
    ("Persistence boundaries", "The review should use a distinct local app identity and the disposable fixture directory. The app must not write fixture data into production recordings or read a real recording folder for its screenshots."),
    ("Failure handling", "A later review can add separate missing, corrupt, or unwritable sidecar fixtures. The viewer should communicate those states through its existing error path and retry actions without replacing user-owned data or claiming a failed save succeeded."),
    ("Acceptance evidence", "Screenshots from this fixture can demonstrate layout and appearance only. They do not prove VoiceOver operation, long-list memory behavior, data migration, recording recovery, or real speech playback; those behaviors need their own native checks."),
    ("Closeout", "The reviewer should record which modes, widths, tabs, and interaction states were actually inspected. Leave any untested item marked pending, retain the screenshots for review, and keep test evidence separate from release or distribution approval."),
]


TRANSCRIPT_TOPICS = [
    "The title and meeting context should stay close to the document tabs so a person can confirm which recording is open.",
    "The summary needs enough vertical room to show a complete discussion without hiding the final paragraphs behind a fixed card.",
    "The transcript should preserve its speaker turns, timestamps, and stable row identity while the reviewer scrolls through it.",
    "The search field should find this phrase and allow the next result to be selected without resetting the current tab.",
    "The waveform should leave a quiet neutral interval where the transcript has a gap between these two turns.",
    "Two people may speak at the same time, so an overlapping interval should remain visibly ambiguous in the waveform.",
    "The assistant panel should be independent of the document and keep its draft when another tab is selected.",
    "The display popover should keep the selected typeface, reading size, density, and speaker-name option easy to adjust.",
    "Shared action ownership should use one card that names both people and keeps the raw completion key unchanged.",
    "The same speaker color should continue through the transcript row, waveform, and speaker legend.",
    "A keyboard user should be able to move focus through the controls in a logical order and activate each one.",
    "The wide window should keep the document column centered while the library and assistant panels resize.",
    "At a narrow width, the tab tools may wrap, but reading text should not shrink or scroll sideways.",
    "A missing optional calendar value should be omitted instead of being presented as a confident fact.",
    "The generated tone is only a playback fixture and should never be mistaken for a voice recording.",
    "The complete action list should be available to copy even when some cards are below the visible area.",
    "Changing the appearance should adapt the surrounding native controls as well as the document surface.",
    "Non-neon should remove the brand gradient while preserving the separate colors assigned to each speaker.",
    "A completed checkbox should remain checked after the summary is saved and the viewer reloads the sidecar.",
    "The reviewer should distinguish missing transcript data from a real transcript that contains no spoken words.",
]

FOLLOW_UPS = [
    "The team will compare the result against the approved interaction reference before recording a decision.",
    "A second pass will check the same control with the assistant open and with the library pane collapsed.",
    "The observation should be recorded as pending until the native application has been inspected directly.",
    "The example is synthetic, so the review should focus on layout and state rather than transcription accuracy.",
    "Any failure should be captured with its visible error state and left unchanged until the owner reviews it.",
    "The group will keep this behavior consistent across the four tabs and the two side panels.",
]


def safe_output_directory(raw: str) -> Path:
    temp_root = Path("/tmp").resolve()
    candidate = Path(raw).expanduser().absolute().resolve()
    if candidate == temp_root or temp_root not in candidate.parents:
        raise SystemExit(f"Refusing to write outside a dedicated /tmp subdirectory: {candidate}")
    return candidate


def word_count(text: str) -> int:
    return len(re.findall(r"\b[\w’'-]+\b", text, flags=re.UNICODE))


def build_summary() -> str:
    sections = []
    for index, (heading, detail) in enumerate(SUMMARY_TOPICS, start=1):
        expansion = (
            f"For this scenario, the reviewer should inspect {heading.lower()} in the selected appearance,"
            " then repeat the same observation at a second window size. The expected result is a clear"
            " presentation of the recording's actual stored content, with no invented fields and no"
            " hidden controls. If a value is unavailable, the interface should make that boundary clear."
        )
        sections.append(f"## {index:02d}. {heading}\n\n{detail} {expansion}")

    summary = "\n\n".join(sections)
    while word_count(summary) < 1_300:
        next_index = len(sections) + 1
        heading, detail = SUMMARY_TOPICS[(next_index - 1) % len(SUMMARY_TOPICS)]
        sections.append(
            f"## {next_index:02d}. Follow-up on {heading.lower()}\n\n"
            f"The participants return to {heading.lower()} and describe one more review case. {detail} "
            "They will compare the visible content with the saved recording, note the exact state they tested, "
            "and leave anything they did not inspect marked as pending."
        )
        summary = "\n\n".join(sections)
    return summary


def write_json(path: Path, payload: object) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def write_wav(path: Path, duration_seconds: float) -> None:
    frames = array("h")
    total_frames = round(duration_seconds * SAMPLE_RATE)
    for index in range(total_frames):
        seconds = index / SAMPLE_RATE
        pulse = 0.30 if math.sin(2 * math.pi * 1.1 * seconds) > -0.20 else 0.06
        tone = math.sin(2 * math.pi * 196 * seconds)
        frames.append(int(7_000 * pulse * tone))
    if sys.byteorder != "little":
        frames.byteswap()

    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(frames.tobytes())


def metadata_payload(stem: str, title: str, duration: float, created: datetime) -> dict[str, object]:
    return {
        "recordingID": str(uuid.uuid4()),
        "dateISO8601": created.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "durationSeconds": duration,
        "meetingTitle": title,
        "masterFileName": f"{stem}.wav",
        "segmentFileNames": [],
        "warnings": [],
        "generatedTitle": title,
        "participants": [name for _, name in SPEAKERS],
        "calendarAttendees": ["Taylor Reed"],
        "associatedApp": "Synthetic QA fixture",
    }


def create_empty_analysis_fixture(recording_folder: Path) -> None:
    stem = "2026-09-28_1500_viewer-qa-no-analysis"
    duration = 18.0
    audio = recording_folder / f"{stem}.wav"
    write_wav(audio, duration)
    write_json(
        recording_folder / f"{stem}.json",
        metadata_payload(stem, "Synthetic Recording Without Analysis", duration, datetime(2026, 9, 28, 15, 0, tzinfo=timezone.utc)),
    )


def create_long_fixture(recording_folder: Path) -> tuple[Path, int, int, float]:
    stem = "2026-09-28_1530_viewer-qa-long-reading-and-overlap"
    duration = 360.0
    title = "Synthetic Viewer Review — Long Summary, Gaps & Overlap"
    created = datetime(2026, 9, 28, 15, 30, tzinfo=timezone.utc)
    summary = build_summary()

    segments = []
    long_gap_count = 0
    overlap_count = 0
    for index in range(240):
        block = index // 30
        start = 0.8 + index * 1.35 + block * 3.8
        end = start + 1.18
        if index > 0 and index % 29 == 12:
            # Extend the preceding turn across this start to model overlap.
            segments[-1]["end"] = round(start + 0.34, 3)
            overlap_count += 1
        if index > 0 and index % 30 == 0:
            long_gap_count += 1
        speaker_id, _ = SPEAKERS[index % len(SPEAKERS)]
        topic = TRANSCRIPT_TOPICS[index % len(TRANSCRIPT_TOPICS)]
        follow_up = FOLLOW_UPS[(index // len(TRANSCRIPT_TOPICS)) % len(FOLLOW_UPS)]
        variation = (
            f"Example turn {index + 1} keeps this sentence distinct for scrolling and search. "
            "The expected behavior is visible in the saved content, not supplied by a network request. "
        )
        text = f"{topic} {variation}{follow_up}"
        segments.append({
            "id": str(uuid.uuid4()),
            "start": round(start, 3),
            "end": round(end, 3),
            "text": text,
            "originalText": text,
            "tokens": [],
            "speakerId": speaker_id,
            "isStarred": index in {11, 73, 148, 221},
            "isEdited": index in {27, 96, 183},
        })

    # Keep all transcript intervals within the generated audio duration.
    last_end = max(segment["end"] for segment in segments)
    if last_end > duration:
        raise RuntimeError(f"Transcript end {last_end}s exceeds WAV duration {duration}s")

    labels = [
        {"id": speaker_id, "displayName": name, "personId": None}
        for speaker_id, name in SPEAKERS
    ]
    rich_transcript = {
        "version": 1,
        "segments": segments,
        "speakerLabels": labels,
        "meSpeakerId": "speaker-1",
    }

    actions = [
        "[Alex Morgan] Send the updated review notes before Friday",
        "[Samira Khan/Chris O'Neill] Check keyboard focus and VoiceOver labels",
        "[Chris O'Neill] Compare all four document tabs at the narrow width",
        "[Jordan Lee] Verify gaps and overlapping turns against the neutral waveform regions",
        "[Alex Morgan/Samira Khan] Record the acceptance result after the visual review",
    ]
    insights = {
        "version": 1,
        "summary": summary,
        "actionItems": actions,
        "completedActionItems": [actions[0]],
        "tags": ["synthetic QA", "transcript viewer", "accessibility", "playback"],
        "sentiment": "Neutral",
        "generatedTitle": title,
        "markdownPath": None,
        "basedOnPreviousTranscript": False,
        "modelProvenance": None,
    }

    audio = recording_folder / f"{stem}.wav"
    write_json(recording_folder / f"{stem}.json", metadata_payload(stem, title, duration, created))
    write_json(recording_folder / f"{stem}.richtranscript.json", rich_transcript)
    write_json(recording_folder / f"{stem}.insights.json", insights)
    write_wav(audio, duration)
    return audio, word_count(summary), len(segments), last_end


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="Dedicated output folder (must be under /tmp).")
    args = parser.parse_args()

    output_root = safe_output_directory(args.output)
    isolated_home = output_root / "isolated-home"
    recording_folder = isolated_home / "Documents" / "dBrief" / "Recordings" / "2026-09"
    recording_folder.mkdir(parents=True, exist_ok=True)

    # Create the no-analysis row first so the long fixture is newest in the library.
    create_empty_analysis_fixture(recording_folder)
    audio, summary_words, segment_count, transcript_end = create_long_fixture(recording_folder)

    print(json.dumps({
        "output_root": str(output_root),
        "isolated_home_candidate": str(isolated_home),
        "recording_folder": str(recording_folder),
        "long_fixture_audio": str(audio),
        "summary_word_count": summary_words,
        "rich_transcript_segments": segment_count,
        "transcript_final_time_seconds": transcript_end,
        "audio_format": "WAV PCM, mono, 16-bit, 16000 Hz; generated tone, not speech",
        "additional_fixture": "Synthetic Recording Without Analysis",
        "preferences_written": False,
        "app_launched": False,
    }, indent=2))


if __name__ == "__main__":
    main()
