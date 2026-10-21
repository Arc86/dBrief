# get.dbrief.nl redesign: the website looks like the app

Date: 2026-10-21 · Status: awaiting Jesper's approval of this document · Owner: Jesper

Product truth lives in `PRODUCT.md` (repo root, gitignored by design: local to the machine running the design skill). This document covers the website only: the landing page (`site/index.html`) and the docs shell (`site/docs.html`, `site/docs.css`, `site/docs.js`). The docs **content** (`site/docs/**/*.md`) is out of scope; it was updated for 2.0 in PR #124.

## Why

dBrief 2.0 shipped a full redesign, but the website still wears the old look: dark-only, near-black navy (#060918), its own coral/violet/cyan gradient with glows, Inter from Google Fonts, and almost no picture of the app. Jesper: it "doesn't follow our current design of the app and is missing how the app looks like."

The visitor is someone in back-to-back client and team meetings, not a developer. In the first seconds they should **get a feel for the app** and **clearly understand what it can do for them**, then download it.

## Goals

1. The site uses the app's visual world: its four themes, palette, system font, five-bar logo, and the way the app uses the brand gradient.
2. The site shows the real app: every product picture is an HTML/CSS rebuild of a real dBrief screen, faithful to the 2.0 UI, recolouring with the active theme.
3. Four themes on the site, behaving like the app: follow the visitor's system (light → Light, dark → Dark), with a visitor override (Auto, Light, Paper, Dark, Dark Paper) that is remembered.
4. A visitor remembers three things: **record without a bot**, **actions per person sent to your tools**, **ask the meeting**. Themes/fonts and privacy support them.
5. Showcase the themes and reading fonts as a feature, interactively.
6. The docs pages get the same themes, switch, header and type, without big mockups.

## Non-goals

- Dutch website (English only for now; the app is bilingual).
- Changing docs content, adding pages, or a build step / framework.
- Social proof of any kind (none exists; none may be invented).
- Screenshots or generated images of the app.

## Anti-goals (a failure even if it works)

- A generic SaaS template: centred headline over a row of equal icon cards; a hero-metric block; gradient text; glowing neon on near-black.
- Mockups that drift from the real app (wrong layout, invented UI, toolbar strips the app doesn't have).
- Any invented claim: users, ratings, customers, speeds, "open source" (there is no license file).
- Loading third-party fonts or trackers on a privacy product's homepage.

## Constraints

- Static HTML/CSS/vanilla JS in `site/`, deployed by `git pull` on Jesper's CleanVM host (TrueNAS). No build step.
- App facts: macOS 14+, Apple Silicon only, free notarized DMG from GitHub Releases, Homebrew `brew install Arc86/dbrief/dbrief`, English + Dutch app, integrations Obsidian, Apple Notes, Apple Reminders, Notion, Todoist, TickTick, webhook.
- Voice: **warm and a bit playful**, still clear and concrete (Jesper chose this over calm-and-plain).
- Accessibility: WCAG AA contrast in all four themes, keyboard-reachable theme switch and controls, visible focus, `prefers-reduced-motion` respected.
- Must keep working: `docs.html` routing and nav (`docs.js`), the docs filter, deep links like `docs.html#integrations/notion`.
- **Fidelity source of truth: the real 2.0 app wins over the draft** (Jesper, 2026-10-21). The draft fixes structure, composition and copy direction; every mockup's anatomy (labels, controls, order, layout) must match the app.
- **Download links go to the GitHub Releases page** (`https://github.com/Arc86/dBrief/releases/latest`), as today (Jesper, 2026-10-21). No release-process change.

## Decided with Jesper

### Visual world (pinned: "follow the app")

Theme tokens, taken from `Sources/dBrief/Models/ViewerPalette.swift` (accent #1268F5 mixed per theme as the app does):

| Theme | canvas | surface | heading | text | secondary | divider | primary (accent) |
|---|---|---|---|---|---|---|---|
| Light | #FBFCFE | #FFFFFF | #0B1430 | #31405F | #65718A | #E1E7F0 | #1268F5 |
| Paper | #F5F2EB | #FFFCF5 | #302D28 | #514B42 | #756D60 | #DBD4C5 | ≈#2E6CD2 |
| Dark | #1B2029 | #242C38 | #F0F3FA | #D2DAE8 | #A3AFC4 | #3A4658 (softened) | ≈#3880F7 |
| Dark Paper | #24211D | #302C26 | #F0E8D8 | #D8CDB9 | #B9AD98 | #50483C (softened) | ≈#6090DE |

Derived tokens (selected tint, accent text) follow the app's rules: selected = accent mixed 14% into canvas; accent text darkened/lightened until ≥4.5:1 on surface. The draft's approximations are a starting point; the builder computes them properly.

- Brand gradient (#FFA52C → #FF4B65 → #FA27BB → #8B39FA → #3261FF → #00C8FF) appears **only where the app uses it**: the five-bar logo, the Ask dBrief AI button outline, the sparkle, the call-prompt border. No gradient text.
- Type: the macOS system font stack (`-apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", system-ui, sans-serif`), because that is the app's UI face. This overrides the design skill's "no platform sans as display" rule by brief. Risk: non-Apple visitors see Segoe/Roboto; acceptable.
- Reading fonts for the showcase are self-hosted from the app's own OFL files (`Sources/dBrief/Resources/Fonts/`): Lexend, OpenDyslexic, EB Garamond, Inter, with their OFL licence texts alongside.
- Icons: authored inline SVG in one stroke weight (SF Symbols-like), never emoji or Unicode glyphs.

### Landing page structure (approved draft: `.superpowers/brainstorm/31577-1792566173/content/site-draft-v2.html`)

1. **Nav (sticky):** logo, links (How it works · Make it yours · Privacy · Docs), theme switch (Auto half-moon + four swatches), Download button.
2. **Hero ("calm and editorial", version C):** left column: headline "Notes from every meeting, *without taking any.*" (emphasis in accent colour, not gradient), lede, Download for Mac + See how it works, facts line (Free · macOS 14+ · Apple Silicon · English & Nederlands). Right column: a flat, faithful **recording viewer with the sidebar collapsed**, matching the real app (Jesper's screenshot): no toolbar strip; traffic lights and sidebar toggle on the canvas; date line with calendar icon; bold title; tabs (Summary, Transcript, Actions + count badge, Meeting Insights) with icons right; command row (Copy, Edit, Reprocess, Spoken Summary, gradient-outlined Ask dBrief AI); the "✦ Summary" card with word count; **Ask dBrief AI as its own floating card** (header with AA ⋯ ✕, blue question bubble, "✦ dBrief" answer with clickable-looking timestamps and copy/speak/retry/share icons, suggestion chips, composer with mic and send). A small **Focus Reader card** (Lexend) overlaps the window's empty lower-left corner and covers no text. Copy and window are vertically centred in one 1200 px column; nothing bleeds off the page. No label/chip above the headline.
3. **Record without a bot** ("Hit record. Nobody gets a bot."): copy + three points (menu bar or ⌃⌥⌘R; call detection for Zoom, Teams, Meet, Slack, Webex, FaceTime; record while the last one processes). Visual: a Mac menu bar strip with the dBrief icon active, the menu bar panel dropped open (Record meeting button, recent recordings), and the "Zoom call detected" prompt (gradient border, Not now / Record call).
4. **Who does what** ("Everyone leaves knowing their homework."): the Actions tab with action items grouped per person (owner cards with initials avatars and counts), placeholders dropped, next to the destination row (Todoist, TickTick, Notion, Apple Reminders, Apple Notes, Obsidian, Webhook) and "retries never double up".
5. **Ask the meeting** ("Missed something? Ask the meeting."): a transcript excerpt beside a large Ask dBrief AI panel. **Signature interaction:** clicking a timestamp in an answer highlights and scrolls to the matching transcript turn.
6. **Make it yours** ("Your notes, your way."): four mini-window theme cards; clicking one switches the whole site (same state as the nav switch). Then "Read in the font that suits you.": a Focus Reader specimen with a font switcher (Lexend, OpenDyslexic, EB Garamond, Inter) and three inclusion lines (English or Nederlands, VoiceOver, keyboard).
7. **Your meetings stay yours:** "On your Mac" (Apple Speech/Whisper/Parakeet; Apple Intelligence/Gemma; voice library stays local), "If you choose" (own AI provider, CLI tools, destinations you switch on), an example privacy receipt, and "No account. No dBrief cloud. Nothing to sign up for."
8. **Close:** "Your next meeting starts soon. Let dBrief take the notes.", Download for Mac + Read the docs, the Homebrew command with a copy button, requirements line.
9. **Footer:** logo, Docs, Release notes, GitHub, Report a bug.

All sample content is a synthetic meeting ("Q3 roadmap sync", Priya Shah, Tom Bakker, Jesse Meijer) and is labelled as an example where it could be mistaken for real.

### Theme behaviour

- Default "Auto": `prefers-color-scheme` light → Light, dark → Dark; follows live system changes.
- Override: Auto, Light, Paper, Dark, Dark Paper; stored in `localStorage` (wrapped in try/catch; page works without storage). Shared by landing page and docs.
- Applied before first paint (tiny inline script in `<head>`) so there is no flash of the wrong theme.

### Docs shell

Same tokens, header (logo, links, theme switch), system font and focus styles. The sidebar, breadcrumb, prose, code blocks, tables, callouts and pager are restyled to the app's palette (prose in a comfortable measure, 65–75ch). No ambient orbs.

## Left to the builder (sensible calls; mark them in the PR)

- Exact spacing scale, radii (12–16 px cards, as the app), shadows (offset + soft blur; one elevation per element).
- Motion: one authored moment (e.g. the hero window and reader card settling in once), plus the timestamp highlight; nothing scattered; all off under reduced motion.
- Final copy within the voice and the facts above; meta/OG tags refreshed to the new copy; `theme-color` per theme.
- Whether `styles.css`/`docs.css` are rewritten or replaced by one shared token file plus page files (prefer one shared `theme.css`).
- Self-hosting `marked` instead of jsDelivr (preferred, for the privacy story) and dropping Google Fonts everywhere.
- Mobile layout (≥360 px): stacked sections, the hero window without the chat card, fitting panels; no horizontal scroll. Known draft gaps: the viewer's command row clips and the fake menu bar wraps on phones.
- Removing now-unused files (`app.js`, `buttons.js`, old CSS) once nothing references them.

## Process requirements

- **Reference capture first.** Before building mockups, run the 2.0 beta (`make run-beta` from main; quit any other dBrief beta first, they share settings) and capture the screens the page rebuilds: the viewer with the sidebar collapsed and Ask dBrief AI open (Summary and Actions tabs), the menu bar panel, the call-detected prompt, the Focus Reader, the privacy receipt, and the Appearance theme picker. Store them under `.superpowers/reference/` (gitignored). Jesper's own screenshot of the viewer is already there (`viewer-sidebar-collapsed-jesper.png`). Correct the draft's mockups to match; known gap: the privacy receipt must show the real anatomy (stage, provider/destination, data categories, outcome), not the draft's two-column list.

- Use the `impeccable` skill during build (Jesper asked): record the direction contract in the surface brief before code; code-led build (no image generation available); one batched desktop + mobile inspection, run `impeccable detect` once, then the finish reviewer and documenter (DESIGN.md).
- Verify in a browser in all four themes at 1440 and 390 px before review; check contrast of secondary text and accent text in each theme.
- Deploy is Jesper's: after merge, `git pull` on CleanVM.
