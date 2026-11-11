#!/usr/bin/env python3
"""Runs tools/policy_links.py on the sites of tools/crawl_regression.json and says which of them it finds the known opt-out route for.

  PLAYWRIGHT_BROWSERS_PATH=$PWD/.tools-browsers .tools-venv/bin/python tools/check_crawl.py [--out .guess/crawl-check.json] [--no-run]
Exit status 1 when any site misses its route.
"""
import argparse, json, os, subprocess, sys

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--out", default=".guess/crawl-check.json"); ap.add_argument("--no-run", action="store_true"); a = ap.parse_args()
    expect = {k: v for k, v in json.load(open("tools/crawl_regression.json")).items() if not k.startswith("_")}
    if not a.no_run:
        subprocess.run([sys.executable, "tools/policy_links.py", "--only", ",".join(expect), "--blind", "--out", a.out, "--workers", "4", "--site-timeout", "200"], check=False)
    got = json.load(open(a.out))
    ok = 0
    for d, want in expect.items():
        r = got.get(d, {})
        hrefs = [c["href"] for c in r.get("candidates", [])]
        hit = False
        if "link" in want: hit = any(want["link"] in h for h in hrefs)
        if "email" in want: hit = any(want["email"].lower() == e.lower() for e in r.get("emails", []))
        if "contact" in want: hit = any(want["contact"] in (c.get("href", "")) for c in r.get("contact_routes", []))
        ok += hit
        print(("PASS " if hit else "MISS ") + d + ("" if hit else "   wanted %s; top: %s" % (want, (hrefs[:1] or r.get("error") or ["nothing"]))))
    print("%d of %d found" % (ok, len(expect)))
    sys.exit(0 if ok == len(expect) else 1)
main()
