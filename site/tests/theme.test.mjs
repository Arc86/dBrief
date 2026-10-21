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
