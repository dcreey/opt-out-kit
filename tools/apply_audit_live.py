#!/usr/bin/env python3
"""Promotes guided sites whose form the app's audit found (it now reads frames and modals) to a live form, so they become semi-automatic.

For each audited site whose form was found and filled, and whose directory entry has no live form, writes `live_form:` with found: true, the page the form was on, and what a
person must clear (the audit's blockers). Run tools/apply_audit_blockers.py on the same file afterwards to add business, agent, file, other and code blockers.

  apply_audit_live.py RESULTS.json [--dir directory]"""
import argparse, datetime, json, os, re

import yamlio


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("results"); ap.add_argument("--dir", default="directory"); a = ap.parse_args()
    n = 0
    for x in json.load(open(a.results)):
        if not x.get("formFound") or not str(x.get("outcome", "")).startswith("filled"): continue
        if any(f.get("type") == "password" or re.search(r"password|sign.?in|log.?in", f.get("label", ""), re.I) for f in x.get("fields", [])): continue       # a login form is not an opt-out
        path = yamlio.entry_path(a.dir, x["domain"])
        if not os.path.exists(path): continue
        doc = yamlio.load(path)
        if (doc.get("live_form") or {}).get("found") is True: continue          # already a live form: leave it
        page = x.get("finalURL") or x.get("opens") or ""
        blockers = list(dict.fromkeys(x.get("blockers") or []))
        doc["live_form"] = {"checked": str(datetime.date.today()), "found": True, "page": page.replace('"', "%22"), "blockers": blockers}
        yamlio.save(path, doc); n += 1
    print(n, "sites promoted to a live form")


if __name__ == "__main__":
    main()
