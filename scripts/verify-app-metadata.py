#!/usr/bin/env python3
"""Reject missing or unresolved identity metadata before packaging the built app."""
import plistlib
import sys
from pathlib import Path


def verify(path):
    with Path(path).open("rb") as source:
        info = plistlib.load(source)
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        value = info.get(key)
        if not isinstance(value, str) or not value.strip() or "$" in value:
            raise ValueError(f"{key} must contain a resolved, nonempty version")
    for key, expected in (
        ("CFBundleDisplayName", "Cinespice"),
        ("CFBundleIdentifier", "app.tevee.ios"),
    ):
        if info.get(key) != expected:
            raise ValueError(f"{key} must be {expected!r}")
    print(f"Verified Cinespice {info['CFBundleShortVersionString']} "
          f"({info['CFBundleVersion']}) metadata")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: verify-app-metadata.py /path/to/Tevee.app/Info.plist")
    try:
        verify(sys.argv[1])
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        sys.exit(f"App metadata verification failed: {error}")
