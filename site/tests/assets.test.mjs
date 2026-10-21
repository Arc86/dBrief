import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const siteDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (f) => readFileSync(join(siteDir, f), "utf8");

const ALLOWED = [/^#/, /^mailto:/, /^https:\/\/github\.com\/Arc86\/dBrief/];
const isAllowed = (ref) => ALLOWED.some((re) => re.test(ref));
const isRemote = (ref) => /^(https?:)?\/\//.test(ref);
const stripQuery = (ref) => ref.split(/[?#]/)[0];

function attrRefs(html) {
  return [...html.matchAll(/\b(?:src|href)\s*=\s*["']([^"']+)["']/g)].map((m) => m[1]);
}
function cssUrls(css) {
  return [...css.matchAll(/url\(\s*["']?([^"')]+)["']?\s*\)/g)]
    .map((m) => m[1])
    .filter((u) => !u.startsWith("data:"));
}

for (const page of ["index.html", "docs.html"]) {
  const html = read(page);
  const refs = [...attrRefs(html), ...cssUrls(html)].filter((r) => !isAllowed(r));

  test(`${page}: no references to other hosts`, () => {
    const remote = refs.filter(isRemote);
    assert.deepEqual(remote, [], `remote references: ${remote.join(", ")}`);
  });

  test(`${page}: every local reference exists under site/`, () => {
    const missing = refs
      .filter((r) => !isRemote(r))
      .filter((r) => !existsSync(join(siteDir, stripQuery(r))));
    assert.deepEqual(missing, [], `missing files: ${missing.join(", ")}`);
  });
}

test("fonts.css: every @font-face url() exists", () => {
  const urls = cssUrls(read("fonts/fonts.css"));
  assert.ok(urls.length >= 6, "expected at least six font urls");
  for (const u of urls) {
    assert.ok(!isRemote(u), `${u} must be local`);
    assert.ok(existsSync(join(siteDir, "fonts", u)), `${u} does not exist`);
  }
});

test("vendor/marked.min.js is marked 13.0.3", () => {
  assert.match(read("vendor/marked.min.js").slice(0, 200), /marked v13\.0\.3/);
});
