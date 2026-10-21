import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
const t = createRequire(import.meta.url)("../theme.js");

test("resolveTheme", () => {
  assert.equal(t.resolveTheme("auto", false), "light");
  assert.equal(t.resolveTheme("auto", true), "dark");
  assert.equal(t.resolveTheme("paper", true), "paper");
  assert.equal(t.resolveTheme("bogus", true), "dark");
});
test("readChoice", () => {
  assert.equal(t.readChoice(null), "auto");
  assert.equal(t.readChoice({ getItem() { throw new Error("blocked"); } }), "auto");
  assert.equal(t.readChoice({ getItem: () => "darkpaper" }), "darkpaper");
  assert.equal(t.readChoice({ getItem: () => "neon" }), "auto");
});
test("writeChoice swallows errors", () => {
  assert.doesNotThrow(() => t.writeChoice({ setItem() { throw new Error(); } }, "dark"));
});
test("constants", () => {
  assert.equal(t.STORAGE_KEY, "dbrief-theme");
  assert.deepEqual(t.CHOICES, ["auto", "light", "paper", "dark", "darkpaper"]);
});

import { readThemeCss, parseThemes } from "./helpers.mjs";
test("no-JS fallback tokens equal light, and the dark media block equals dark", () => {
  const css = readThemeCss();
  const themes = parseThemes(css);
  const media = css.match(/@media \(prefers-color-scheme: dark\)\s*\{\s*:root:not\(\[data-theme\]\)\s*\{([^}]*)\}/);
  assert.ok(media, "dark media fallback block exists");
  const vars = {};
  for (const d of media[1].matchAll(/--([\w-]+)\s*:\s*([^;]+);/g)) vars[d[1]] = d[2].trim();
  assert.deepEqual(vars, themes.dark);
  assert.match(css, /:root:not\(\[data-theme\]\),\s*\[data-theme="light"\]/);
});
test("wireThemeColor is exported", () => assert.equal(typeof t.wireThemeColor, "function"));
