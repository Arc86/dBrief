import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
const here = dirname(fileURLToPath(import.meta.url));
export const themeCssPath = join(here, "..", "theme.css");
export const readThemeCss = () => readFileSync(themeCssPath, "utf8");

// Parses the `[data-theme="x"] { --a: v; ... }` blocks into {x: {a: v}}.
export function parseThemes(cssText) {
  const out = {};
  const re = /\[data-theme="(light|paper|dark|darkpaper)"\]\s*\{([^}]*)\}/g;
  let m;
  while ((m = re.exec(cssText))) {
    const vars = out[m[1]] ?? (out[m[1]] = {});
    for (const d of m[2].matchAll(/--([\w-]+)\s*:\s*([^;]+);/g)) vars[d[1]] = d[2].trim();
  }
  return out;
}

function luminance(hex) {
  const n = hex.replace("#", "");
  const [r, g, b] = [0, 2, 4].map((i) => {
    const v = parseInt(n.slice(i, i + 2), 16) / 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
export function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}
