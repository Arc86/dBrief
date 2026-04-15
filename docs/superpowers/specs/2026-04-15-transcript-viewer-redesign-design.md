# Transcript Viewer Redesign — Design Spec

**Date:** 2026-04-15
**Scope:** Transcript viewer window (Transcript, Segments, Chat tabs)
**Status:** Approved

---

## Goal

Replace the current plain-list transcript UI with a premium macOS-native aesthetic — frosted glass surfaces, consistent speaker pill components, and merged speaker turns. The design must adapt to system light/dark mode without a manual toggle.

This spec also serves as the canonical design language reference for applying the same aesthetic to other surfaces in future (menu bar popover, settings, etc.).

---

## 1. Design Language Tokens

These tokens define the full visual system. All values come in light and dark variants, resolved via SwiftUI's `@Environment(\.colorScheme)`.

### Backgrounds

| Layer | Light | Dark |
|---|---|---|
| Window background | `linear-gradient(145deg, #e8e8ed, #d8d8e0)` | `linear-gradient(145deg, #1c1c2e, #26263a)` |
| Toolbar / tab bar | `rgba(255,255,255, 0.55)` + blur(20) | `rgba(255,255,255, 0.07)` + blur(20) |
| Sidebar | `rgba(255,255,255, 0.35)` + blur(20) | `rgba(0,0,0, 0.20)` + blur(20) |
| Speaker turn card | `rgba(255,255,255, 0.60)` + blur(12) | `rgba(255,255,255, 0.05)` + blur(12) |
| Waveform bar | `rgba(255,255,255, 0.45)` + blur(20) | `rgba(0,0,0, 0.25)` + blur(20) |
| Chat input field | `rgba(255,255,255, 0.60)` + blur(12) | `rgba(255,255,255, 0.08)` + blur(12) |
| Template chip | `rgba(255,255,255, 0.50)` | `rgba(255,255,255, 0.07)` |

### Borders

| Layer | Light | Dark |
|---|---|---|
| Toolbar / tab bar | `rgba(0,0,0, 0.08)` | `rgba(255,255,255, 0.07)` |
| Speaker turn card | `rgba(255,255,255, 0.80)` | `rgba(255,255,255, 0.09)` |
| Sidebar divider | `rgba(0,0,0, 0.07)` | `rgba(255,255,255, 0.06)` |
| Template chip | `rgba(0,0,0, 0.08)` | `rgba(255,255,255, 0.10)` |

### Typography

| Role | Size | Weight | Color (light) | Color (dark) |
|---|---|---|---|---|
| Tab label (active) | 11pt | Semibold (600) | `#1d1d1f` | `rgba(255,255,255, 0.90)` |
| Tab label (inactive) | 11pt | Regular | `rgba(0,0,0, 0.30)` | `rgba(255,255,255, 0.28)` |
| Turn body text | 12.5pt | Regular | `#1d1d1f` | `rgba(255,255,255, 0.88)` |
| Timestamp | 10pt | Regular | `rgba(0,0,0, 0.35)` | `rgba(255,255,255, 0.30)` |
| Section label (sidebar) | 9pt | Bold (700) | `rgba(0,0,0, 0.40)` | `rgba(255,255,255, 0.30)` |
| Secondary label | 10.5pt | Regular | `rgba(0,0,0, 0.50)` | `rgba(255,255,255, 0.35)` |
| Template chip text | 11pt | Regular | `rgba(0,0,0, 0.70)` | `rgba(255,255,255, 0.70)` |

All text uses the system font (`-apple-system` / `.body` / `.caption` in SwiftUI).

### Shape & Depth

- **Card corner radius:** 10pt
- **Card shadow (light):** `.shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 1)`
- **Card shadow (dark):** `.shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 1)`
- **Chip corner radius:** 20pt (fully rounded)
- **Backdrop blur:** 20pt for structural surfaces, 12pt for content cards

### Speaker Accent Colors

Assigned round-robin from the macOS system palette. The same color is used for the pill background in all contexts.

| Index | Name | Hex |
|---|---|---|
| 0 | Red | `#ff453a` |
| 1 | Blue | `#0a84ff` |
| 2 | Orange | `#ff9f0a` |
| 3 | Green | `#30d158` |
| 4 | Purple | `#bf5af2` |
| 5 | Teal | `#5ac8fa` |

---

## 2. Speaker Pill Component

A single reusable component used in transcript cards, segment headers, and the sidebar People list.

**Anatomy:** Solid `accentColor` background, white foreground text, speaker name in all-caps.

