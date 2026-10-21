import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const siteDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (f) => (existsSync(join(siteDir, f)) ? readFileSync(join(siteDir, f), "utf8") : "");
const html = read("docs.html");
const css = read("docs.css");
const js = read("docs.js");
const head = (html.match(/<head>([\s\S]*?)<\/head>/) || [])[1] || "";
const attr = (tag, name) => (tag.match(new RegExp(`\\b${name}\\s*=\\s*"([^"]*)"`)) || [])[1];

test("every sidebar slug in docs.js has a Markdown file", () => {
  const slugs = [...js.matchAll(/slug:\s*"([^"]+)"/g)].map((m) => m[1]);
  assert.ok(slugs.length >= 40, `expected the full sidebar, found ${slugs.length} slugs`);
  const missing = ["index", ...slugs].filter((s) => !existsSync(join(siteDir, "docs", `${s}.md`)));
  assert.deepEqual(missing, [], `missing docs: ${missing.join(", ")}`);
});

test("docs.html loads the self-hosted marked, not jsDelivr", () => {
  assert.match(html, /<script src="vendor\/marked\.min\.js"[^>]*><\/script>/);
  assert.doesNotMatch(html, /jsdelivr/i);
  const marked = html.search(/vendor\/marked\.min\.js/);
  const docs = html.search(/<script src="docs\.js/);
  assert.ok(docs > marked, "docs.js must load after marked");
});

test("theme.js loads synchronously in <head> before any stylesheet", () => {
  const script = head.search(/<script src="theme\.js"><\/script>/);
  const firstSheet = head.search(/<link[^>]+rel="stylesheet"/);
  assert.ok(script >= 0, "theme.js script tag missing from <head>");
  assert.ok(firstSheet > script, "a stylesheet loads before theme.js");
  assert.match(head, /<link rel="stylesheet" href="theme\.css[^"]*">/);
  assert.match(head, /<link rel="stylesheet" href="docs\.css[^"]*">/);
});

test("header theme switch has Auto plus four labelled swatches", () => {
  const header = (html.match(/<header[\s\S]*?<\/header>/) || [""])[0];
  const pick = (header.match(/class="theme-pick"[\s\S]*?<\/div>/) || [""])[0];
  const buttons = [...pick.matchAll(/<button[^>]*>/g)].map((m) => m[0]);
  assert.deepEqual(buttons.map((b) => attr(b, "data-theme-choice")), ["auto", "light", "paper", "dark", "darkpaper"]);
  assert.deepEqual(buttons.map((b) => attr(b, "aria-label")), ["Match my Mac", "Light", "Paper", "Dark", "Dark Paper"]);
});

test("header links home, back to the landing sections, and downloads the latest release", () => {
  const header = (html.match(/<header[\s\S]*?<\/header>/) || [""])[0];
  const hrefs = [...header.matchAll(/<a\b[^>]*>/g)].map((m) => attr(m[0], "href"));
  for (const h of ["index.html", "index.html#record", "index.html#yours", "index.html#privacy", "docs.html", "https://github.com/Arc86/dBrief/releases/latest"]) {
    assert.ok(hrefs.includes(h), `header link missing: ${h}`);
  }
});

test("no ambient orbs or old site files remain", () => {
  assert.doesNotMatch(html, /\b(orb|ambient)\b/);
  assert.doesNotMatch(css, /\.(orb|ambient)\b/);
  assert.doesNotMatch(html, /styles\.css|buttons\.js|app\.js|fonts\.googleapis/);
  assert.doesNotMatch(css, /background-clip\s*:\s*text/);
});

test("prose keeps a 65-75ch reading measure", () => {
  const m = css.match(/\.prose\s*\{[^}]*max-width:\s*(\d+)ch/);
  assert.ok(m, ".prose has no max-width in ch");
  const ch = Number(m[1]);
  assert.ok(ch >= 65 && ch <= 75, `.prose measure ${ch}ch`);
});
