#!/usr/bin/env python3
"""Reserve a monotonic beta build number and stamp the assembled bundle.

The tracked counter survives `make clean` and app-version changes. Reserve the
number before stamping/signing: a failed build can leave a gap but cannot reuse
an issued number. Never change the production source Info.plist.
"""
import fcntl
import os
import pathlib
import plistlib
import re
import sys
import tempfile


def atomic_write(path, data):
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            os.fchmod(output.fileno(), 0o644)
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def stamp(plist_path, counter_path):
    info = plistlib.loads(plist_path.read_bytes())
    if info.get("CFBundleIdentifier") != "com.dbrief.app.beta":
        raise ValueError("Refusing to stamp a non-beta bundle")

    lock_path = counter_path.with_name(f".{counter_path.name}.lock")
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        previous = counter_path.read_text().strip()
        if not re.fullmatch(r"[0-9]+", previous):
            raise ValueError("Invalid beta build counter; refusing to reset it")
        number = int(previous) + 1
        info["CFBundleVersion"] = str(number)
        # Serialize first, then durably reserve before changing the bundle.
        encoded = plistlib.dumps(info, sort_keys=False)
        atomic_write(counter_path, f"{number}\n".encode())
        atomic_write(plist_path, encoded)
    print(f"Beta build {number} (app version {info.get('CFBundleShortVersionString', '?')})")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("Usage: stamp-beta-build.py BETA_INFO_PLIST COUNTER_FILE")
    try:
        stamp(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        sys.exit(f"Beta build stamping failed: {error}")