**Spec:**
- Font: 9pt, Bold (700)
- Letter spacing: 0.5pt (SwiftUI: `.kerning(0.5)`)
- Padding: 2pt top/bottom, 8pt left/right
- Corner radius: 20pt
- Text: `speakerName.uppercased()`

This component must never vary between surfaces. If the sidebar shows a speaker, it shows this exact pill.

---

## 3. Transcript Tab

**Layout:** Scrollable list of speaker-turn cards, sidebar on the right, waveform player pinned at the bottom.

### Speaker Turn Cards

Consecutive segments from the same speaker are merged into a single turn. The merge boundary resets when the speaker changes.

Each card contains:
1. **Header row:** Speaker pill + timestamp range (e.g. `0:18 – 0:32`), vertically centered
2. **Body:** Full merged text, `lineSpacing: 1.65`, wrapping naturally

Cards have 8pt vertical gap between them and 14pt horizontal/vertical padding inside the scroll area.

### Sidebar

Width: ~130pt. Sections:

**People**
- Section label: "PEOPLE" (uppercase, 9pt bold)
- One row per speaker: pill on the left, edit pencil icon (`✎`) on the right
- Tapping the pill or pencil opens the existing speaker rename popover

**Display**
- Section label: "DISPLAY"
- Font Size stepper
- Speaker Names toggle

### Waveform Bar

Pinned at the bottom. Contains: play/pause button, waveform visualization, current time + playback speed. Uses the waveform bar background token.

---

## 4. Segments Tab

Identical layout and components to the Transcript tab. The only difference is the data source: segments use WhisperKit's raw segment boundaries rather than the full transcript, but are still merged into speaker turns before display.

Merging rule: consecutive segments where `segment.speaker == previousSegment.speaker` (matched by speaker ID, not display name) are combined. Timestamp shows the range from first to last segment in the turn.

---

## 5. Chat Tab

**Layout:** Vertical stack — input field at top, section label, template chip grid, empty conversation area below.

### Input Field

- Full-width, frosted glass card style (card tokens)
- Left icon: sparkle symbol (`✦`), `rgba` dimmed
- Placeholder text: `"Ask anything about this transcript…"`
- Corner radius: 10pt
- Tapping a template chip populates this field

### Template Chips

- Section label: "QUICK TEMPLATES" above the grid
- Chips arranged in a wrapping flow layout. SwiftUI has no built-in wrapping layout; use a custom `FlowLayout` (composable layout protocol) or `LazyVGrid` with `.adaptive(minimum: 100)` columns as a simpler fallback.
- Current templates: Bullet Points, Action Items, Key Points, Questions Asked, Improve Grammar, Generate FAQ, Extract Statistics, Identify Emotions
- Chip style: glass fill, border, fully rounded (20pt), 11pt text

### Conversation Area

Below the chip grid: scrollable area for chat history. Empty state shows a centered sparkle icon + subtitle "Ask anything about this transcript, or pick a template above." Once a conversation starts, messages appear here in a standard chat bubble layout (user right-aligned, assistant left-aligned, both using card tokens).

---

## 6. Implementation Notes

### SwiftUI Mapping

| CSS concept | SwiftUI equivalent |
|---|---|
| `backdrop-filter: blur(N)` | `.ultraThinMaterial` / `.regularMaterial` |
| `rgba(white, 0.05)` fill | Custom `Color` with opacity modifier |
| `@Environment(\.colorScheme)` | Same — use to switch token values |
| `border-radius: 10px` | `.cornerRadius(10)` or `.clipShape(RoundedRectangle(cornerRadius: 10))` |
| Gradient background | `LinearGradient` on the window's root `ZStack` background |

macOS `Material` types (`.ultraThinMaterial`, `.regularMaterial`) provide system-accurate vibrancy and automatically adapt to light/dark mode — prefer these over manual `rgba` fills where possible. Use manual `rgba` only where the material's built-in tint conflicts with the design.

### Segment Merging

The merge step belongs in the view model / data transformation layer, not the view. `RichTranscriptBuilder` (or a new `SpeakerTurnBuilder`) should expose `[SpeakerTurn]` where each turn has `speaker`, `startTime`, `endTime`, and `text`. The view consumes turns, not raw segments.

### Reuse Checklist (for future surfaces)

To apply this design language to a new surface:
1. Use the gradient background tokens on the root container
2. Apply the appropriate material + border combination from the token table
3. Use `SpeakerPillView` (the shared pill component) wherever a speaker is referenced
4. Use SF system font at the specified sizes — no custom fonts
5. Test both `colorScheme` values before shipping
