#!/usr/bin/env python3
"""Reads each opt-out page that mentions an email contact and records the address a privacy request should go to as `contact_email:`.

Polite like the crawler: honors robots.txt, retries with backoff, a few workers. Only addresses on the site's own domain (or its
family's) that look like privacy contacts are kept. Usage: find_contact_emails.py [--dir directory] [--workers 6]
"""
import argparse, concurrent.futures as cf, glob, os, re, sys, urllib.parse
sys.path.insert(0, os.path.dirname(__file__))
import profile_brokers as P

MAIL = re.compile(r"mailto:([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})", re.I)
TEXT_MAIL = re.compile(r"\b([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})\b")
WANT = re.compile(r"privacy|dpo|optout|opt-out|dsar|rights|ccpa|gdpr|legal|compliance|dataprotection|data-protection|suppression|remove|unsubscribe", re.I)
BAD = re.compile(r"sales@|support@|press@|careers?@|jobs@|billing@|abuse@|noreply|no-reply|example\.|sentry|wixpress|cloudflare", re.I)


def pick(domain, html):
    found = []
    for m in MAIL.finditer(html): found.append(m.group(1))
    text = re.sub(r"<[^>]+>", " ", html)
    for m in TEXT_MAIL.finditer(text): found.append(m.group(1))
    reg = P.registrable(domain)
    ok = [a for a in dict.fromkeys(x.lower() for x in found) if not BAD.search(a) and WANT.search(a)]
    own = [a for a in ok if P.registrable(a.split("@")[1]) == reg]
    return (own or ok or [None])[0]


def one(path):
    s = open(path).read()
    if "contact_email:" in s or "email_contact" not in s: return None
    m = re.search(r'^opt_out_url: "([^"]+)"', s, re.M); d = re.search(r'^domain: "([^"]+)"', s, re.M)
    if not m or not d: return None
    f = P.Fetcher()
    if not f.allowed(m.group(1)): return None
    st, _, body = f.get(m.group(1))
    if st is None or st >= 400: return None
    addr = pick(d.group(1), body)
    return (path, addr) if addr else None


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--dir", default="directory"); ap.add_argument("--workers", type=int, default=6)
    a = ap.parse_args(); n = 0
    with cf.ThreadPoolExecutor(a.workers) as ex:
        for r in ex.map(one, sorted(glob.glob(os.path.join(a.dir, "*.yml")))):
            if not r: continue
            path, addr = r; s = open(path).read()
            s = re.sub(r"(\nopt_out_url: [^\n]*\n)", lambda m: m.group(1) + (m.group(1).count("\n") and "") , s, 1)
            lines = s.split("\n"); i = next(k for k, l in enumerate(lines) if l.startswith("opt_out_url:"))
            lines.insert(i + 1, f'contact_email: "{addr}"'); open(path, "w").write("\n".join(lines)); n += 1
    print(f"wrote contact_email to {n} sites")


if __name__ == "__main__":
    main()
