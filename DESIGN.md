---
name: dBrief website
description: A calm Mac-app window shown as a website, in the app's own four themes.
colors:
  accent: "#1268F5"
  accent-fill-dark: "#3171D6"
  canvas: "#FBFCFE"
  surface: "#FFFFFF"
  band: "#F3F6FB"
  divider: "#E1E7F0"
  heading: "#0B1430"
  text: "#31405F"
  secondary: "#65718A"
  accent-text: "#105CD9"
  selected: "#DAE7FD"
  ok: "#23793A"
  paper-canvas: "#F5F2EB"
  paper-surface: "#FFFCF5"
  paper-heading: "#302D28"
  paper-text: "#514B42"
  paper-secondary: "#756D60"
  paper-divider: "#DBD4C5"
  paper-accent: "#2E6CD2"
  dark-canvas: "#1B2029"
  dark-surface: "#242C38"
  dark-heading: "#F0F3FA"
  dark-text: "#D2DAE8"
  dark-secondary: "#A3AFC4"
  dark-divider: "#3A4658"
  dark-accent: "#3880F7"
  darkpaper-canvas: "#24211D"
  darkpaper-surface: "#302C26"
  darkpaper-heading: "#F0E8D8"
  darkpaper-text: "#D8CDB9"
  darkpaper-secondary: "#B9AD98"
  darkpaper-divider: "#50483C"
  darkpaper-accent: "#6090DE"
  brand-orange: "#FFA52C"
  brand-red: "#FF4B65"
  brand-magenta: "#FA27BB"
  brand-violet: "#8B39FA"
  brand-blue: "#3261FF"
  brand-cyan: "#00C8FF"
typography:
  display:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif"
    fontSize: "50px"
    fontWeight: 750
    lineHeight: 1.06
    letterSpacing: "-0.025em"
  headline:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif"
    fontSize: "40px"
    fontWeight: 750
    lineHeight: 1.1
    letterSpacing: "-0.022em"
  title:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif"
    fontSize: "19px"
    fontWeight: 680
    lineHeight: 1.3
    letterSpacing: "-0.01em"
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.55
  label:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 600
    lineHeight: 1
  code:
    fontFamily: "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, monospace"
    fontSize: "13.5px"
    fontWeight: 400
    lineHeight: 1.6
rounded:
  sm: "6px"
  md: "9px"
  lg: "11px"
  card: "14px"
  window: "16px"
  pill: "999px"
spacing:
  xs: "8px"
  sm: "12px"
  md: "20px"
  lg: "32px"
  xl: "64px"
  section: "112px"
components:
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "#FFFFFF"
    typography: "{typography.label}"
    rounded: "{rounded.lg}"
    padding: "12px 20px"
  button-primary-dark:
    backgroundColor: "{colors.accent-fill-dark}"
    textColor: "#FFFFFF"
  button-secondary:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.heading}"
    rounded: "{rounded.lg}"
    padding: "12px 20px"
  nav-button:
    backgroundColor: "{colors.accent}"
    textColor: "#FFFFFF"
    rounded: "{rounded.md}"
    padding: "9px 14px"
  card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text}"
    rounded: "{rounded.card}"
  band:
    backgroundColor: "{colors.band}"
    textColor: "{colors.text}"
  nav-link-active:
    backgroundColor: "{colors.selected}"
    textColor: "{colors.accent-text}"
    rounded: "{rounded.md}"
    padding: "6px 10px"
  callout:
    backgroundColor: "{colors.selected}"
    textColor: "{colors.text}"
    rounded: "{rounded.lg}"
    padding: "14px 18px 14px 46px"
---

# Design System: dBrief website

## Overview

This file documents the design system of the dBrief WEBSITE (`site/`: landing page and docs), not the macOS app. The website's world is pinned to the app's 2.0 visual world.

**Creative North Star: "The App, Calmly Shown"**

The page is the app. Each section rebuilds a real 2.0 screen (recording viewer, menu bar panel, call prompt, Ask dBrief AI, privacy receipt) in the app's own palette and lets the product do the persuading. Surfaces are quiet rounded cards on a quiet canvas; type is the system UI font in a single family; colour is a restrained blue accent on neutrals that the visitor can switch between four themes (Light, Paper, Dark, Dark Paper), and the switch recolours the whole site, mockups included.

Density is moderate: one 1200 px column, generous 112 px section rhythm, copy in warm plain language. Imagery is never stock or invented social proof; it is HTML/CSS reconstructions of the app.

