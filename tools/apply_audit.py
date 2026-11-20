#!/usr/bin/env python3
"""Applies tools/audit_forms.py output: a browser-found form (`live`) whose page failed the audit and has a better page proposed gets that
page; one with no better page is marked not found so it is not trusted. Forms read from the page (`page`) are only listed.
Usage: apply_audit.py DIR [--dir directory] [--date YYYY-MM-DD]"""
import argparse, datetime, os

import yamlio


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("audit"); ap.add_argument("--dir", default="directory"); ap.add_argument("--date", default=datetime.date.today().isoformat())
    a = ap.parse_args(); moved = dropped = listed = 0; left = []
    for line in open(os.path.join(a.audit, "audit.tsv")):
        d, src, url, verdict, reasons, score, alt = (line.rstrip("\n").split("\t") + [""] * 7)[:7]
        if verdict != "suspect": continue
        path = yamlio.entry_path(a.dir, d)
        doc = yamlio.load(path)
        live = doc.get("live_form")
        if src == "live" and alt:
            if live is not None and live.get("page") == url: live["page"] = alt
            moved += 1; yamlio.save(path, doc)
        elif src == "page" and alt:
            # The saved form was the wrong one and a better page passed its own audit: use that page instead.
            doc.pop("opt_out_form", None)
            doc["live_form"] = {"checked": a.date, "found": True, "page": alt, "blockers": []}
            moved += 1; yamlio.save(path, doc)
        elif src == "live" and any(w in reasons for w in ("HTTP 4", "no form on the page", "page did not load")) and "bot wall" not in reasons:
            if live is not None: doc["live_form"] = {"checked": a.date, "found": False}
            dropped += 1; yamlio.save(path, doc)
        else: listed += 1; left.append((d, src, url, reasons, alt))
    print(f"moved {moved} to a better page, dropped {dropped} dead ones, {listed} left to review")
    with open(os.path.join(a.audit, "review.tsv"), "w") as f:
        for r in left: f.write("\t".join(r) + "\n")


if __name__ == "__main__":
    main()
