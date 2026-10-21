import { test } from "node:test";
import assert from "node:assert/strict";
import { readThemeCss, parseThemes, contrast } from "./helpers.mjs";

const css = readThemeCss();
const themes = parseThemes(css);
const spec = {
  light: { canvas: "#FBFCFE", surface: "#FFFFFF", heading: "#0B1430", text: "#31405F", secondary: "#65718A" },
  paper: { canvas: "#F5F2EB", surface: "#FFFCF5", heading: "#302D28", text: "#514B42", secondary: "#756D60" },
  dark: { canvas: "#1B2029", surface: "#242C38", heading: "#F0F3FA", text: "#D2DAE8", secondary: "#A3AFC4" },
  darkpaper: { canvas: "#24211D", surface: "#302C26", heading: "#F0E8D8", text: "#D8CDB9", secondary: "#B9AD98" },
};

for (const name of Object.keys(spec)) {
  test(`${name}: spec values`, () => {
    for (const [k, v] of Object.entries(spec[name])) assert.equal(themes[name][k].toUpperCase(), v, `${name} --${k}`);
  });
  test(`${name}: AA contrast`, () => {
    const t = themes[name];
    const pairs = [
      ["text", "canvas"], ["text", "surface"], ["secondary", "canvas"], ["secondary", "surface"],
      ["accent-text", "surface"], ["accent-text", "selected"], ["on-primary", "primary-fill"],
    ];
    for (const [a, b] of pairs) {
      const c = contrast(t[a], t[b]);
      assert.ok(c >= 4.5, `${name} ${a} on ${b} = ${c.toFixed(2)}`);
    }
  });
}
test("system dark fallback present", () => {
  assert.ok(css.includes("prefers-color-scheme: dark"));
  assert.ok(css.includes(":root:not([data-theme])"));
});
