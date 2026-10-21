import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const siteDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (f) => (existsSync(join(siteDir, f)) ? readFileSync(join(siteDir, f), "utf8") : "");
const html = read("index.html");
const css = read("home.css");
const RELEASES = "https://github.com/Arc86/dBrief/releases/latest";

const loadHome = () => createRequire(import.meta.url)("../home.js");
const attr = (tag, name) => (tag.match(new RegExp(`\\b${name}\\s*=\\s*"([^"]*)"`)) || [])[1];

test("turnForTimestamp finds the matching turn", () => {
  const { turnForTimestamp } = loadHome();
  const turns = [{ t: "00:31:12" }, { t: "00:38:40" }];
  assert.equal(turnForTimestamp("00:38:40", turns), 1);
  assert.equal(turnForTimestamp("00:31:12", turns), 0);
  assert.equal(turnForTimestamp("01:00:00", turns), -1);
  assert.equal(turnForTimestamp("00:31:12", []), -1);
});

test("theme.js loads synchronously in <head> before any stylesheet", () => {
  const head = (html.match(/<head>([\s\S]*?)<\/head>/) || [])[1] || "";
  const script = head.search(/<script src="theme\.js"><\/script>/);
  const firstSheet = head.search(/<link[^>]+rel="stylesheet"/);
  assert.ok(script >= 0, "theme.js script tag missing from <head>");
  assert.ok(firstSheet > script, "a stylesheet loads before theme.js");
  assert.doesNotMatch(head, /<script src="theme\.js"[^>]*\b(defer|async)\b/);
});

test("nav theme switch has Auto plus four labelled swatches", () => {
  const nav = (html.match(/<header[\s\S]*?<\/header>/) || [""])[0];
  const pick = (nav.match(/class="theme-pick"[\s\S]*?<\/div>/) || [""])[0];
  const buttons = [...pick.matchAll(/<button[^>]*>/g)].map((m) => m[0]);
  assert.deepEqual(buttons.map((b) => attr(b, "data-theme-choice")), ["auto", "light", "paper", "dark", "darkpaper"]);
  for (const b of buttons) assert.ok(attr(b, "aria-label"), `swatch without aria-label: ${b}`);
});

test("Make it yours has four theme cards sharing the theme state", () => {
  const cards = [...html.matchAll(/<button[^>]*class="theme-card"[^>]*>/g)].map((m) => attr(m[0], "data-theme-choice"));
  assert.deepEqual(cards, ["light", "paper", "dark", "darkpaper"]);
});

test("sections are exactly record, actions, ask, yours, privacy, download", () => {
  const ids = [...html.matchAll(/<section\b[^>]*\bid="([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(ids, ["record", "actions", "ask", "yours", "privacy", "download"]);
});

test("every download link goes to the latest GitHub release", () => {
  const anchors = [...html.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/g)];
  const downloads = anchors.filter(([, a, body]) => /data-download/.test(a) || />\s*Download\b|^\s*Download\b/.test(body.replace(/<svg[\s\S]*?<\/svg>/g, "")));
  assert.ok(downloads.length >= 3, `expected at least 3 download links, found ${downloads.length}`);
  for (const [tag] of downloads) assert.equal(attr(tag, "href"), RELEASES, tag);
});

test("every answer timestamp has a transcript turn to jump to", () => {
  const jumps = [...html.matchAll(/data-jump="([^"]+)"/g)].map((m) => m[1]);
  const turns = new Set([...html.matchAll(/class="turn(?: hit)?"[^>]*data-t="([^"]+)"/g)].map((m) => m[1]));
  assert.ok(jumps.length >= 2, "expected clickable timestamps");
  for (const j of jumps) assert.ok(turns.has(j), `no .turn for ${j}`);
});

test("home.css has no gradient text", () => {
  assert.ok(css.length > 0, "home.css missing");
  assert.doesNotMatch(css, /background-clip\s*:\s*text/);
});

test("nothing is hidden until JS runs", () => {
  assert.doesNotMatch(html, /\breveal\b/);
  assert.doesNotMatch(css, /\.reveal\b/);
  assert.doesNotMatch(css, /opacity\s*:\s*0(?![.\d])/);
  assert.doesNotMatch(css, /visibility\s*:\s*hidden/);
  assert.doesNotMatch(html, /style="[^"]*(opacity\s*:\s*0(?![.\d])|visibility\s*:\s*hidden|display\s*:\s*none)/);
});

test("page loads home.css and home.js, not the old files", () => {
  assert.match(html, /<link rel="stylesheet" href="home\.css[^"]*">/);
  assert.match(html, /<script src="home\.js[^"]*"( defer)?><\/script>/);
  assert.doesNotMatch(html, /styles\.css|app\.js|buttons\.js|fonts\.googleapis/);
});
