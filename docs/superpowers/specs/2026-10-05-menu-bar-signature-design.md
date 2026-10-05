# Menu Bar "Signature" — Design Translation

**Source:** Pencil document `pencil-new.pen`, frames `Signature · Light · *` and `Signature · Dark · *`
(12 states × 2 schemes, 390 pt wide artboards, 360 pt panel card).
**Supersedes:** `docs/superpowers/plans/2026-09-28-menu-bar-panel-restyle.md` (built for the older
"dBrief Menu Bar Panel" frames `w4EU9`/`sUu5f`/`b65oAI`/`A5FmqI`; never implemented).
**Branch:** `ui/redesign`.

## 1. The one key finding

The Signature frames are drawn **with the Transcript Viewer's palette, value for value**:

| Pen value (light / dark) | Viewer token (`ViewerThemeResolver`) |
|---|---|
| `#FBFCFE` / `#1B2029` — footer, control fills | `canvas` |
| `#FFFFFF` / `#242C38` — panel card | `surface` |
| `#0B1430` / `#F0F3FA` — titles | `heading` |
| `#31405F` / `#D2DAE8` — body, button labels | `text` |
| `#65718A` / `#A3AFC4` — captions, meta | `secondary` |
| `#E1E7F0` / `#3A4658` — hairlines, control borders | `divider` |
| `#1268F5` / `#3880F7` — Record button, level bars | `primary` (dark = accent mixed 16 % white) |
| `#FFFFFF` — Record label | `onPrimary` |
| `#FF4B65 … #00C8FF` — logo bars, gradient borders | `brandStops` |

So the menu needs **no new base palette**. It reads `\.viewerPalette`, which `AppAppearanceScope`
already injects into the `MenuBarExtra`, the mini player and the call popups. That gives us, for free:

- **Paper and Dark Paper** (the Pen file has none): the same roles resolve to the paper tokens.
- **Configurable accent**: the Record button, level bars and accent borders follow `viewerAccentHex`.
- **Reduce neon**: `brandStops` collapse to the accent, so the logo bars and gradient borders go flat.

## 2. New semantic tokens (the only additions)

The frames use a few status colours the viewer palette does not have. They go in one pure resolver,
`MenuPanelPalette.resolve(mode:base:)`, next to `ViewerPalette`.

| Role | Light (Pen) | Dark (Pen) | Paper (new) | Dark Paper (new) | Used for |
|---|---|---|---|---|---|
| `success` | `#23804C` | `#7BDCAA` | `#3D7046` | `#9BD3A4` | Ready dot, "Analyzed", Mic/System audio, done steps |
| `danger` | `#B93852` | `#FF91A6` | `#A63A3A` | `#F2A08F` | Stop/Delete labels, "Recording" label + dot |
| `dangerFill` | `#FFF2F5` | `#382935` | `#F8EAE3` | `#3D2C27` | Stop/Delete/confirm backgrounds |
| `dangerBorder` | `#D5B3C1` | `#755C6F` | `#D9B2A8` | `#7A564C` | Stop/Delete/confirm borders |
| `warning` | `#E0A21B` | `#E0A21B` | `#C08A2E` | `#D9A54A` | Memory bar, "needs attention" |
| `accentBorder` | derived | derived | derived | derived | Play circles, "Record call" outline: `primary` mixed 50 % into `surface` |
| `successFill` | derived | derived | derived | derived | Recovery banner: `success` mixed 95 % into `surface` |

**Deliberate deviation:** Pen draws the light "Recording" label as `#D7415C`, which is 4.4:1 on white
(fails AA). We use `danger` (`#B93852`, 5.6:1). Every text role must reach 4.5:1 on `surface` in all four
modes; a unit test enforces this.

## 3. Panel anatomy (all states)

```
┌──────────── 360 pt card, radius 18, 1 pt divider border, surface fill ────────────┐
│ header  58 pt · padding 16 · bottom hairline                                       │
│   [logo bars 23×24] dBrief (17/650 heading)  ● status (12/regular secondary)        │
├────────────────────────────────────────────────────────────────────────────────────┤
│ section  padding 14 v / 16 h · gap 10 · bottom hairline (full bleed)               │
│ section …                                                                          │
├────────────────────────────────────────────────────────────────────────────────────┤
│ footer  45 pt · canvas fill · padding 10/16   ⚙ Settings…            Quit dBrief    │
└────────────────────────────────────────────────────────────────────────────────────┘
```

