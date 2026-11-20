#!/usr/bin/env python3
"""Records in each site's `live_form.blockers` what the form audit showed only a person can answer, so the plan demotes the site to guided (or
puts a typed-code form last) before anything is opened.

  business  a required field asks for a company, job title, industry, role or relationship to the company
  agent     a required field asks for an authorized agent's details
  file      a required file upload or signature
  other     questions the app cannot read (a Google Form whose fields are all "Your answer")
  code      a required typed code or puzzle (the form stays semi-automated, but goes last)

Input is the audit's results.json. Usage: apply_audit_blockers.py RESULTS.json [--dir directory]"""
import argparse, datetime, json, os, re

import yamlio

RULES = [("business", r"company|organi[sz]ation|job|title|industry|role|department|purpose|relationship|division|how did you hear|research|your needs"),
         ("other", r"^your answer$"),
         ("agent", r"agent|on behalf|authori[sz]ed"), ("file", r"\bfile\b|upload|attach"),
         ("code", r"captcha|enter the (numbers|code|characters)|math|equation|five plus|verification code|security (code|check)")]


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("results"); ap.add_argument("--dir", default="directory"); a = ap.parse_args()
    n = 0
    for x in json.load(open(a.results)):
        if not x["formFound"]: continue
        req = [f["label"].lower() for f in x["fields"] if f["required"] and not f["filled"] and f["type"] not in ("checkbox", "radio", "hidden")]
        found = [name for name, pat in RULES if any(re.search(pat, l) for l in req)]
        path = yamlio.entry_path(a.dir, x["domain"])
        if not found or not os.path.exists(path): continue
        doc = yamlio.load(path)
        # A form read from the page has no live block yet: add one that only carries what the audit saw.
        live = doc.get("live_form") or {"checked": str(datetime.date.today()), "found": False}
        have = list(live.get("blockers") or [])
        live["blockers"] = have + [f for f in found if f not in have]
        doc["live_form"] = live
        yamlio.save(path, doc); n += 1
    print(n, "sites updated")


if __name__ == "__main__":
    main()