**Key Characteristics:**
- App-window world: canvas, surface, divider and band tones, not a marketing-gradient world.
- One accent (#1268F5 family), tuned per theme for AA contrast.
- The six-stop brand gradient is rationed to where the app uses it.
- Four themes plus Auto (follows system), all driven by custom properties on `:root` / `[data-theme]`.
- Motion embodies "the meeting becomes a brief": one authored sequence on load, a theme wash, and small demos that react to the visitor. Reduced motion has its own path for each.

## Colors

A cool-neutral app palette with a single blue accent, repeated in four tunings (theme.css). Values below are Light unless prefixed; the frontmatter is normative.

### Primary
- **App Blue** (#1268F5): borders, focus rings, chat bubble, selected tab underline, primary button fill in Light. In Dark the fill steps to #3171D6 (`accent-fill-dark`) so white text keeps 4.5:1; Paper uses #2E6CD2, Dark Paper #4C75B6 for fill.
- **Accent Text** (#105CD9): accent used as text and links, shifted per theme until it is at least 4.5:1 on surface and on the selected tint (Dark #5995F7, Paper #295DB4, Dark Paper #729CE2).

### Neutral
- **Canvas** (#FBFCFE): page background. Paper #F5F2EB (warm), Dark #1B2029, Dark Paper #24211D.
- **Surface** (#FFFFFF): cards, window panels, inputs. Paper #FFFCF5, Dark #242C38, Dark Paper #302C26.
- **Band** (#F3F6FB): full-width alternating sections and code blocks, always with hairline top and bottom borders.
- **Divider** (#E1E7F0): every 1 px border and rule.
- **Heading** (#0B1430), **Text** (#31405F), **Secondary** (#65718A): the three text tiers. Paper tones are warm browns (#302D28 / #514B42 / #756D60); dark themes invert.
- **Selected** (#DAE7FD): accent mixed about 14% into canvas; active nav item, badges, icon wells.
- **Success Green** (#23793A, per-theme): only for "done" status marks in mockups.
- **Speaker colours** (#2B7378, #A33F48, #3E7444): avatar fills in mockups only; white initials.
- **Danger** (`--danger` #B93852, fill #FFF2F5, border #D5B3C1; per theme from the app's MenuPanelPalette): only the record demo's "Recording" status, its red dot and the soft Stop button.

### Named Rules
**The Four-Theme Rule.** Every colour comes from a theme variable. A new surface must be checked in all four themes, and hard-coded hex is allowed only for the logo, window traffic lights and speaker avatars.

**The Rationed Gradient Rule.** The brand gradient (orange, red, magenta, violet, blue, cyan) appears only on the five-bar logo, the Ask dBrief AI outline, the sparkle and the call-prompt border. It is never a fill behind text, never gradient text, never a section background.

**The Accent-Text Rule.** Accent as text always uses `accent-text`, not the raw accent; the fill and the text variants exist because they pass contrast separately.

## Typography

**Display / Body Font:** the system UI stack (`-apple-system`, SF Pro Text, Segoe UI, system-ui, sans-serif). **Mono:** `ui-monospace` / SF Mono for commands, timestamps and code. **Showcase fonts:** Lexend, EB Garamond, Inter, OpenDyslexic (self-hosted, OFL) appear only inside the Focus Reader/fonts demonstration, never as site UI.

**Character:** one native family at confident weights (650 to 750) with tight negative tracking on large sizes; it reads like the app, not like a brand site.

### Hierarchy
- **Display** (750, 50px, 1.06, -0.025em): landing H1; 42px under 980 px.
- **Headline** (750, 40px, 1.1, -0.022em): section H2; close-section H2 is 48px; 33px on small screens.
- **Title** (680-720, 19-25px, 1.2-1.3): docs H2/H3 and "where" subheads. Docs page title is 38px/750.
- **Body** (400, 16px, 1.55; docs 16.5px at 1.7, capped at 70ch): lede is 17.5-18px.
- **Label** (600, 14-15px): buttons, nav links (14px), small notes (13.5px, secondary tone).

### Named Rules
**The Single Family Rule.** Site UI is the system stack only. Other families belong to the font-showcase demo.

**The Balanced Heading Rule.** Headings use `text-wrap: balance`; no heading is set in a size smaller than its body text.

## Layout

One centred column, `max-width: 1200px`, 32 px side padding, nothing bleeding off the page (`overflow-x: clip`). Landing sections are two-column splits (about 1 : 1.08, 56-72 px gap, sometimes flipped) that collapse to one column at 980 px; the hero is a 440 px copy column beside the stage, collapsing at 1199 px. Sections breathe at 112 px vertical padding, alternating plain canvas and `band` sections. Docs use a 236 px sticky sidebar plus a 70ch reading column with a 64 px gap and a mobile drawer. The nav is sticky, 64 px tall, translucent canvas with a 14 px backdrop blur, and gains a divider on scroll. Responsive breakpoints: 1199, 980, 760, 640, 600, 380 px. Spacing runs on a loose 4/8 rhythm (8, 12, 20, 32, 64, 112).

## Elevation & Depth

Hybrid: tonal layering first (canvas, surface, band, hairline dividers), shadow only on floating things. Cards and docs tables sit flat on a 1 px divider. Floating mockups (menu panel, reader card, call card, receipt) use soft, long-throw shadows.

### Shadow Vocabulary
- **Medium** (`--shadow-md`: `0 18px 40px -20px rgba(11,20,48,.25), 0 1px 3px rgba(11,20,48,.06)`): panels and cards that float over a mockup.
- **Large** (`--shadow-lg`: `0 40px 80px -32px rgba(11,20,48,.28), 0 2px 8px rgba(11,20,48,.06)`): call card and privacy receipt. Dark themes use black at .6-.7 alpha.
- **Button lift** (`0 8px 20px -12px rgba(var(--shadow-ink), .35), 0 1px 2px rgba(var(--shadow-ink), .12)`, deeper on hover with a 1 px rise, flatter while pressed): primary button only. `--shadow-ink` is the theme's shadow colour (navy in Light, warm brown in Paper, black in both dark themes), so the lift never reads as a coloured glow.

### Named Rules
**The Flat-At-Rest Rule.** Ordinary content cards are bordered, not shadowed. Shadow means "this floats above something".

**Mockup-specific convention (not a page rule).** The recording-viewer window is drawn with a hairline ring plus a big offset drop shadow (`--window-shadow`, 0.5 px ring in light themes, 1 px white-9% ring in dark) because that is how a macOS window looks. Do not reuse this ring-plus-throw recipe on page furniture.

## Shapes

Gently rounded and consistent: 6 px (chips, small controls), 9 px (nav buttons, search, nav items), 11 px (buttons, callouts, brew command row, docs cards/code), 14 px (cards, panels), 16 px (the app window), 18-20 px (receipt, call prompt), full pill for the theme switch and tags. Borders are always 1 px solid divider; the accent border (1.5 px) marks the composer and the call prompt. Logo bars are 3 px wide rounded strokes.

## Components

### Buttons
- **Shape:** 11 px radius, 12x20 padding, 15 px/600; nav variant 9 px radius, 9x14 padding, 14 px.
- **Primary:** `primary-fill` background, white text (fill is chosen for 4.5:1), button-lift shadow; hover rises 1 px. Filled controls that change colour on hover instead (the menu panel's Record meeting, the call prompt's Record call) use `--primary-fill-hover`, the fill darkened with black, which keeps white text at 4.5:1 in every theme (lightening toward the heading tone fails in Dark and Dark Paper).
- **Secondary:** surface background, heading text, divider border; hover darkens border to secondary; pressed fills with `band`. "Match my Mac" in the theme picker follows the same hover.
- **Focus:** 2 px accent outline, 3 px offset, on every interactive element.

### Theme switch
A pill with an Auto glyph and four 24 px swatches in each theme's canvas colour; pressed state gets a surface gap plus a 3.5 px accent ring. Keyboard reachable; choice persists and recolours the site and the mockups.

### Navigation
Logo (five bars + wordmark 18/700), 14 px links in text tone (heading on hover; current docs page in accent text 600), theme switch and a small Download button on the right. Links hide under 980 px. The header is one shared component in theme.css; the landing page shows its divider once scrolled, docs always. The docs filter sits on a solid shelf in the sticky sidebar, so topics never show around it while the list scrolls; Return opens the first match. Docs sidebar: search field (34 px, 9 px radius, accent focus ring) and grouped list; active item gets `selected` fill and accent text.

### Cards / Containers
Surface fill, 1 px divider, 14 px radius, 10-16 px padding for mockup cards, no shadow unless floating. Bands are full-width `band` with hairlines.

### Docs prose
70ch measure, 1.7 line height; headings get more space above than below (h2 56 px / h3 36 px above). Callouts are a selected-tinted blockquote with a masked info glyph; code is mono on `band`; tables are bordered 12 px-rounded surfaces with a band header; kbd is a bordered key cap.

### Brew command row
Surface pill row with mono command, user-selectable, plus a small `selected` copy button.

### App mockups (signature)
HTML/CSS rebuilds of the recording viewer, menu panel, call prompt, Ask dBrief AI chat, Focus Reader card and privacy receipt. They carry content the real app produces and are labelled synthetic where invented. Mockup-specific convention, not page typography: text inside them runs 8.5-12 px, tab rows are tight, and the window uses the hairline-plus-shadow recipe, all because they replicate the macOS app's own metrics. Page copy never uses these sizes.

### Motion
**Thesis:** dBrief is quietly listening and taking notes for you. Motion uses the app's own materials (writing lines, streamed answers, the five bars as a level meter, ticked-off actions), never generic reveals.

- **Easing:** `--ease-out` = `cubic-bezier(.16, 1, .3, 1)` for every arrival; `ease-in` only for exits. No bounce, no elastic.
- **Durations:** feedback 120-180 ms (ticks, hovers, button colour), routine state 200-340 ms (bubbles arriving, call prompt), theme wash 560 ms, focal sequence about 2.5 s in total. Exits are faster than entrances (call prompt leaves in 160 ms, returns in 320 ms).
- **Content is visible by default.** No CSS rule hides text; `home.js` hides only what it is about to reveal, inside a Web Animation with `fill: backwards`, and only when reduced motion is off. `html.brief-writing` exists only while the hero sequence runs.

**Focal sequence, "the brief writes itself"** (once per load, hero only, skipped when the hero is not in view, waits for a hidden tab): the window and reader card settle in (1.1 s, unchanged); from 350 ms the Summary card is written line by line, each line a clip-path wipe left to right sized to its ink width (40 ms + 90 ms per full line); the question bubble arrives (340 ms, 8 px rise and .96 scale); the answer streams word by word (20 ms apart, each word 220 ms from opacity 0 and 2 px blur); the two timestamps light up in `--selected` for 700 ms.

**Ask section:** the first answer streams the same way the first time the chat scrolls into view (prepared in paused animations just before, so text never flashes and vanishes), then 00:31:12 lights up in the answer and its transcript turn gets the hit highlight, then the follow-up question and answer arrive.

**Theme wash:** the View Transitions API wraps the `data-theme` change; the new theme grows as a circle (`clip-path`) from the centre of the control that chose it, over 560 ms. Other transitions are suspended while it runs (`html.theme-washing`). No API: instant change.

**Record demo:** "Record call" or "Record meeting" swaps the panel to the app's recording controls (timer, pulsing red "Recording" dot, soft Stop), the menu bar item shows the app's red dot and duration, and the header's five bars become a level meter (`scaleY` every 110 ms, 110 ms linear, a wandering speech-like envelope, bounded 30-100 % of the bar box). It halts offscreen or in a hidden tab, stops itself after 60 s, and announces start and stop in a polite live region. "Not now" sends the prompt away and brings it back after 2 s.

**Actions:** ticking an action fills the ring with the accent (scale, 180 ms), draws the check (stroke-dashoffset, 160 ms), strikes the text through and mutes it, and updates the "N unfinished · M completed" line and the tab badge. Owner counts stay the total, as in the app.

**Reading fonts:** the specimen comes into focus in the new face (opacity .35 and 3 px blur to sharp, 240 ms).

**Reduced motion:** theme.css stops every CSS transition and animation. The hero and Ask text appear whole (no writing, no streaming), the theme change is a 120 ms crossfade instead of the wash, the level meter stays still while the timer keeps counting, the call prompt and font switch fade in 120 ms without movement, and ticked actions still change colour, fill and strike-through instantly.

**Don't:** scroll reveals on every section, parallax, hover lifts on content cards, bounce, confetti, sound, or new brand-gradient surfaces. Every loop stops when offscreen or hidden.

## Do's and Don'ts

### Do:
- **Do** build new sections as faithful pieces of the real app UI in theme variables, and verify them in all four themes.
- **Do** keep the accent to one blue and use `accent-text` for text.
- **Do** keep emphasis in headings as accent colour only (`em` without italics), never gradient text.
- **Do** keep one 1200 px column, 32 px gutters, and 112 px section rhythm.
- **Do** keep copy warm and concrete, and every claim something the app does today.
- **Do** keep focus rings, keyboard access and reduced-motion handling on every new control.

### Don't:
- **Don't** use the brand gradient as a fill, background or text colour beyond the four app-sanctioned places.
- **Don't** invent testimonials, logos, counts or ratings; the site uses no social proof.
- **Don't** use ring-plus-offset window shadows or sub-12 px text outside app mockups.
- **Don't** introduce a second UI typeface; showcase fonts stay in the font demo.
- **Don't** hard-code colours that should follow the theme, or ship a surface untested in Dark Paper.
- **Don't** claim "open source" or use the word without a licence.
