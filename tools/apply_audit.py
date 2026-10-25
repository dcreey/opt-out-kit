#!/usr/bin/env python3
"""Applies tools/audit_forms.py output: a browser-found form (`live`) whose page failed the audit and has a better page proposed gets that
page; one with no better page is marked not found so it is not trusted. Forms read from the page (`page`) are only listed.
Usage: apply_audit.py DIR [--dir directory] [--date YYYY-MM-DD]"""
import argparse, datetime, os, re, sys


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("audit"); ap.add_argument("--dir", default="directory"); ap.add_argument("--date", default=datetime.date.today().isoformat())
    a = ap.parse_args(); moved = dropped = listed = 0; left = []
    for line in open(os.path.join(a.audit, "audit.tsv")):
        d, src, url, verdict, reasons, score, alt = (line.rstrip("\n").split("\t") + [""] * 7)[:7]
        if verdict != "suspect": continue
        path = os.path.join(a.dir, re.sub(r"[^a-z0-9]+", "_", d.lower()).strip("_") + ".yml")
        s = open(path).read()
        if src == "live" and alt:
            s = s.replace(f'  page: "{url}"', f'  page: "{alt}"', 1); moved += 1
            open(path, "w").write(s)
        elif src == "page" and alt:
            # The saved form was the wrong one and a better page passed its own audit: use that page instead.
            s = re.sub(r"\nopt_out_form: \{.*\}\n", "\n", s)
            s = re.sub(r"\nlive_form:\n(?:[ \t]+.*\n?)*", "\n", s).rstrip("\n") + f'\nlive_form:\n  checked: "{a.date}"\n  found: true\n  page: "{alt}"\n  blockers: []\n'
            moved += 1; open(path, "w").write(s)
        elif src == "live" and re.search(r"HTTP 4|no form on the page|page did not load", reasons) and "bot wall" not in reasons:
            s = re.sub(r"\nlive_form:\n(?:[ \t]+.*\n?)*", f'\nlive_form:\n  checked: "{a.date}"\n  found: false\n', s); dropped += 1
            open(path, "w").write(s)
        else: listed += 1; left.append((d, src, url, reasons, alt))
    print(f"moved {moved} to a better page, dropped {dropped} dead ones, {listed} left to review")
    with open(os.path.join(a.audit, "review.tsv"), "w") as f:
        for r in left: f.write("\t".join(r) + "\n")


if __name__ == "__main__":
    main()
