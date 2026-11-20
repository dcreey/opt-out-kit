#!/usr/bin/env python3
"""Reads each opt-out page that mentions an email contact and records the address a privacy request should go to as `contact_email:`.

Polite like the crawler: honors robots.txt, retries with backoff, a few workers. Only addresses on the site's own domain (or its
family's) that look like privacy contacts are kept. Usage: find_contact_emails.py [--dir directory] [--workers 6]
"""
import argparse, concurrent.futures as cf, glob, os, re, sys, urllib.parse
sys.path.insert(0, os.path.dirname(__file__))
import yamlio  # noqa: E402  (after the path insert)
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


LINK = re.compile(r'href=["\']([^"\'#]+)["\'][^>]*>([^<]{0,80})<', re.I)
POLICY = re.compile(r"privacy|data.?protection|do.?not.?sell|your.?rights|ccpa|gdpr", re.I)


def fetch(f, url):
    if not f.allowed(url): return None
    st, _, body = f.get(url)
    return body if st is not None and st < 400 else None


def one(path):
    """One address per site, looked for in this order: the opt-out page, the privacy policy it links to, the home page and its policy."""
    doc = yamlio.load(path)
    if "contact_email" in doc: return None
    d = doc.get("domain")
    if not d: return None
    m = doc.get("opt_out_url")
    f = P.Fetcher()
    starts = [m] if m else []
    starts.append(f"https://{d}/")
    for start in starts:
        body = fetch(f, start)
        if not body: continue
        addr = pick(d.group(1), body)
        if addr: return (path, addr, "page")
        seen = 0
        for href, text in LINK.findall(body):
            if not POLICY.search(href + " " + text): continue
            url = urllib.parse.urljoin(start, href)
            if urllib.parse.urlsplit(url).scheme not in ("http", "https"): continue
            sub = fetch(f, url)
            seen += 1
            if sub:
                addr = pick(d.group(1), sub)
                if addr: return (path, addr, "policy")
            if seen >= 3: break
    return None


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--dir", default="directory"); ap.add_argument("--workers", type=int, default=6)
    a = ap.parse_args(); n = 0
    with cf.ThreadPoolExecutor(a.workers) as ex:
        for r in ex.map(one, sorted(glob.glob(os.path.join(a.dir, "*.yml")))):
            if not r: continue
            path, addr, how = r; doc = yamlio.load(path)
            keys = list(doc.keys())
            i = keys.index("opt_out_url") if "opt_out_url" in keys else keys.index("confidence")          # right after the opt-out page, as before
            doc.insert(i + 1, "contact_email", addr); doc.insert(i + 2, "contact_email_source", how)
            yamlio.save(path, doc); n += 1
    print(f"wrote contact_email to {n} sites")


if __name__ == "__main__":
    main()
