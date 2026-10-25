#!/usr/bin/env python3
"""Keeps business-only and non-broker sites out of the app, and documents each one.

Reads pipeline/not-personal-sites.json: {domain: {"kind": "business_only" | "not_a_data_broker", "reason": "..."}}. Writes an `excluded:` block into
each site's directory file (the app never loads a site that has one, and every tool skips it) and regenerates the table in
docs/EXCLUDED_SITES.md between its markers. Removing a site from the JSON and re-running puts it back.
Usage: apply_exclusions.py [--dir directory] [--date YYYY-MM-DD]
"""
import argparse, datetime, json, os, re

START, END = "<!-- excluded-table:start -->", "<!-- excluded-table:end -->"


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--dir", default="directory"); ap.add_argument("--date", default=datetime.date.today().isoformat())
    a = ap.parse_args(); listed = json.load(open("pipeline/not-personal-sites.json")); done = 0; rows = []
    for name in sorted(os.listdir(a.dir)):
        if not name.endswith(".yml"): continue
        path = os.path.join(a.dir, name); s = open(path).read()
        d = re.search(r'^domain: "([^"]+)"', s, re.M).group(1)
        had = re.search(r"\nexcluded:\n(?:[ \t]+.*\n?)*", s)
        s = re.sub(r"\nexcluded:\n(?:[ \t]+.*\n?)*", "\n", s).rstrip("\n") + "\n"
        if d in listed:
            e = listed[d]; checked = (re.search(r'checked: "([^"]+)"', had.group(0)).group(1) if had else a.date)
            s += f'excluded:\n  checked: "{checked}"\n  kind: "{e["kind"]}"\n  reason: {json.dumps(e["reason"])}\n'; done += 1
            rows.append((d, e["kind"], e["reason"]))
        open(path, "w").write(s)
    table = "| Site | Why it is kept out | Details |\n|---|---|---|\n" + "".join(
        f"| `{d}` | {'Business-only opt-out' if k == 'business_only' else 'Not a data broker'} | {r} |\n" for d, k, r in rows)
    doc = open("docs/EXCLUDED_SITES.md").read()
    block = f"{START}\n## Business-only and non-broker sites\n\nThe app shows only opt-outs that a person can use for their own personal data. These sites are loaded by no screen and crawled by no tool. Each has an `excluded:` block in `directory/`; the list comes from `pipeline/not-personal-sites.json` (`tools/apply_exclusions.py`).\n\n{table}{END}"
    if START in doc: doc = re.sub(re.escape(START) + r".*?" + re.escape(END), lambda m: block, doc, flags=re.S)
    else: doc = doc.rstrip("\n") + "\n\n" + block + "\n"
    open("docs/EXCLUDED_SITES.md", "w").write(doc)
    print(f"{done} sites excluded")


if __name__ == "__main__":
    main()
