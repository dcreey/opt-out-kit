#!/usr/bin/env python3
"""Records in each site's `live_form.blockers` what the form audit showed only a person can answer, so the plan demotes the site to guided (or
puts a typed-code form last) before anything is opened.

  business  a required field asks for a company, job title, industry, role or relationship to the company
  agent     a required field asks for an authorized agent's details
  file      a required file upload or signature
  other     questions the app cannot read (a Google Form whose fields are all "Your answer")
  code      a required typed code or puzzle (the form stays semi-automated, but goes last)

Input is the audit's results.json. Usage: apply_audit_blockers.py RESULTS.json [--dir directory]"""
import argparse, json, os, re

RULES = [("business", r"company|organi[sz]ation|job|title|industry|role|department|purpose|relationship|division|how did you hear|research|your needs"),
         ("other", r"^your answer$"),
         ("agent", r"agent|on behalf|authori[sz]ed"), ("file", r"\bfile\b|upload|attach|signature|e-?sign"),
         ("code", r"captcha|enter the (numbers|code|characters)|math|equation|five plus|verification code|security (code|check)")]


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("results"); ap.add_argument("--dir", default="directory"); a = ap.parse_args()
    n = 0
    for x in json.load(open(a.results)):
        if not x["formFound"]: continue
        req = [f["label"].lower() for f in x["fields"] if f["required"] and not f["filled"] and f["type"] not in ("checkbox", "radio", "hidden")]
        found = [name for name, pat in RULES if any(re.search(pat, l) for l in req)]
        path = os.path.join(a.dir, re.sub(r"[^a-z0-9]+", "_", x["domain"].lower()).strip("_") + ".yml")
        if not found or not os.path.exists(path): continue
        s = open(path).read(); m = re.search(r"(\nlive_form:\n(?:[ \t]+.*\n?)*)", s)
        if not m:   # a form read from the page has no live block yet: add one that only carries what the audit saw
            import datetime
            s = s.rstrip("\n") + f'\nlive_form:\n  checked: "{datetime.date.today()}"\n  found: false\n'; open(path, "w").write(s)
            m = re.search(r"(\nlive_form:\n(?:[ \t]+.*\n?)*)", s)
        block = m.group(1); b = re.search(r"  blockers: \[(.*)\]", block)
        have = [t.strip().strip('"') for t in b.group(1).split(",") if t.strip()] if b else []
        merged = have + [f for f in found if f not in have]
        line = "  blockers: [" + ", ".join(f'"{t}"' for t in merged) + "]"
        block2 = re.sub(r"  blockers: \[.*\]", line, block) if b else block.rstrip("\n") + "\n" + line + "\n"
        open(path, "w").write(s.replace(block, block2)); n += 1
    print(n, "sites updated")


if __name__ == "__main__":
    main()
