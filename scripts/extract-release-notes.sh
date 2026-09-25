#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version>" >&2
  exit 2
fi

version=$1
notes_file="$(dirname "$0")/../RELEASE_NOTES.md"

awk -v heading="## dBrief ${version}" '
  $0 == heading { found = 1; next }
  found && /^## dBrief / { exit }
  found { lines[++count] = $0 }
  END {
    if (!found) {
      printf "No release notes found for %s\n", heading > "/dev/stderr"
      exit 1
    }
    while (count > 0 && lines[count] ~ /^[[:space:]]*$/) count--
    if (count > 0 && lines[count] == "---") count--
    for (i = 1; i <= count; i++) print lines[i]
  }
' "$notes_file"
