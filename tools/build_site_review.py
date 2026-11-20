#!/usr/bin/env python3
"""Builds the one-page site review tool (an HTML page) from directory/*.yml: every site that has no readable form yet, one card per site, with tag buttons.
Tags are kept by the page itself (its shared database, or the browser when there is none) and exported as JSON for tools/apply_site_review.py.

  python3 tools/build_site_review.py [--out .guess/site-review.html]
"""
import argparse, json, os

import yamlio

SIG = {"captcha_recaptcha": "reCAPTCHA", "captcha_turnstile": "Cloudflare check", "captcha_hcaptcha": "hCaptcha", "captcha_datadome": "DataDome check",
       "email_contact": "email listed", "email_input": "has an email box", "email_only_wording": "wording says email", "phone_verify": "phone code", "phone_input": "phone box",
       "mail_option": "postal option", "id_required": "ID required", "account_hint": "account hint", "login_required": "login", "file_upload": "file upload",
       "listing_url_input": "asks for your listing link", "search_first": "search first", "name_input": "name box", "script_rendered_page": "page built by script",
       "script_rendered_form": "form built by script", "portal_osano": "Osano portal", "portal_trustarc": "TrustArc portal", "bot_check_on_home": "blocks scripts"}

def field(doc, key):
    v = doc.get(key)
    return str(v) if v is not None else ""

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--out", default=".guess/site-review.html"); ap.add_argument("--skip", default="", help="comma-separated domains already settled (tagged or corrected): left out"); ap.add_argument("--no-email-only", action="store_true", help="leave out sites that already have an email address as a way out"); ap.add_argument("--hide-later", action="store_true", help="leave out sites marked find_later"); a = ap.parse_args()
    skip = set(x.strip() for x in a.skip.split(",") if x.strip())
    sites = []
    for _, s in yamlio.entries("directory"):
        if "excluded" in s or "closed" in s: continue
        form = "opt_out_form" in s
        live = s.get("live_form") or {}
        found = live.get("found") is True
        blockers = " ".join(str(b) for b in (live.get("blockers") or []))
        business = found and "business" in blockers
        if (form or found) and not business: continue
        if field(s, "domain") in skip: continue
        url, mail = field(s, "opt_out_url"), field(s, "contact_email")
        if a.no_email_only and mail: continue
        if a.hide_later and s.get("find_later") is True: continue
        sig = [str(x) for x in (s.get("signals") or [])]
        why = ("A form on its page asks for business details, so the app only walks you to it" if business else
               "Its page has no form the app can read" if url else "No opt-out page on file" + (" (the site blocked our scan)" if "wall" in blockers else ""))
        sites.append({"d": field(s, "domain"), "n": field(s, "name"), "u": url, "e": mail, "w": why, "s": [SIG[x] for x in sig if x in SIG][:8], "p": int(s.get("priority") or 0)})
    sites.sort(key=lambda x: -x["p"])
    tpl = open("tools/site_review_template.html").read()
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    open(a.out, "w").write(tpl.replace("/*SITES*/[]", json.dumps(sites, separators=(",", ":"))))
    print(len(sites), "sites ->", a.out)
main()
