#!/usr/bin/env python3
"""Keeps business-only and non-broker sites out of the app, and documents each one.

Reads pipeline/not-personal-sites.json: {domain: {"kind": "business_only" | "not_a_data_broker", "reason": "..."}}. Writes an `excluded:` block into
each site's directory file (the app never loads a site that has one, and every tool skips it) and regenerates the table in
docs/EXCLUDED_SITES.md between its markers. Removing a site from the JSON and re-running puts it back.
Usage: apply_exclusions.py [--dir directory] [--date YYYY-MM-DD]
"""
import argparse, datetime, json, os, re

import yamlio

START, END = "<!-- excluded-table:start -->", "<!-- excluded-table:end -->"


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--dir", default="directory"); ap.add_argument("--date", default=datetime.date.today().isoformat())
    a = ap.parse_args(); listed = json.load(open("pipeline/not-personal-sites.json")); done = 0; rows = []
    for name in sorted(os.listdir(a.dir)):
        if not name.endswith(".yml"): continue
        path = os.path.join(a.dir, name); doc = yamlio.load(path)
        d = doc["domain"]
        had = doc.pop("excluded", None)
        if d in listed:
            e = listed[d]
            doc["excluded"] = {"checked": had["checked"] if had else a.date, "kind": e["kind"], "reason": e["reason"]}; done += 1
            rows.append((d, e["kind"], e["reason"]))
        yamlio.save(path, doc)
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
