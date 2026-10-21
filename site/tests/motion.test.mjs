import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { contrast } from "./helpers.mjs";

const siteDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (f) => readFileSync(join(siteDir, f), "utf8");
const html = read("index.html");
const css = read("home.css");
const themeCss = read("theme.css");
const require = createRequire(import.meta.url);
const home = require("../home.js");
const theme = require("../theme.js");

test("formatElapsed reads like the app's recording clock", () => {
  assert.equal(home.formatElapsed(0), "00:00");
  assert.equal(home.formatElapsed(7), "00:07");
  assert.equal(home.formatElapsed(7.9), "00:07");
  assert.equal(home.formatElapsed(60), "01:00");
  assert.equal(home.formatElapsed(3723), "1:02:03");
  assert.equal(home.formatElapsed(-4), "00:00");
});

test("splitWords keeps every character, so a streamed answer reads back unchanged", () => {
  const text = "Two things: sending the beta invite  to the waitlist before Friday ";
  const words = home.splitWords(text);
  assert.equal(words.join(""), text);
  assert.equal(words.length, 11);
  assert.ok(words.every((w) => /\S/.test(w)));
  assert.deepEqual(home.splitWords(""), []);
  assert.deepEqual(home.splitWords("   "), ["   "]);
});

test("actionSummary counts unfinished and completed actions", () => {
  assert.equal(home.actionSummary([false, false, false, false, false]).text, "5 unfinished · 0 completed");
  const s = home.actionSummary([true, false, true, false, false]);
  assert.equal(s.unfinished, 3);
  assert.equal(s.completed, 2);
  assert.equal(s.text, "3 unfinished · 2 completed");
});

test("lineRevealFrames writes line by line and ends fully revealed", () => {
  const lines = [{ top: 0, bottom: 16, right: 300 }, { top: 16, bottom: 32, right: 120 }];
  const { frames, duration } = home.lineRevealFrames(lines, 400, 90);
  assert.ok(duration > 0 && duration < 400);
  assert.equal(frames.length, 4);
  assert.equal(frames[0].offset, 0);
  assert.equal(frames.at(-1).offset, 1);
  for (let i = 1; i < frames.length; i++) assert.ok(frames[i].offset >= frames[i - 1].offset, "offsets increase");
  for (const f of frames) assert.equal(f.clipPath.match(/,/g).length, 5, "every polygon has six points");
  assert.match(frames[0].clipPath, /^polygon\(0px 0px, 100% 0px, 100% 0px, 0px 0px, 0px 16px, 0px 16px\)$/);
  assert.match(frames.at(-1).clipPath, /100% 16px, 122px 16px, 122px 32px, 0px 32px\)$/);
  assert.deepEqual(home.lineRevealFrames([], 400, 90), { frames: [], duration: 0 });
});

test("washRadius reaches the farthest viewport corner", () => {
  assert.equal(theme.washRadius(0, 0, 300, 400), 500);
  assert.equal(theme.washRadius(300, 400, 300, 400), 500);
  assert.equal(theme.washRadius(150, 200, 300, 400), 250);
});

// Rules whose selector is about hero or Ask text: summary, chat bubbles, answers.
const ruleBlocks = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((m) => ({ sel: m[1].trim(), body: m[2] }));
test("no CSS rule hides hero or Ask text by default", () => {
  const textSel = /\.(sum|ans|q|who|big-chat|acts)\b/;
  const hides = /opacity\s*:\s*0(?![.\d])|visibility\s*:\s*hidden|clip-path\s*:|display\s*:\s*none/;
  const offenders = ruleBlocks.filter((r) => textSel.test(r.sel) && hides.test(r.body) && !/^html\.brief-writing/.test(r.sel));
  assert.deepEqual(offenders.map((r) => r.sel), []);
});

test("the writing state is a class home.js sets, never a default", () => {
  assert.doesNotMatch(html, /class="[^"]*brief-writing/);
  assert.match(read("home.js"), /classList\.add\("brief-writing"\)/);
  assert.match(read("home.js"), /classList\.remove\("brief-writing"\)/);
});

test("reduced motion has a path for every new animation", () => {
  const js = read("home.js");
  assert.match(js, /function canAnimate\(\)[\s\S]*?!reducedMotion\(\)/, "writing and streams need canAnimate()");
  assert.match(js, /function writeHeroBrief\(\)[\s\S]*?canAnimate\(\)/);
  assert.match(js, /function streamAskOnce\([^)]*\)[\s\S]*?canAnimate\(\)/);
  assert.match(js, /!meter && !reducedMotion\(\)/, "level meter is skipped under reduced motion");
  const homeReduce = (css.match(/@media \(prefers-reduced-motion: reduce\)\s*\{([\s\S]*?)\n\}/) || [])[1] || "";
  assert.match(homeReduce, /\.meter i\s*\{[^}]*transform:\s*none/);
  assert.match(themeCss, /@media \(prefers-reduced-motion: reduce\)\s*\{\s*::view-transition-group/);
  assert.match(themeCss, /transition: none !important; animation: none !important/);
  assert.match(read("theme.js"), /if \(reduce \|\| !origin\) return;/, "no circular wash under reduced motion");
});

test("record demo: real buttons, a polite live region, labelled as an example", () => {
  const desk = (html.match(/<figure class="desk-fig">[\s\S]*?<\/figure>/) || [""])[0];
  assert.doesNotMatch(desk, /class="desk" role="img"/, "interactive mock cannot be role=img");
  for (const hook of ['data-rec="start"', 'data-rec="stop"', 'data-call="record"', 'data-call="dismiss"']) {
    assert.match(desk, new RegExp(`<button type="button"[^>]*${hook}`), hook);
  }
  assert.match(desk, /<p class="sr-only" id="rec-live" aria-live="polite"><\/p>/);
  assert.match(desk, /class="synthetic">Example/);
  assert.match(desk, /class="rec-ui" hidden/);
});

test("actions mock: each action is a toggle button, header and badge start in step", () => {
  const mock = (html.match(/<div class="actions-mock"[\s\S]*?<figcaption/) || [""])[0];
  assert.doesNotMatch(mock, /role="img"/);
  const ticks = [...mock.matchAll(/<button type="button" class="todo-tick" aria-pressed="false" aria-labelledby="(ai-\d)"/g)].map((m) => m[1]);
  assert.equal(ticks.length, 5);
  for (const id of ticks) assert.match(mock, new RegExp(`id="${id}"`));
  assert.match(mock, /data-action-summary[^>]*>5 unfinished · 0 completed</);
  assert.match(mock, /data-unfinished>5</);
});

test("danger tones from the app pass AA in every theme", () => {
  const pick = (sel) => {
    const block = (css.match(new RegExp(`${sel}\\s*\\{([^}]*--danger:[^}]*)\\}`)) || [])[1] || "";
    return Object.fromEntries([...block.matchAll(/--([\w-]+):\s*(#[0-9A-Fa-f]{6})/g)].map((m) => [m[1], m[2]]));
  };
  const surfaces = { light: "#FFFFFF", paper: "#FFFCF5", dark: "#242C38", darkpaper: "#302C26" };
  for (const [name, surface] of Object.entries(surfaces)) {
    const t = pick(`\\[data-theme="${name}"\\]`);
    assert.ok(t.danger, `${name} --danger`);
    assert.ok(contrast(t.danger, surface) >= 4.5, `${name} danger on surface`);
    assert.ok(contrast(t.danger, t["danger-fill"]) >= 4.5, `${name} danger on its fill`);
  }
});
