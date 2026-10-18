#!/bin/bash
# Updates Sources/dBrief/Resources/Localizable.xcstrings from the source code,
# then compiles it into the tracked Resources/Localizations/<lang>.lproj files that
# `make app` copies (xcstringstool needs Xcode; the app build doesn't).
# `--compile-only` skips the source scan, e.g. after editing a translation.
#
# The compiler extracts every localizable string (with exact placeholders) while
# building into a separate scratch path, so the normal build cache is untouched.
# The build is incremental and only re-emits a file's strings when it recompiles,
# so earlier output is kept and output for deleted sources is skipped. Only the
# app's own modules are synced; translations already in the catalog are kept, and
# strings no longer in the source are marked stale.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="$ROOT/Sources/dBrief/Resources/Localizable.xcstrings"
COMPILED="$ROOT/Sources/dBrief/Resources/Localizations"
OUT="$ROOT/.build/loc"

compile() {
    rm -rf "$COMPILED"
    mkdir -p "$COMPILED"
    xcrun xcstringstool compile "$CATALOG" --output-directory "$COMPILED"
    echo "Compiled: $(cd "$COMPILED" && ls -d ./*.lproj 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
}

if [ "${1:-}" = "--compile-only" ]; then
    compile
    exit 0
fi

mkdir -p "$OUT"
swift build --package-path "$ROOT" --product dBrief --scratch-path "$ROOT/.build/l10n" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT"

FILES=()
while IFS= read -r file; do FILES+=(--stringsdata "$file"); done < <(
    python3 - "$OUT" "$ROOT" <<'EOF'
import json, pathlib, sys
out, root = pathlib.Path(sys.argv[1]), sys.argv[2]
modules = (f"{root}/Sources/dBrief/", f"{root}/Sources/dBriefWire/")
for path in sorted(out.glob("*.stringsdata")):
    source = json.loads(path.read_text())["source"]
    if source.startswith(modules) and pathlib.Path(source).exists():
        print(path)
EOF
)

xcrun xcstringstool sync "$CATALOG" "${FILES[@]}"
echo "Synced $(( ${#FILES[@]} / 2 )) source files into ${CATALOG#"$ROOT"/}"
compile
