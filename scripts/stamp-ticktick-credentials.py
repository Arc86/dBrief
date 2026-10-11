#!/usr/bin/env python3
"""Write TickTick OAuth credentials into a built app's Info.plist.

Values come from TICKTICK_CLIENT_ID / TICKTICK_CLIENT_SECRET, falling back to
KEY=VALUE lines in an optional secrets file (gitignored packaging/secrets.env).
Missing values are written as empty strings, which hides TickTick in the app.
Never prints the values: this repository and its CI logs are public.
"""
import os
import pathlib
import plistlib
import sys

KEYS = {
    "TICKTICK_CLIENT_ID": "DBTickTickClientID",
    "TICKTICK_CLIENT_SECRET": "DBTickTickClientSecret",
}


def read_secrets(path):
    values = {}
    if path is None or not path.is_file():
        return values
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip("'\"")
    return values


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit("usage: stamp-ticktick-credentials.py <Info.plist> [secrets.env]")
    plist_path = pathlib.Path(sys.argv[1])
    secrets = read_secrets(pathlib.Path(sys.argv[2]) if len(sys.argv) == 3 else None)
    info = plistlib.loads(plist_path.read_bytes())
    configured = True
    for variable, plist_key in KEYS.items():
        value = os.environ.get(variable) or secrets.get(variable, "")
        info[plist_key] = value
        configured = configured and bool(value)
    plist_path.write_bytes(plistlib.dumps(info))
    print("TickTick credentials: " + ("stamped" if configured else "not set (TickTick hidden)"))


if __name__ == "__main__":
    main()
