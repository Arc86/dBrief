# Menu bar panel restyle — design reference

Status: inspected design; implementation not started.

## Source

Pen document: `/Users/jesper.mol/.pencil/documents/9cd04b7e-e528-4f6e-8da3-c8cae6cd2fb4/pencil-new.pen`.
Read through Pen MCP; do not read the encrypted file with filesystem tools.

| State | Light frame | Dark frame | Canvas dimensions |
|---|---|---|---|
| Idle / recent recordings | `w4EU9` | `IC2GS` | 450 × 799 |
| Recording | `sUu5f` | `JuhXW` | 450 × 710 |
| Recording complete | `b65oAI` | `bdnji` | 450 × 900 |
| Output | `A5FmqI` | `gWX10` | 450 × 799 |

The user requested a plan before execution. Other canvas frames describe the meeting viewer; those are outside this restyle.

## Appearance

Panel: width 450, outer padding 20, section gap 12, corner radius 22. Header: height 42, icon 34, title 17 / bold. Content width: 410. Canvas heights communicate composition, not fixed runtime window heights.

| Role | Light | Dark |
|---|---|---|
| Panel | `#F9FBFE` | `#0D1423` |
| Card / queue | `#FFFFFF` | `#121A2B` |
| Secondary button | `#E9EDF3` | `#1A2538` |
| Field / transcript surface | `#F0F3F7` | `#182337` |
| Expanded recording | `#EDF4FF` | `#142A4B` |
| Primary text | `#0B1430` | `#F4F7FC` |
| Secondary text | `#31405F` | `#C5CEDD` |
| Muted text | `#6D7892` | `#8D99AE` |
| Hairline | `#E1E7F0` | `#273349` |
| Blue icon / solid accent | `#1268F5` | `#4C8DFF` |
| Positive status | `#16B364` | `#4CCB8A` |
| Stop surface | `#FFF0F3` | `#42202A` |
| Stop text | `#FF4567` | `#FF6B86` |

Primary button gradient: `#155EEF` → `#2E8DFF`. Waveform gradient: `#8B5CF6` → `#2E8DFF`. Warning: `#F59E0B`. Light destructive action: `#E5484D`, white label. The logo keeps its existing multicolor identity; the primary button changes to blue.

Fonts in the mockups are Inter. Proposed native translation: system sans with equivalent sizes/weights, monospaced digits for timer. Do not introduce a font dependency unless the user specifically requests exact Inter typography.

## State composition

1. Idle: header; capture card (profile row + Record meeting button with shortcut badge); Open meeting viewer; Recent recordings; Queue & Recovery; two import buttons; footer.
2. Recording: header with Recording status; timer / REC; waveform; Pause and Stop; microphone and system audio; optional output folder; viewer; queue; disabled import actions; footer. No recent-recording list.
3. Recording complete: header; recording-specific profile context; complete status / profile selector / metrics; title; participants; processing options; optional output folder; Delete / Skip / Queue / Process; footer. Capture, history, queue and import sections are replaced by review content.
4. Output: header; capture card; Meeting notes title / duration / real completion status; collapsible output; Copy notes / Open file / Transcript / Done; viewer; queue; imports; footer.

Design measurements: capture card radius 14 / padding 12; profile selector 156 × 34 / radius 9; Record button height 54 / radius 12; viewer button height 46 / radius 12; recent header 40; selected row radius 14, play circle 40, collapsed play circle 36; recent action buttons height 34; queue collapsed height 58 / radius 12; imports height 42 / radius 10; footer height 30; recording timer 42; waveform height 58; pause/stop height 58 / radius 14; output card radius 12; output actions height 40 / radius 9; review actions height 52 / radius 10.

## Runtime adaptations

- Height follows real content and available display space. Scroll overflow on small displays instead of forcing a 900-point window; keep review actions reachable.
- Mockup data (titles, counts, timings, queue warnings, participants, folder path) is illustrative. Render real state and preserve existing availability conditions.
- Retain additional existing functionality: calendar suggestions and automation countdown, participant loading, integration destinations, recovery messages, error copy/dismiss, retry/cancel, playback progress, YouTube entry and queue controls.
- Paused and processing screens are not separately drawn. Derive their appearance from recording/output frames while retaining existing labels, operations and state transitions.
- Match the explicit dark frames to system appearance. Reduce motion disables pulsing; calm appearance flattens gradients/removes decorative shadows. Retain accessible focus, native text editing and system menus.
- Preserve menu-bar icon behavior and command shortcuts. Keep changes scoped to the panel and its child views.
