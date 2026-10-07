#!/usr/bin/env python3
"""Audit publishable files and every local Git object without printing secrets.

Known keys come from the environment; a local signing file supplies the private
team ID for exact matching. Ignored, untracked build products are not published.
All tracked files and Git objects (including unreachable objects) are inspected.
"""

import os
from pathlib import Path
import re
import subprocess
import sys


def git(root, *arguments):
    return subprocess.check_output(["git", "-C", str(root), *arguments], stderr=subprocess.DEVNULL)


def known_private_values(root):
    values = {value.strip().encode() for name in ("TYPESAFE_API_KEY", "OPENROUTER_API_KEY", "DEVELOPMENT_TEAM")
              if (value := os.environ.get(name)) and len(value.strip()) >= 10}
    signing = root / "Config" / "Signing.local.xcconfig"
    if signing.exists():
        values.update(re.findall(rb"DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]{10})\b", signing.read_bytes()))
    return values


def inspect_bytes(data, private_values):
    issues = set()
    if any(value in data for value in private_values):
        issues.add("known private key or Apple team identifier")
    if re.search(rb"sk-(?:or-v1-|proj-)?[a-zA-Z0-9_-]{32,}", data):
        issues.add("API token pattern")
    if re.search(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----", data):
        issues.add("private signing key")
    if re.search(rb"(?:DEVELOPMENT_TEAM|DevelopmentTeam)\s*[:=]\s*[\"']?[A-Z0-9]{10}\b", data):
        issues.add("literal Apple developer team")
    assignments = re.findall(rb"(?:TYPESAFE_API_KEY|OPENROUTER_API_KEY)[\"']?\s*[:=]\s*[\"']([^\"'\r\n]+)", data)
    for value in assignments:
        # Synthetic test data and explicit substitution examples are not keys.
        if value.startswith((b"test-", b"example-", b"$", b"<", b"your-")):
            continue
        if len(value) >= 16:
            issues.add("literal API key assignment")
    return issues


def private_path(path):
    parts = Path(path).parts
    return (parts[0] in {"tmp", "output", ".build", ".swiftpm", "DerivedData", "build", ".aws", "com.apple.DeveloperTools"}
            or "xcuserdata" in parts or "__pycache__" in parts
            or Path(path).name in {".DS_Store", "BuildCredentials.plist"}
            or Path(path).name.startswith(".env") and Path(path).name != ".env.example"
            or path.endswith((".local.plist", ".local.xcconfig", ".local.env", ".p12", ".p8", ".mobileprovision", ".provisionprofile"))
            or any(part.endswith((".app", ".xcarchive", ".xcresult")) for part in parts))


def audit(root):
    private_values = known_private_values(root)
    paths = set(git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0")) - {b""}
    failures = []
    for raw in sorted(paths):
        name = os.fsdecode(raw)
        path = root / name
        if private_path(name):
            failures.append((name, {"private/generated file is publishable"}))
        if path.is_file() and not path.is_symlink():
            issues = inspect_bytes(path.read_bytes(), private_values)
            if path.stat().st_size > 100 * 1024 * 1024:
                issues.add("file exceeds GitHub's 100 MiB limit")
            if issues:
                failures.append((name, issues))

    # --batch-all-objects also catches staged and dangling blobs, beyond branch history.
    objects = git(root, "cat-file", "--batch-all-objects", "--batch-check=%(objectname) %(objecttype)").splitlines()
    reader = subprocess.Popen(["git", "-C", str(root), "cat-file", "--batch"],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        for entry in objects:
            oid, kind = entry.split()
            if kind not in {b"blob", b"commit", b"tag"}:
                continue
            reader.stdin.write(oid + b"\n"); reader.stdin.flush()
            header = reader.stdout.readline().split()
            data = reader.stdout.read(int(header[2]))
            reader.stdout.read(1)
            issues = inspect_bytes(data, private_values)
            if issues:
                failures.append(("Git object " + oid.decode()[:12], issues))
    finally:
        reader.stdin.close(); reader.stdout.close(); reader.wait()
    commits = git(root, "rev-list", "--all", "--count").decode().strip()
    for location, issues in failures:
        print(f"FAIL {location}: {', '.join(sorted(issues))} (values hidden)")
    if failures:
        return 1
    print(f"PASS: {len(paths)} publishable files, {len(objects)} Git objects, {commits} reachable commits; no findings.")
    return 0


if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    try:
        sys.exit(audit(root))
    except (OSError, subprocess.CalledProcessError, ValueError):
        raise SystemExit("Audit could not complete; check that this is a readable Git repository.") from None
