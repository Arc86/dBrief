# get.dbrief.nl Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the landing page and docs shell of get.dbrief.nl in the dBrief 2.0 app's visual world: four themes, faithful HTML rebuilds of real app screens, a theme and font showcase.

**Architecture:** Plain static files in `site/`. One shared token sheet (`theme.css`) and one shared theme script (`theme.js`, applied in `<head>` before paint) serve both pages; each page adds its own stylesheet and script. Fonts and the Markdown renderer are self-hosted. Logic worth testing lives in small pure functions exported for Node's built-in test runner.

**Tech Stack:** HTML, CSS (custom properties, `color-mix`), vanilla JS, `node --test` (Node 26, no npm dependencies), `playwright-cli` for browser checks, the `impeccable` skill for design process.

**Spec:** `docs/superpowers/specs/2026-10-21-website-redesign-design.md` (approved 2026-10-21). Approved draft: `.superpowers/brainstorm/31577-1792566173/content/site-draft-v2.html`. Product record: `PRODUCT.md` (local, gitignored).

Worktree: `/Users/jesper.mol/code/VoiceRecorder-1.5.0`, branch `site/redesign`. Serve locally with `python3 -m http.server 8765 --directory site` (run in background); pages at `http://localhost:8765/index.html` and `/docs.html`.

## Global Constraints

