#!/usr/bin/env python3
"""Gives each tracked file a modification time worked out from its contents, so a build folder restored from CI's cache rebuilds only what changed.

Xcode and SwiftPM decide what to rebuild by file times: a source whose time differs from the one the last build saw is compiled again. A fresh checkout
gives every file the time of the checkout, so with last run's build folder restored they would still rebuild everything. Here a file's time comes from
git's hash of its contents (`git ls-files -s`, read from the checkout itself: no history is needed, so CI checks out one commit): the same contents always
get the same time, and changed contents a different one. The times fall in 2001 to 2006, older than any build. Files with changes not yet committed keep
their own time. (Until 2026-11-20 this was tools/ci_restore_mtimes.py, which used each file's last commit time and so needed 100 commits of history.)

  ci_file_times.py            every tracked file
  ci_file_times.py --check    print how many files it would set, change nothing
"""
import os
import subprocess
import sys

BASE = 978307200          # 2001-01-01, UTC
SPAN = 5 * 365 * 86400    # five years of seconds to spread the times over


def time_for(blob):
    """The time for a file whose git blob hash is `blob`: the same for the same contents, different for different ones (as far as 32 bits tell apart)."""
    return BASE + int(blob[:8], 16) % SPAN


def tracked_blobs(cwd=None):
    """Every tracked file with its blob hash, from the index (`mode blob stage<TAB>path`)."""
    out = subprocess.run(["git", "ls-files", "-s", "-z"], capture_output=True, check=True, cwd=cwd).stdout.decode()
    files = {}
    for entry in filter(None, out.split("\0")):
        meta, path = entry.split("\t", 1)
        files[path] = meta.split()[1]
    return files


def main():
    check = "--check" in sys.argv
    files = tracked_blobs()
    dirty = set(subprocess.run(["git", "diff", "--name-only", "-z", "HEAD"], capture_output=True, check=True).stdout.decode().split("\0")) - {""}
    done = 0
    for path, blob in files.items():
        if path in dirty or not os.path.isfile(path) or os.path.islink(path):
            continue
        if not check:
            t = time_for(blob)
            os.utime(path, (t, t))
        done += 1
    print(f"{'would set' if check else 'set'} {done} of {len(files)} files to the time of their contents")


if __name__ == "__main__":
    main()
