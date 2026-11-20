#!/usr/bin/env python3
"""Works out, from each broker's own privacy policy, whether an opt-out lasts or has to be repeated.

Reads the evidence tools/collect_about.py gathered (.about/<domain>.json) and writes a `persistence:` line into each directory file:
  result      permanent  - the policy says the opt-out is kept (a suppression list, "we will not add you again", "until you withdraw")
              temporary  - the policy says it can come back (data is collected again, the opt-out expires, you must resubmit, it is a browser cookie)
              unknown    - the policy does not say; treated like temporary for planning, because most brokers refill their data
  reup_months when to ask the person to do it again (6 to 12; none for permanent)
  quote       the sentence the verdict rests on, when there is one
Usage: describe_persistence.py [--about .about] [--dir directory] [--dry-run]
"""
import argparse, glob, json, os, re

import yamlio

PERMANENT = [
    r"permanently (opt|remov|suppress|delet)", r"suppression (list|file)", r"(will|shall|do) not (re-?add|re-?list|re-?publish|add you back|re-?collect)",
    r"remain(s)? (opted|removed|suppressed)", r"will not be (re-?added|re-?listed|re-?published)",
]
TEMPORARY = [
    r"re-?submit", r"submit (it|your request|another request|a new request) again", r"opt.?out again", r"renew(ed)? (your )?(opt|request)",
    r"(may|can|might|could) (re-?appear|be re-?added|be re-?listed|show up again|re-?populate|be re-?acquired|be collected again|be re-?published)",
    r"(newly|new) (collected|acquired|obtained|received) (records|information|data)", r"data (we|that we) (collect|obtain|receive) (in the future|later|after)",
    r"opt.?out.{0,60}expir|expir.{0,60}opt.?out", r"valid for (\d+|one|a|twelve|six) (year|month).{0,40}opt|opt.{0,60}valid for (\d+|one|a|twelve|six) (year|month)",
    r"opt.?out cookie|cookie.?based opt.?out|clear(ing)? (your )?cookies.{0,60}opt|opt.{0,60}clear(ing)? (your )?cookies",
    r"every (\d+|twelve|six|one|12|6) (months|years?).{0,60}(opt|request)|(opt|request).{0,60}every (\d+|twelve|six|one|12|6) (months|years?)",
]
COOKIE_KINDS = {"adtech", "marketing_data", "marketing_services", "location_data", "b2b", "lead_generation"}
DURATION = re.compile(r"(?:every|each|after|within|valid for|expires? (?:after|in))\s+(\d+|one|two|six|twelve|a)\s*(month|year)s?", re.I)
WORD = {"one": 1, "a": 1, "two": 2, "six": 6, "twelve": 12}
DEFAULT_MONTHS = {"people_search": 6, "arrests": 12, "marketing_data": 12, "adtech": 6, "location_data": 6, "lead_generation": 6}


def sentences(text):
    return [s.strip() for s in re.split(r"(?<=[.!?])\s+", text) if 25 < len(s.strip()) < 420]


def decide(policy_text, category):
    perm = temp = None
    months = None
    for s in sentences(policy_text or ""):
        low = s.lower()
        if not re.search(r"opt|remov|delet|suppress|resubmit|re-?submit", low): continue
        if re.search(r"additional information|verify your identity|authorized agent|identity verification", low): continue
        if perm is None and any(re.search(p, low) for p in PERMANENT) and not re.search(r"(not|never) (permanent|honou?red)", low): perm = s
        pats = TEMPORARY if category in COOKIE_KINDS else [p for p in TEMPORARY if "cookie" not in p]          # a cookie opt-out is the opt-out only for ad-style brokers
        if temp is None and any(re.search(p, low) for p in pats): temp = s
        m = DURATION.search(low)
        if m and months is None:
            n = WORD.get(m.group(1).lower()) or int(m.group(1)); months = n * (12 if m.group(2).lower().startswith("year") else 1)
    default = DEFAULT_MONTHS.get(category, 12)
    if temp:  # the policy itself says it can come back: the sentence wins over a general "we keep your opt-out" line
        return {"result": "temporary", "reup_months": max(6, min(12, months or default)), "quote": temp[:240]}
    if perm: return {"result": "permanent", "quote": perm[:240]}
    return {"result": "unknown", "reup_months": default if default <= 12 else 12}


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--about", default=".about"); ap.add_argument("--dir", default="directory"); ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(); counts = {}
    for f in sorted(glob.glob(os.path.join(a.dir, "*.yml"))):
        doc = yamlio.load(f)
        d = doc["domain"]
        cat = (doc.get("about") or {}).get("category") or "other"
        p = os.path.join(a.about, d + ".json")
        ev = json.load(open(p)) if os.path.exists(p) else {}
        text = ((ev.get("policy") or {}).get("text") or "") + " " + ((ev.get("home") or {}).get("text") or "")[:4000]
        out = decide(text, cat)
        src = (ev.get("policy") or {}).get("url") or (ev.get("home") or {}).get("url")
        if src and out["result"] != "unknown": out["source"] = src
        counts[out["result"]] = counts.get(out["result"], 0) + 1
        if a.dry_run: continue
        doc.pop("persistence", None); doc["persistence"] = out
        yamlio.save(f, doc)
    print(counts)


if __name__ == "__main__":
    main()