- Static files only; no build step, no npm dependencies in `site/`; deploy is `git pull` on CleanVM.
- No third-party requests from either page: no Google Fonts, no jsDelivr, no analytics. Allowed external references are plain links to `github.com/Arc86/dBrief…`.
- Theme tokens per theme exactly as the spec's table (Light, Paper, Dark, Dark Paper); brand gradient `#FFA52C → #FF4B65 → #FA27BB → #8B39FA → #3261FF → #00C8FF` only on the logo bars, the Ask dBrief AI outline, the sparkle and the call-prompt border. No gradient text.
- UI font stack: `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", system-ui, sans-serif`. Showcase fonts self-hosted from `Sources/dBrief/Resources/Fonts/` with their OFL files.
- Theme storage key `dbrief-theme`; values `auto | light | paper | dark | darkpaper`; default `auto` (system light → `light`, dark → `dark`).
- WCAG AA: body, secondary and accent text ≥ 4.5:1 on canvas and surface in every theme; button text on its fill ≥ 4.5:1 (dark themes need a deeper button fill than the app's accent; white on #3880F7 is only 3.75:1, on #6090DE 3.21:1).
- Download links go to `https://github.com/Arc86/dBrief/releases/latest`. Docs link `docs.html`. Homebrew: `brew install Arc86/dbrief/dbrief`.
- Facts only: macOS 14+, Apple Silicon, free, English & Nederlands, integrations Obsidian, Apple Notes, Apple Reminders, Notion, Todoist, TickTick, webhook. No social proof, no "open source". Example content labelled as an example.
- Voice: warm and a bit playful, clear and concrete. English only.
- No label/eyebrow above headings; icons are inline SVG in one stroke weight, never emoji or Unicode glyphs.
- The real 2.0 app wins over the draft for every mockup's anatomy.

## Review Focus

1. **Storage blocked** (Safari private window, blocked site data): `localStorage` throws; the page still renders in the system theme and the switch still works for the session. Test in Task 2 (`resolveTheme` with a throwing storage).
2. **System appearance changes while the page is open:** with `auto` the page follows; with an explicit choice it does not. Test in Task 2.
3. **JavaScript disabled or slow:** content is visible and themed from the system (a `prefers-color-scheme: dark` fallback for `:root:not([data-theme])`), no hidden-until-animated content. Test in Task 2 (CSS fallback present) and Task 4 (no element starts invisible without JS).
4. **Phones at 360 px:** no horizontal scroll on either page; hero window, panel and call prompt fit. Browser check in Tasks 4 and 5 (`scrollWidth <= innerWidth`).
5. **Theme choice carries across pages:** choosing Paper on the landing page shows Paper on `docs.html#integrations/notion` and back. Browser check in Task 5.

---

### Task 1: Reference capture and direction contract

**Files:**
- Create: `.superpowers/reference/*.png`, `.superpowers/reference/notes.md` (gitignored)
- Create: surface brief via `impeccable surface-brief write site/index.html …` (lands in `.impeccable/`, gitignored)

**Interfaces:**
- Produces: reference captures and a list of draft-vs-app differences that Tasks 4 and 6 must apply; the direction contract later reviewers load.

- [ ] **Step 1: Launch the 2.0 beta.** Quit any running dBrief Beta first (`osascript -e 'tell application id "com.dbrief.app.beta" to quit'`), then `make run-beta` from the worktree. Expected: `Launched dBrief-Beta.app`.
- [ ] **Step 2: Capture each screen** with `screencapture -x -l<windowid>` or `-R`, in Light theme, into `.superpowers/reference/`: `viewer-summary.png` (sidebar collapsed, Ask dBrief AI open), `viewer-actions.png`, `menu-panel.png`, `call-prompt.png` (if it cannot be triggered, use the user's earlier screenshot description in the spec), `focus-reader.png`, `privacy-receipt.png`, `appearance-settings.png`. Jesper's `viewer-sidebar-collapsed-jesper.png` is already there.
- [ ] **Step 3: Write `notes.md`**: one line per difference between `site-draft-v2.html` and the captures (labels, order, controls, layout). Known: the privacy receipt shows stage, provider/destination, data categories and outcome.
- [ ] **Step 4: Write the surface brief** with `/Users/jesper.mol/.claude/skills/impeccable/scripts/impeccable surface-brief write site/index.html <body-file> site/docs.html`. The body holds scope (Persuade for `index.html`, Read for `docs.html`), audience/job/action from PRODUCT.md, and `## Direction contract` with THESIS, OWN-WORLD, STORY, FIRST VIEWPORT, FORM (`user-pinned: app world + approved draft v2; no concept-seed roll`), and FINISH verbatim: "unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance". Never copy the contract into `site/`.
- [ ] **Step 5: Verify** with `impeccable surface-brief read site/index.html`. Expected: all six blocks present.

### Task 2: Theme foundation (`theme.css`, `theme.js`) with tests

**Files:**
- Create: `site/theme.css`, `site/theme.js`
- Create: `site/tests/theme.test.mjs`, `site/tests/contrast.test.mjs`, `site/tests/helpers.mjs`

**Interfaces:**
- Produces (`theme.js`, classic script that also sets `module.exports` when defined):
  - `STORAGE_KEY = "dbrief-theme"`, `CHOICES = ["auto","light","paper","dark","darkpaper"]`
  - `resolveTheme(choice: string, prefersDark: boolean): "light"|"paper"|"dark"|"darkpaper"` (unknown choice → behaves as `auto`)
  - `readChoice(storage: {getItem(k):string|null} | null): string` (returns `"auto"` when storage is null, throws, or holds an unknown value)
  - `writeChoice(storage, choice): void` (swallows exceptions)
  - On load in a browser: sets `document.documentElement.dataset.theme` immediately; `initThemeSwitch()` on DOMContentLoaded wires every `[data-theme-choice]` button (sets `aria-pressed`, stores, applies) and listens to `matchMedia('(prefers-color-scheme: dark)')` changes.
- Produces (`theme.css`): custom properties `--canvas --surface --heading --text --secondary --divider --band --primary --primary-fill --on-primary --accent-text --selected --shadow-lg --shadow-md --brand --sys --mono` under `[data-theme="light|paper|dark|darkpaper"]`, plus `:root:not([data-theme])` light defaults and a `@media (prefers-color-scheme: dark)` block giving `:root:not([data-theme])` the Dark values. `--primary-fill` is the button background (≥ 4.5:1 with `--on-primary`); `--primary` keeps the app's mixed accent for borders, bubbles and chips. Also base element styles shared by both pages (body, selection, focus-visible, links, `.ico`, `.bars` logo, `.btn` primary/secondary, theme switch `.theme-pick`), and `@media (prefers-reduced-motion: reduce)` disabling transitions.

- [ ] **Step 1: Write the failing tests.** `theme.test.mjs` (load `../theme.js` via `createRequire`):
  - `resolveTheme("auto", false) === "light"`, `resolveTheme("auto", true) === "dark"`, `resolveTheme("paper", true) === "paper"`, `resolveTheme("bogus", true) === "dark"`.
  - `readChoice(null) === "auto"`; `readChoice({getItem(){ throw new Error("blocked") }}) === "auto"`; `readChoice({getItem:()=> "darkpaper"}) === "darkpaper"`; `readChoice({getItem:()=> "neon"}) === "auto"`.
  - `writeChoice({setItem(){ throw new Error() }}, "dark")` does not throw.
  - `STORAGE_KEY === "dbrief-theme"`.
  `contrast.test.mjs` (`helpers.mjs` exports `parseThemes(cssText) -> {light:{…},paper:{…},dark:{…},darkpaper:{…}}` and `contrast(hexA, hexB) -> number` using WCAG relative luminance):
  - For each theme: `contrast(text, canvas)`, `contrast(text, surface)`, `contrast(secondary, canvas)`, `contrast(secondary, surface)`, `contrast(accent-text, surface)`, `contrast(accent-text, selected)`, `contrast(on-primary, primary-fill)` are all `>= 4.5`.
  - The Light/Paper/Dark/Dark Paper `canvas`, `surface`, `heading`, `text`, `secondary` equal the spec table exactly.
  - The CSS text contains `prefers-color-scheme: dark` and `:root:not([data-theme])`.
- [ ] **Step 2: Run** `node --test site/tests/` — Expected: FAIL (files missing).
- [ ] **Step 3: Implement `site/theme.js` and `site/theme.css`** to the interfaces above. Compute `--selected` (accent mixed 14% into canvas), `--accent-text` and `--primary-fill` so the tests pass; record the computed hex values in the CSS, not runtime `color-mix` for these three.
- [ ] **Step 4: Run** `node --test site/tests/` — Expected: all pass.
- [ ] **Step 5: Commit** `site/theme.css site/theme.js site/tests/` — `feat(site): shared four-theme tokens and theme switch`.

### Task 3: Self-hosted fonts and Markdown renderer

**Files:**
- Create: `site/fonts/` with `Lexend-Variable.ttf`, `EBGaramond-Variable.ttf`, `Inter-Regular.otf`, `Inter-Bold.otf`, `OpenDyslexic-Regular.otf`, `OpenDyslexic-Bold.otf` and their `*-OFL.txt` (copied from `Sources/dBrief/Resources/Fonts/`), plus `site/fonts/fonts.css` (`@font-face` rules, `font-display: swap`)
- Create: `site/vendor/marked.min.js` (marked 13.0.3, the version `docs.html` loads today) and `site/vendor/marked-LICENSE.md`
- Create: `site/tests/assets.test.mjs`

**Interfaces:**
- Produces: font families `"Lexend"`, `"EB Garamond"`, `"Inter"`, `"OpenDyslexic"` via `fonts/fonts.css`; `vendor/marked.min.js` defines `window.marked`.

- [ ] **Step 1: Write the failing test** `assets.test.mjs`: for `site/index.html` and `site/docs.html`, every `src`/`href` that is not `#…`, `mailto:` or `https://github.com/Arc86/dBrief…` resolves to an existing file under `site/`; no attribute or CSS `url()` points at another host (`fonts.googleapis.com`, `cdn.jsdelivr.net`, etc.); every `@font-face` `url()` in `site/fonts/fonts.css` exists.
- [ ] **Step 2: Run** `node --test site/tests/assets.test.mjs` — Expected: FAIL (index/docs still load Google Fonts and jsDelivr).
- [ ] **Step 3: Add the files** (copy fonts, write `fonts.css`, download `https://cdn.jsdelivr.net/npm/marked@13.0.3/marked.min.js` once and its LICENSE; verify the first line names marked v13.0.3). The test keeps failing until Tasks 4–5 replace the page heads; that is expected.
- [ ] **Step 4: Commit** `site/fonts site/vendor site/tests/assets.test.mjs` — `chore(site): self-host showcase fonts and marked`.

### Task 4: Landing page

**Files:**
- Rewrite: `site/index.html`
- Create: `site/home.css`, `site/home.js`
- Create: `site/tests/home.test.mjs`

**Interfaces:**
- Consumes: `theme.css`, `theme.js` (`initThemeSwitch`, `[data-theme-choice]` buttons), `fonts/fonts.css`.
- Produces (`home.js`, also `module.exports`): `turnForTimestamp(ts: string, turns: Array<{t:string}>): number` (index of the turn whose `t === ts`, else `-1`); browser wiring for `[data-jump]` timestamps (adds `.hit` to the matching `.turn`, removes it from others, scrolls it into view with `block:"nearest"`, smooth unless reduced motion), `[data-font]` buttons (sets the reader's `font-family`, `aria-pressed`), copy button for the Homebrew command (`navigator.clipboard.writeText("brew install Arc86/dbrief/dbrief")`, label changes to "Copied" for 2 s), and the nav `.scrolled` border.

- [ ] **Step 1: Write the failing test** `home.test.mjs`: `turnForTimestamp("00:38:40", [{t:"00:31:12"},{t:"00:38:40"}]) === 1`; unknown → `-1`. Static checks on `index.html`: has `<script src="theme.js">` inside `<head>` before any stylesheet; has the nav switch with five `[data-theme-choice]` buttons (`auto, light, paper, dark, darkpaper`) and the four theme cards; exactly the section ids `record, actions, ask, yours, privacy, download`; every download link `href` is `https://github.com/Arc86/dBrief/releases/latest`; no `background-clip: text` in `home.css`; no element has an inline or CSS rule that makes it invisible before JS runs (no `.reveal` / `opacity:0` defaults).
- [ ] **Step 2: Run** `node --test site/tests/home.test.mjs` — Expected: FAIL.
- [ ] **Step 3: Build `index.html` + `home.css` + `home.js`** from `site-draft-v2.html`, applying every line of `.superpowers/reference/notes.md` (real app anatomy wins), the spec's section copy, and: privacy receipt with the real anatomy; button fills use `--primary-fill`; one authored entrance moment for the hero window and reader card (CSS, content visible by default, skipped under reduced motion); meta description, Open Graph tags and per-theme `theme-color` updated to the new copy; `logo.png` kept as favicon/OG image. Mobile (≤ 600 px): hero window without the chat card, command row fits, fake menu bar does not wrap, panel and call prompt fit.
- [ ] **Step 4: Run** `node --test site/tests/` — Expected: theme, contrast, home pass; assets may still fail only for `docs.html`.
- [ ] **Step 5: Browser check** (server running): with `playwright-cli`, open `index.html` at 1440×900 and 390×844 in each theme (click each nav swatch). For each: full-page screenshot into `.impeccable/review/home-<theme>-<width>.png`; `scrollWidth <= innerWidth`; console has no errors except a missing favicon; clicking `[data-jump="00:38:40"]` gives that turn class `hit`; clicking the OpenDyslexic button changes the reader's computed `font-family`. Fix what the captures show in one batch; re-capture once.
- [ ] **Step 6: Commit** `site/index.html site/home.css site/home.js site/tests/home.test.mjs` — `feat(site): landing page in the app's 2.0 look`.

### Task 5: Docs shell

**Files:**
- Rewrite: `site/docs.html`, `site/docs.css`
- Modify: `site/docs.js` only where class names or the loading of `marked` change (routing, filter, pager logic unchanged)
- Create: `site/tests/docs.test.mjs`

**Interfaces:**
- Consumes: `theme.css`, `theme.js`, `vendor/marked.min.js`.

- [ ] **Step 1: Write the failing test** `docs.test.mjs`: every `slug` in `docs.js` has `site/docs/<slug>.md`; `docs.html` loads `vendor/marked.min.js` (not jsDelivr) and `theme.js` in `<head>`; it has the same five `[data-theme-choice]` buttons; no `.orb`/ambient markup remains.
- [ ] **Step 2: Run** `node --test site/tests/docs.test.mjs` — Expected: FAIL.
- [ ] **Step 3: Restyle** header (logo, links back to `index.html#…`, theme switch, Download), sidebar, filter field, breadcrumb, prose (65–75ch measure, headings, lists, tables, code, blockquote callouts, images), pager and mobile menu with the tokens; system font; focus styles.
- [ ] **Step 4: Run** `node --test site/tests/` — Expected: all pass, including `assets.test.mjs`.
- [ ] **Step 5: Browser check**: `docs.html#integrations/notion` at 1440 and 390 in Light and Dark Paper; nav, filter (type "todo" → Todoist listed), pager and mobile menu work; `scrollWidth <= innerWidth`; choose Paper on `index.html`, open `docs.html` → Paper, change to Dark there, back to `index.html` → Dark. Screenshots into `.impeccable/review/docs-*.png`.
- [ ] **Step 6: Commit** `site/docs.html site/docs.css site/docs.js site/tests/docs.test.mjs` — `feat(site): docs in the app's four themes`.

### Task 6: Cleanup

**Files:**
- Delete: `site/styles.css`, `site/app.js`, `site/buttons.js` (and any other file nothing references)
- Modify: `site/tests/assets.test.mjs` (add: no file under `site/` except `docs/**`, `tests/**`, `fonts/**`, `vendor/**` is unreferenced by the two pages or by each other)

- [ ] **Step 1: Add the unreferenced-file assertion; run** `node --test site/tests/assets.test.mjs` — Expected: FAIL listing the old files.
- [ ] **Step 2: Delete them; run** `node --test site/tests/` — Expected: all pass.
- [ ] **Step 3: Commit** — `chore(site): remove the old site styles and scripts`.

### Task 7: Finish (impeccable) and PR

- [ ] **Step 1: Detector:** `/Users/jesper.mol/.claude/skills/impeccable/scripts/impeccable detect --json site/index.html site/home.css site/docs.html site/docs.css site/theme.css`; fix mechanical findings; keep the rest for the reviewer.
- [ ] **Step 2: Captures:** `.impeccable/review/desktop.png` (index, 1440, Light, full page) and `mobile.png` (390), plus the per-theme captures from Tasks 4–5. Open each once to confirm it is valid (no blank regions, motion settled).
- [ ] **Step 3: Finish review:** spawn `impeccable-finish-reviewer` fresh with the request, the spec, the surface brief path, artifact paths, screenshot paths, detector findings, the draft as critique reference, and `reference/craft-floor.md`. Act on its disposition (ship / fix / rebuild / recapture); at most two fix rounds.
- [ ] **Step 4: Documenter:** spawn `impeccable-documenter` to write `DESIGN.md` and `.impeccable/design.json` from the built site. Commit `DESIGN.md` — `docs: DESIGN.md for the website`.
- [ ] **Step 5: Final run** `node --test site/tests/` — Expected: all pass. Push `site/redesign` and open a PR to `main` listing the builder calls from the spec and the reviewer's verdict; deploy stays with Jesper (`git pull` on CleanVM after merge).
