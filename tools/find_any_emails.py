#!/usr/bin/env python3
"""For sites with no email on file: opens the home page, then the privacy, terms, contact and similar pages (found by link text and by common paths) in a real
browser and lists every address on the site's own domain (mailto links and text), with the page it came from. Generic ones (support@, info@, contact@) are kept
and labelled, because for many small sites that is the only way in. Writes a TSV and does not change the directory.

  python3 tools/find_any_emails.py --sites .guess/site-review.html [--skip-file tagged.txt] [--out .guess/any-emails.tsv] [--workers 6]
"""
import argparse, asyncio, json, re, sys
from urllib.parse import urljoin, urlparse
from playwright.async_api import async_playwright

EM = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
JUNK = re.compile(r"example\.|sentry|wixpress|cloudflare|noreply|no-reply|\.(png|jpe?g|gif|svg|webp)$", re.I)
PATHS = ["/privacy", "/privacy-policy", "/terms", "/terms-of-service", "/terms-and-conditions", "/contact", "/contact-us", "/about", "/legal", "/imprint"]
LINKWORDS = re.compile(r"privacy|terms|contact|legal|imprint|about|opt.?out|remove|do not sell|ccpa", re.I)
GENERIC = re.compile(r"^(info|support|contact|hello|admin|sales|help|service|team|office|mail)@", re.I)
KIND = [("privacy", r"privacy|dpo|dataprotection|optout|opt-out|removal|remove|delete|ccpa|gdpr|dsar"), ("legal", r"legal|compliance|abuse|copyright|dmca")]

def reg(host):
    p = host.lower().removeprefix("www.").split("."); return ".".join(p[-2:])

def kind(a):
    for k, rx in KIND:
        if re.search(rx, a.split("@")[0], re.I): return k
    return "generic" if GENERIC.match(a) else "other"

async def scan(ctx, site, sem):
    d = site["d"]; found = {}
    async with sem:
        page = await ctx.new_page()
        try:
            async def grab(url):
                try:
                    await page.goto(url, wait_until="domcontentloaded", timeout=15000); await page.wait_for_timeout(800)
                    html = await page.content(); text = await page.inner_text("body")
                    for m in re.findall(r"mailto:([^\"'?>\s]+)", html) + EM.findall(text) + EM.findall(html):
                        m = m.strip(".,;:()<>").lower()
                        if EM.fullmatch(m) and not JUNK.search(m) and reg(m.split("@")[1]) == reg(d): found.setdefault(m, page.url)
                    return await page.eval_on_selector_all("a[href]", "els=>els.map(e=>[e.href,(e.innerText||'').trim()])")
                except Exception: return []
            base = "https://" + d + "/"
            links = await grab(base)
            seen = {base}
            todo = [u for u, t in links if LINKWORDS.search(t) or LINKWORDS.search(urlparse(u).path)]
            todo = [u for u in todo if urlparse(u).hostname and reg(urlparse(u).hostname) == reg(d)][:6]
            todo += [urljoin(base, p) for p in PATHS]
            for u in todo[:12]:
                if u in seen: continue
                seen.add(u); await grab(u)
        except Exception: pass
        finally: await page.close()
    return d, found

async def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--sites", required=True); ap.add_argument("--skip-file"); ap.add_argument("--out", default=".guess/any-emails.tsv"); ap.add_argument("--workers", type=int, default=6)
    a = ap.parse_args()
    html = open(a.sites).read(); sites = json.loads(re.search(r'(\[\{"d":.*?\}\])', html, re.S).group(1))
    skip = set(open(a.skip_file).read().split()) if a.skip_file else set()
    sites = [s for s in sites if s["d"] not in skip]
    print(len(sites), "sites", file=sys.stderr)
    sem = asyncio.Semaphore(a.workers)
    async with async_playwright() as p:
        b = await p.chromium.launch(); ctx = await b.new_context(user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/124 Safari/537.36")
        tasks = [asyncio.wait_for(scan(ctx, s, sem), 90) for s in sites]
        out = open(a.out, "w"); n = 0
        for i, t in enumerate(asyncio.as_completed(tasks)):
            try: d, found = await t
            except Exception: continue
            for m, src in sorted(found.items(), key=lambda kv: ["privacy", "legal", "other", "generic"].index(kind(kv[0]))):
                out.write(f"{d}\t{m}\t{kind(m)}\t{src}\n"); n += 1
            out.flush()
            if (i + 1) % 20 == 0: print(i + 1, "done", file=sys.stderr)
        await b.close()
    print(n, "addresses ->", a.out, file=sys.stderr)
asyncio.run(main())
