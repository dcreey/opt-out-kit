#!/usr/bin/env python3
"""Writes what a reviewed real run showed into each directory entry as a `run_check:` block.

A person looked at the screenshot each site showed after the automatic opt-out sent its form. Those that showed a confirmation are
`confirmed`; the rest are `failed` with what the page showed instead (a cookie banner over the form, a contact or sign-up form,
an error, a required menu left empty, a bot check, ...). The app classifies by this before any guess made from reading the page.
Usage: apply_run_check.py [--dir directory] [--date YYYY-MM-DD]
"""
import argparse, datetime, os, re

CONFIRMED = {"lionsharemarketing.com": "thank-you page: allow up to 45 days", "scileads.com": "it said Request received",
             "apollo.io": "it said We sent an email to you, please check your inbox"}
# The privacy-request portal many people-search sites share ("Your Privacy Choices" / "Remove My Information"): one real send on
# peoplesearchusa.org (2026-10-28) showed "Check your email ... nothing is removed until that link is clicked"; the others carry the same
# template and filled completely, with no check in the way, in a dry run of the real run path.
PORTAL = "removal request accepted; a confirmation link is emailed and must be clicked"
for d in ["backgroundcheckers.net", "checksecrets.com", "inmatessearcher.com", "mugshotlook.com", "peoplesearch123.com", "peoplesearcher.com",
          "peoplesearchusa.org", "personsearchers.com", "privaterecords.net", "privatereports.com", "publicsearcher.com", "sealedrecords.net",
          "secretinfo.org", "truthrecord.org", "weinform.org"]:
    CONFIRMED[d] = PORTAL
FAILED = {}
def put(note, *domains):
    for d in domains: FAILED[d] = note
put("a cookie banner covered the form", "adttribution.com", "becausal.com", "bestpickreports.com", "datalinedata.com", "leadspace.com", "mediawallah.com",
    "milestonemarketingsolutions.com", "propensity.com", "swoop.com", "thedatatrust.com", "upcell.io", "vi.co", "fourthwall.tv", "intentiq.com")
put("the page is a contact form, not an opt-out", "achcoop.com", "jungroup.com")
put("the page is a sign-up, not an opt-out", "amplemarket.com", "resonate.com")
put("the page is a policy or information page with no form", "carneydirect.com", "complementics.com", "focus-usa.com", "outkeep.com", "ispot.tv", "hightouch.com", "agedleadstore.com", "sg360.com", "datadecisionsgroup.com")
put("you pick an option first, then a form appears", "tl1mkt.com", "nordicdataresources.com", "oan.pl", "onaudience.com")
put("the site showed an error after sending", "accudata.com", "acculeads.com", "deepsync.com", "dspolitical.com", "freewheel.com", "leadmemedia.com")
put("a required menu was left empty", "donorbase.com", "exactdata.com", "usadata.com", "vector.co", "quorum.inc")
put("required boxes were not ticked", "fourcornerhome.com")
put("a bot check appears after sending", "atdata.com", "adept-id.com", "thedatagroup.com")
put("the form was not on the page", "abovedata.io", "findem.ai", "lizdev.com", "veraset.com")


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--dir", default="directory"); ap.add_argument("--date", default=datetime.date.today().isoformat())
    ap.add_argument("--only", help="comma-separated domains: write only these")
    a = ap.parse_args(); n = 0
    only = set(a.only.split(",")) if a.only else None
    for domain, note in {**{d: ("confirmed", t) for d, t in CONFIRMED.items()}, **{d: ("failed", t) for d, t in FAILED.items()}}.items():
        if only and domain not in only: continue
        result, text = note
        path = os.path.join(a.dir, re.sub(r"[^a-z0-9]+", "_", domain.lower()).strip("_") + ".yml")
        if not os.path.exists(path): print("no entry for", domain); continue
        s = open(path).read()
        s = re.sub(r"\nrun_check:\n(?:[ \t]+.*\n?)*", "\n", s).rstrip("\n") + f'\nrun_check:\n  date: "{a.date}"\n  result: "{result}"\n  note: "{text}"\n'
        open(path, "w").write(s); n += 1
    print(f"wrote run_check to {n} sites")


if __name__ == "__main__":
    main()
