#!/usr/bin/env python3
"""Writes a pseudo-localized Localizable.strings for checking which UI text is
still hard-coded: every catalog string becomes "⟦…⟧", so any text on screen
without the brackets doesn't go through the catalog.

    scripts/pseudo-strings.py Sources/dBrief/Resources/Localizations/nl.lproj
    make beta && open dBrief-Beta.app --args -AppleLanguages "(nl)"
    scripts/sync-strings.sh --compile-only   # restore the real translations
"""
import json
import pathlib
import plistlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
catalog = json.loads((root / "Sources/dBrief/Resources/Localizable.xcstrings").read_text())
target = pathlib.Path(sys.argv[1])
target.mkdir(parents=True, exist_ok=True)
strings = {key: f"⟦{key}⟧" for key in catalog["strings"] if key.strip()}
with open(target / "Localizable.strings", "wb") as handle:
    plistlib.dump(strings, handle)
print(f"Wrote {len(strings)} pseudo strings to {target}")
