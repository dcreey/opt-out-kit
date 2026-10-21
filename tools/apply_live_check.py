#!/usr/bin/env python3
"""Writes the result of a live, no-send preview into each directory entry as a `live_check:` block.

Input is the LIVEPREVIEW lines printed by AppTests/LiveAssistedPreviewTests (run with TEST_RUNNER_OPTOUT_LIVE=1
TEST_RUNNER_OPTOUT_ONLY=all), one per site: `domain: blockers=[...]`. Each site's file gets what actually blocked the form when its
real page was loaded with a made-up profile: nothing, a visible bot check, a certification box or a terms prompt.
Nothing is sent anywhere. Usage: apply_live_check.py LOG [--dir directory] [--date YYYY-MM-DD]
"""
import argparse, datetime, os, re, sys


def parse(log):
    out = {}
    for line in open(log, errors="replace"):
        m = re.search(r"LIVEPREVIEW (\S+?): blockers=\[(.*?)\](?: fieldsToFill|$)", line)
        if not m: continue
        found = []
        for kind, text in re.findall(r'(check|certify|terms)(?:\("([^"]*)"\))?', m.group(2)):
            found.append(kind + (": " + text if text else ""))
        out[m.group(1)] = found
    return out


def block(date, blockers):
    items = ", ".join('"' + b.replace('"', "'") + '"' for b in blockers)
    return f"live_check:\n  checked: \"{date}\"\n  blockers: [{items}]\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log"); ap.add_argument("--dir", default="directory"); ap.add_argument("--date", default=datetime.date.today().isoformat())
    a = ap.parse_args()
    results = parse(a.log)
    done = 0
    for domain, blockers in results.items():
        path = os.path.join(a.dir, re.sub(r"[^a-z0-9]+", "_", domain.lower()).strip("_") + ".yml")
        if not os.path.exists(path): print("no entry for", domain, file=sys.stderr); continue
        text = open(path).read()
        text = re.sub(r"\nlive_check:\n(?:[ \t]+.*\n?)*", "\n", text)          # replace an older block
        text = text.rstrip("\n") + "\n" + block(a.date, blockers)
        open(path, "w").write(text); done += 1
    print(f"wrote live_check to {done} of {len(results)} sites; "
          f"{sum(1 for b in results.values() if not b)} had nothing blocking the form")


if __name__ == "__main__":
    main()
