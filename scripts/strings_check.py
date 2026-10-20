#!/usr/bin/env python3
"""Localization guardrails for Localizable.xcstrings.

    strings_check.py check <catalog> <compiled-dir> <infoplist-catalog> <stringsdata>...
        Fails when the source has a string the catalog lacks, when a translation's
        format specifiers don't match its key, or when the committed compiled
        .lproj files differ from what the catalog compiles to. Contents are
        compared, not bytes, so a different Xcode version doesn't cause noise.

    strings_check.py report <catalog>
        Prints how much of each language is translated, as a Markdown table.
"""
import collections
import json
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile

# Flags exclude the space so prose such as "6.05% for" isn't read as "% f".
SPEC = re.compile(r"%(?:(\d+)\$)?([-+#0]*\d*(?:\.\d+)?(?:lld|ld|lu|d|u|@|f|g|e|x)|%)")
LETTERS = re.compile(r"[A-Za-z]{2,}")


def specs(text):
    found = []
    for match in SPEC.finditer(text):
        if match.group(2) == "%":
            continue
        kind = re.sub(r"[-+#0\d.]", "", match.group(2))
        found.append((match.group(1), kind))
    return found


def translatable(key):
    return bool(LETTERS.search(SPEC.sub("", key)))


def spec_problem(key, value, variant=False):
    """None when `value` uses the same specifiers as `key`.

    A plural variant may leave a number out ("Name the voice …" for one)."""
    want = collections.Counter(kind for _, kind in specs(key))
    found = specs(value)
    if any(position for position, _ in found) and not all(position for position, _ in found):
        return "mixes positional and plain specifiers"
    have = collections.Counter(kind for _, kind in found)
    if variant:
        return None if not (have - want) else f"unexpected specifiers {dict(have - want)}"
    return None if have == want else f"specifiers {dict(want)} -> {dict(have)}"


def check_translations(catalog):
    problems = []
    for key, entry in catalog["strings"].items():
        for language, localization in entry.get("localizations", {}).items():
            unit = localization.get("stringUnit")
            if unit and "%#@" not in unit.get("value", ""):
                problem = spec_problem(key, unit["value"])
                if problem:
                    problems.append(f"{language}: {key!r}: {problem}")
            for variants in localization.get("variations", {}).values():
                for variant in variants.values():
                    value = variant.get("stringUnit", {}).get("value", "")
                    problem = spec_problem(key, value, variant=True)
                    if problem:
                        problems.append(f"{language}: {key!r} (plural): {problem}")
    return problems


def compile_contents(catalogs):
    """{relative path: parsed plist} for what the catalogs compile to."""
    with tempfile.TemporaryDirectory() as directory:
        for catalog in catalogs:
            subprocess.run(["xcrun", "xcstringstool", "compile", str(catalog), "--output-directory", directory],
                           check=True, capture_output=True)
        return load_tree(pathlib.Path(directory))


def load_tree(root):
    return {str(path.relative_to(root)): plistlib.loads(path.read_bytes())
            for path in sorted(root.rglob("*")) if path.is_file()}


def check(catalog_path, compiled_dir, infoplist_path, stringsdata_paths):
    catalog = json.loads(pathlib.Path(catalog_path).read_text())
    errors = []

    source_keys = set()
    for path in stringsdata_paths:
        tables = json.loads(pathlib.Path(path).read_text()).get("tables", {})
        source_keys.update(entry["key"] for entry in tables.get("Localizable", []))
    live = {key for key, entry in catalog["strings"].items() if entry.get("extractionState") != "stale"}
    missing = sorted(source_keys - set(catalog["strings"]))
    if missing:
        errors.append(f"{len(missing)} source strings are missing from the catalog, e.g. {missing[:5]}")
    unused = sorted(live - source_keys - {k for k, e in catalog["strings"].items()
                                          if e.get("extractionState") == "manual"})
    if unused:
        print(f"note: {len(unused)} catalog strings are no longer in the source and will be marked stale "
              f"by the next sync, e.g. {unused[:3]}")

    errors += check_translations(catalog)

    expected = compile_contents([catalog_path, infoplist_path])
    committed = load_tree(pathlib.Path(compiled_dir))
    if expected != committed:
        differing = sorted(set(expected) ^ set(committed)) or \
            sorted(path for path in expected if expected[path] != committed.get(path))
        errors.append(f"compiled translations are out of date ({', '.join(differing)})")

    if errors:
        print("Localization check failed:")
        for error in errors:
            print(f"  - {error}")
        print("Fix: run `make strings` (or `scripts/sync-strings.sh --compile-only` after editing a "
              "translation) and commit the catalog and Sources/dBrief/Resources/Localizations.")
        return 1
    print(f"Localization check passed: {len(source_keys)} source strings, catalog and compiled files in step.")
    return 0


def report(catalog_path):
    catalog = json.loads(pathlib.Path(catalog_path).read_text())
    keys = [key for key, entry in catalog["strings"].items()
            if entry.get("extractionState") != "stale" and entry.get("shouldTranslate") is not False
            and translatable(key)]
    languages = sorted({language for key in keys
                        for language in catalog["strings"][key].get("localizations", {})} - {"en"})
    print("| Language | Translated | Needs review | Missing |")
    print("|---|---|---|---|")
    for language in languages:
        done = review = 0
        for key in keys:
            localization = catalog["strings"][key].get("localizations", {}).get(language)
            if not localization:
                continue
            done += 1
            states = re.findall(r'"state":\s*"(\w+)"', json.dumps(localization))
            review += "needs_review" in states
        print(f"| {language} | {done}/{len(keys)} ({done * 100 // max(len(keys), 1)}%) | {review} | "
              f"{len(keys) - done} |")
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "report":
        sys.exit(report(sys.argv[2]))
    if len(sys.argv) >= 5 and sys.argv[1] == "check":
        sys.exit(check(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]))
    sys.exit(__doc__)
