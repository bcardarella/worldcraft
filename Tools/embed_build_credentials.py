#!/usr/bin/env python3
"""Xcode build phase: embed optional environment credentials in the built app only.

Always rewrites the resource, including when keys are removed from the environment.
Never reads shell files, writes source files, or prints secret values.
"""

import os
from pathlib import Path
import plistlib
import sys

KEY_NAMES = ("TYPESAFE_API_KEY", "OPENROUTER_API_KEY")
LEGACY_FILES = ("TypeSafe.local.plist", "OpenRouter.local.plist")


def embed(environment):
    build = Path(environment["TARGET_BUILD_DIR"]).resolve()
    resources = (build / environment["UNLOCALIZED_RESOURCES_FOLDER_PATH"]).resolve()
    relative = resources.relative_to(build)
    if not relative.parts or not any(part.endswith(".app") for part in relative.parts):
        raise ValueError("Expected an app bundle inside TARGET_BUILD_DIR")
    # Xcode creates the bundle before this post-build phase. Only the declared
    # resource files need write access under Xcode's script sandbox.
    if not resources.is_dir():
        raise ValueError("Expected an existing app bundle")
    destination = resources / "BuildCredentials.plist"
    # A build after upgrading must not retain old credentials as copied resources.
    for name in LEGACY_FILES:
        (resources / name).unlink(missing_ok=True)
    destination.unlink(missing_ok=True)
    values = {}
    for name in KEY_NAMES:
        value = environment.get(name, "").strip()
        if not value:
            continue
        if len(value) > 8192 or any(character.isspace() for character in value):
            raise ValueError(f"{name} must contain a single API key without whitespace")
        values[name] = value
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as output:
            plistlib.dump(values, output, fmt=plistlib.FMT_BINARY, sort_keys=True)
    except BaseException:
        destination.unlink(missing_ok=True)
        raise
    return destination


if __name__ == "__main__":
    try:
        embed(os.environ)
    except (KeyError, ValueError, OSError):
        # Do not echo environment values, exception payloads, or file contents.
        print("error: Could not prepare build credentials. Check the build output path and API key environment variables.", file=sys.stderr)
        sys.exit(1)
