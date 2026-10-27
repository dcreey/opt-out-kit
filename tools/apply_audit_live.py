#!/usr/bin/env python3
"""Promotes guided sites whose form the app's audit found (it now reads frames and modals) to a live form, so they become semi-automatic.

For each audited site whose form was found and filled, and whose directory entry has no live form, writes `live_form:` with found: true, the page the form was on, and what a
person must clear (the audit's blockers). Run tools/apply_audit_blockers.py on the same file afterwards to add business, agent, file, other and code blockers.

  apply_audit_live.py RESULTS.json [--dir directory]"""
import argparse, datetime, json, os, re


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("results"); ap.add_argument("--dir", default="directory"); a = ap.parse_args()
    n = 0
    for x in json.load(open(a.results)):
        if not x.get("formFound") or not str(x.get("outcome", "")).startswith("filled"): continue
        if any(f.get("type") == "password" or re.search(r"password|sign.?in|log.?in", f.get("label", ""), re.I) for f in x.get("fields", [])): continue       # a login form is not an opt-out
        path = os.path.join(a.dir, re.sub(r"[^a-z0-9]+", "_", x["domain"].lower()).strip("_") + ".yml")
        if not os.path.exists(path): continue
        s = open(path).read()
        m = re.search(r"\nlive_form:\n(?:[ \t]+.*\n?)*", s)
        if m and re.search(r"  found: true", m.group(0)): continue          # already a live form: leave it
        page = x.get("finalURL") or x.get("opens") or ""
        blockers = list(dict.fromkeys(x.get("blockers") or []))
        block = '\nlive_form:\n  checked: "%s"\n  found: true\n  page: "%s"\n  blockers: [%s]\n' % (datetime.date.today(), page.replace('"', "%22"), ", ".join(json.dumps(b, ensure_ascii=False) for b in blockers))
        s = s.replace(m.group(0), block, 1) if m else s.rstrip("\n") + block
        open(path, "w").write(s); n += 1
    print(n, "sites promoted to a live form")


if __name__ == "__main__":
    main()
