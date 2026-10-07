#!/usr/bin/env python3
"""Launch Xcode directly so build scripts inherit this shell's environment."""

from pathlib import Path
import subprocess
import sys


def main():
    if subprocess.run(["/usr/bin/pgrep", "-x", "Xcode"], stdout=subprocess.DEVNULL).returncode == 0:
        raise SystemExit("Quit Xcode first, then rerun this command so it inherits your environment.")
    developer = Path(subprocess.check_output(["/usr/bin/xcode-select", "-p"], text=True).strip())
    executable = developer.parent / "MacOS" / "Xcode"
    if not executable.is_file():
        raise SystemExit("Select a full Xcode installation in Xcode > Settings > Locations first.")
    project = Path(__file__).resolve().parent.parent / "Worldcraft.xcodeproj"
    subprocess.Popen([str(executable), str(project)], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("Opened Xcode with the current shell environment. API key values are not displayed.")


if __name__ == "__main__":
    main()
