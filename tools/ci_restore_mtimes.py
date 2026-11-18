#!/usr/bin/env python3
"""Sets each tracked file's modification time to the time of the last commit that changed it.

A fresh checkout gives every file the time of the checkout, so Xcode and SwiftPM, which decide what to rebuild by file times, would rebuild
everything even with last run's build folder restored from the cache. With the commit times, only files changed since that build are rebuilt.
Needs the full history (actions/checkout with fetch-depth: 0). Files with changes not yet committed keep their own time.

  ci_restore_mtimes.py            every tracked file
  ci_restore_mtimes.py --check    print how many files it would set, change nothing
"""
import os, subprocess, sys


def main():
    check = "--check" in sys.argv
    tracked = set(subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True).stdout.decode().split("\0")) - {""}
    dirty = set(subprocess.run(["git", "diff", "--name-only", "-z", "HEAD"], capture_output=True, check=True).stdout.decode().split("\0")) - {""}
    # One pass over the history, newest first: the first time a file appears is its last change.
    log = subprocess.run(["git", "log", "--format=@%ct", "--name-only", "--no-renames"], capture_output=True, check=True).stdout.decode()
    seen, when = {}, None
    for line in log.splitlines():
        if line.startswith("@"): when = int(line[1:])
        elif line and line in tracked and line not in seen: seen[line] = when
    done = 0
    for path, t in seen.items():
        if path in dirty or not os.path.isfile(path): continue
        if not check: os.utime(path, (t, t))
        done += 1
    print(f"{'would set' if check else 'set'} {done} of {len(tracked)} files to their last commit's time")


if __name__ == "__main__":
    main()
