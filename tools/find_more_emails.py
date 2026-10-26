#!/usr/bin/env python3
"""Looks harder for the address a privacy request goes to, for sites that have neither a form nor an email on file.

Sources, in order: the policy text already gathered (.about), then a real browser on the site's own pages (home, privacy policy, contact,
do-not-sell and similar), reading mailto links and addresses written in the text. Only addresses on the site's own domain (or one it shares with
a parent company named in the page) that look like privacy contacts are kept, best first: privacy@, data protection, opt-out and removal
addresses before compliance or general inquiry ones. Writes `contact_email:` with source `page` (policy text) or `browser`.
Usage: find_more_emails.py [--apply]
"""
import argparse, asyncio, glob, json, os, re, sys
sys.path.insert(0, os.path.dirname(__file__))
import live_forms as L
import profile_brokers as P
from playwright.async_api import async_playwright

EM = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
RANK = [r"^privacy@", r"privacy", r"^(dpo|dataprotection|data-protection|dataprivacy)", r"opt.?out|removal|remove|delete|suppress|unsubscribe", r"dsar|rights|ccpa|gdpr|consumer", r"compliance|legal"]
BAD = re.compile(r"sales@|support@|press@|careers?@|jobs@|billing@|abuse@|noreply|no-reply|example\.|sentry|wixpress|cloudflare|info@|hello@|contact@|admin@|webmaster@|inquiries@|appeals|\.(png|jpg|gif|svg|webp)$", re.I)
PATHS = ["/privacy", "/privacy-policy", "/privacy-notice", "/legal/privacy", "/privacy-policy/", "/ccpa", "/do-not-sell", "/contact", "/contact-us", "/about/contact"]


def best(domain, candidates):
    own = P.registrable(domain)
    ok = [c.lower() for c in dict.fromkeys(candidates) if not BAD.search(c) and any(re.search(p, c.split("@")[0], re.I) for p in RANK)]
    ok = [c for c in ok if P.registrable(c.split("@")[1]) == own]          # the site's own domain only
    ok.sort(key=lambda c: min(i for i, p in enumerate(RANK) if re.search(p, c.split("@")[0], re.I)))
    return ok[0] if ok else None


async def browse(ctx, domain):
    found = []
    for path in PATHS:
        page = await ctx.new_page()
        try:
            r = await page.goto(f"https://{domain}{path}", wait_until="domcontentloaded", timeout=20000)
            if r is None or r.status >= 400: continue
            await page.wait_for_timeout(2500)
            found += await page.evaluate(L.EMAIL_JS)
            found += EM.findall(await page.evaluate("document.body ? document.body.innerText : ''"))
        except Exception: pass
        finally: await page.close()
        if best(domain, found): break
    return best(domain, found)


async def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--apply", action="store_true"); a = ap.parse_args()
    todo = []
    for f in sorted(glob.glob("directory/*.yml")):
        t = open(f).read()
        if re.search(r"^(closed|excluded):|^opt_out_form:|^  found: true|^contact_email:", t, re.M): continue
        todo.append((f, re.search(r'^domain: "([^"]+)"', t, re.M).group(1)))
    results = {}
    for f, d in todo:                                            # 1. the policy text we already have
        p = os.path.join(".about", d + ".json")
        if os.path.exists(p):
            ev = json.load(open(p)); text = ((ev.get("policy") or {}).get("text") or "") + " " + ((ev.get("home") or {}).get("text") or "")
            c = best(d, EM.findall(text))
            if c: results[d] = (c, "page")
    print(len(results), "from policy text of", len(todo), flush=True)
    async with async_playwright() as p:                          # 2. a browser on the site's own pages
        browser = await p.chromium.launch(); sem = asyncio.Semaphore(6)
        async def one(d):
            async with sem:
                ctx = await browser.new_context(user_agent=L.UA)
                try: return d, await asyncio.wait_for(browse(ctx, d), timeout=120)
                except Exception: return d, None
                finally: await ctx.close()
        rest = [d for f, d in todo if d not in results]
        for coro in asyncio.as_completed([one(d) for d in rest]):
            d, c = await coro
            if c: results[d] = (c, "browser")
        await browser.close()
    print(len(results), "addresses found in total")
    for f, d in todo:
        if d in results and a.apply:
            c, src = results[d]; t = open(f).read().rstrip("\n")
            open(f, "w").write(t + f'\ncontact_email: "{c}"\ncontact_email_source: "{src}"\n')
    json.dump({d: v[0] for d, v in results.items()}, open("/tmp/more_emails.json", "w"), indent=1)


if __name__ == "__main__":
    asyncio.run(main())