- Sections are **flat strips split by full-bleed hairlines**, not nested cards. No `Divider()`s inside.
- Typography: system font through `.uiFont(...)` (respects the user's UI typography preference). The
  Pen frames say Helvetica Neue/Inter only because they were imported from HTML.

### Components

| Component | Spec |
|---|---|
| `BrandBarsMark` | 5 bars, 3 pt wide, gap 2, radius 2, heights 9/18/24/15/7, colours = `brandStops[1...5]` |
| Hero button (Record meeting, Process recording) | height 58 (Process: 44), radius 11, `primary` fill, `onPrimary` 18/650 label, 20 pt record glyph |
| Secondary button | height 33–35, radius 8, `surface` fill, `divider` border, `text` 12–13/500 label, 16 pt icon |
| Row button (Transcript viewer) | height 36, radius 8, `canvas` fill, `divider` border, leading icon, trailing `arrow.up.right` |
| Danger button (Stop, Delete) | as secondary with `dangerFill` / `dangerBorder` / `danger` label |
| Accent-outline button (Record call) | `surface` fill, 1.5 pt `primary` border, `heading` label |
| Brand-outline button (View transcript on Brief ready) | existing `ViewerBrandButtonStyle`, height 40 |
| Selector (Profile, Mic, Meeting) | height 28, radius 7, `canvas` fill, `divider` border, `chevron.down` |
| Section header | `chevron.right/down` + title 13/600 heading + count 11 secondary + 28 pt refresh icon button |
| Recording row | 30 pt play circle (`surface` fill, `accentBorder` stroke, `primary` glyph) · title 13/500 · meta 11 secondary + status (`success` for Analyzed) · chevron up/down |
| Action tile | 3 columns × 2 rows, height 47, radius 8, icon over 11/500 label; Delete tile uses danger roles |
| Level bars | 3 pt bars, gap 3, radius 2, `primary`, 37 pt tall (mini player 26 pt), driven by `peakLevel` |

## 4. States

| # | Frame | What changes vs today |
|---|---|---|
| 01 | Meeting detector (`CallDetectedPopup`) | Card with brand-gradient 1.5 pt border, logo bars, title 16/600, caption, close ✕, "Not now" + accent-outline "Record call" with mic icon |
| 02 | Mini player (`FloatingMiniPlayer`) | Header strip on `canvas` (logo, dBrief, ● Recording, 0:15, collapse chevron), level bars, Pause / danger Stop |
| 03 | Ready | Hero Record button; Profile selector + hotkey hint on one row; Transcript viewer row; collapsed Recent recordings + Queue & Recovery; import row; footer |
| 04 | Recent recording actions | Expanded row shows a fixed 3×2 tile grid: Copy summary, Show in Finder, Reprocess / Transcript, Integrations, Delete. Unavailable actions are **disabled tiles**, so the grid never reflows |
| 05 | Queue and recovery | Empty state: tray icon, "No pending work", caption. *Pen also shows "Pause queue" — not implemented (no backing behaviour); see Out of scope* |
| 06 | Video URL import | Inline panel under the import row: title + ✕, URL field, accent "Go" (disabled tint when empty), status caption |
| 07 | Recording | Timer 30/600 + "Recording" (danger), level bars, Pause / danger Stop, Mic selector (success) + System audio (success), Obsidian folder + Choose…, import buttons disabled. No Profile row |
| 08 | Recording completed | Centered title 22/650 + meta (duration · size · 📅 Calendar linked); Meeting details + Refresh; meeting selector + "Updated at"; Calendar attendees; Participants token box; **Processing settings row** (profile · N tasks selected ›) replaces the inline checkbox list; hero "Process recording"; output-folder caption; Keep audio only / Queue / ••• |
| 09 | Long title, 6 participants | Title wraps to max 3 lines then truncates (tooltip = full title); participant tokens wrap; panel scrolls; footer stays pinned |
| 10 | Delete confirmation | Bottom action area is replaced in place by a danger card: title, explanation, Cancel / filled-danger Delete |
| 11 | Processing | Recovery banner (`successFill`, ✕); "Processing recording" + "n of m done"; step list (✓ success / spinner primary / empty circle pending / ✕ danger failed); engine caption; Stop (danger) + View transcript |
| 12 | Brief ready | Title + date · duration + ✓ "Summary · Actions · Tags · Notes"; Summary paragraph; "More details" disclosure (existing action items / tags); brand-outline View transcript; Copy notes / Open file; recovery note row; "Dismiss brief" text button |

## 5. Decisions taken (flag if wrong)

1. **Footer everywhere.** Frames 03–10 have the "Settings… / Quit dBrief" footer; 11–12 show a header
   gear instead. We use the footer in every state and drop the header gear menu (keeps ⌘, and ⌘Q).
2. **Pending steps show an empty circle,** not the spinner Pen draws on all three unfinished steps;
   only the running step spins.
3. **"Skip" becomes "Keep audio only"** (same handler). "•••" holds Delete recording.
4. **Panel width is fixed at 360 pt** (today: min 340 / ideal 360).

## 6. Out of scope

- **Pause queue** (05): needs a new queue-paused state in `RecordingManager`; separate ticket.
- **Memory meter "12.7 / 16 GB"** (11): needs a memory-usage reader; keep today's "Low RAM" tag, restyled.
- Onboarding, Settings, Speaker review window, CallEndedPopup (follows 01's styling only if trivial).
- Any change to recording, processing, queue or calendar behaviour.
