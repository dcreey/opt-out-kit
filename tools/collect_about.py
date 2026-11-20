#!/usr/bin/env python3
"""Collects what each broker says about itself: its home page description and its privacy policy text, for tools/describe_brokers.py.

Output: DIR/<domain>.json with {name, home: {title, description, headings, text}, policy: {url, text}, registry: {...}}.
Usage: collect_about.py --out .about [--only a.com,b.com] [--workers 8]
"""
import argparse, asyncio, json, os, re, sys, urllib.parse

import yamlio
sys.path.insert(0, os.path.dirname(__file__))
import live_forms as L
from playwright.async_api import async_playwright

POLICY_LINK = re.compile(r"privacy (policy|notice|statement)|privacy$|^privacy|data (privacy|protection)|your privacy|ccpa|california (privacy|consumer)", re.I)
PAGE_JS = """() => { const m = n => (document.querySelector('meta[name="' + n + '"],meta[property="' + n + '"]') || {}).content || '';
  return { title: document.title || '', description: m('description') || m('og:description'), site: m('og:site_name'),
    headings: [...document.querySelectorAll('h1,h2')].map(h => (h.innerText || '').trim()).filter(Boolean).slice(0, 8),
    text: (document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').trim().slice(0, 90000),
    links: [...document.querySelectorAll('a[href]')].map(a => [a.href, (a.innerText || '').trim().slice(0, 60)]).slice(0, 400) }; }"""


def registry():
    d = json.load(open("registries/all-brokers.json"))["brokers"]
    return {b["domain"]: b for b in d}


async def grab(ctx, url):
    page = await ctx.new_page()
    try:
        r = await page.goto(url, wait_until="domcontentloaded", timeout=25000); await page.wait_for_timeout(2500)
        if r is not None and r.status >= 400: return None
        await L.deny_cookies(page)
        return dict(await page.evaluate(PAGE_JS), url=page.url)
    except Exception: return None
    finally: await page.close()


async def one(browser, d, entry, reg, out, sem):
    async with sem:
        path = os.path.join(out, d + ".json")
        if os.path.exists(path): return
        ctx = await browser.new_context(user_agent=L.UA, viewport={"width": 1100, "height": 900})
        try:
            async def run():
                home = await grab(ctx, "https://" + d + "/") or await grab(ctx, "https://www." + d + "/")
                cands = list((reg.get("privacy_urls") or {}).values())
                url = entry.get("opt_out_url")
                if url and re.search(r"privacy|ccpa|rights|policy", url, re.I): cands.append(url)
                if home:
                    own = urllib.parse.urlsplit(home["url"]).netloc.replace("www.", "").split(".")[-2:]
                    for href, text in home["links"]:
                        if POLICY_LINK.search(text) and urllib.parse.urlsplit(href).netloc.replace("www.", "").split(".")[-2:] == own: cands.append(href)
                policy = None
                for u in dict.fromkeys(c if c.startswith("http") else "https://" + c for c in cands):
                    policy = await grab(ctx, u.rstrip(";"))
                    if policy and len(policy["text"]) > 1500: break
                if home: home.pop("links", None)
                if policy: policy.pop("links", None)
                return {"domain": d, "names": reg.get("names", []), "registered_in": reg.get("registered_in", []), "home": home, "policy": policy}
            data = await asyncio.wait_for(run(), timeout=180)
        except Exception as e:
            data = {"domain": d, "names": reg.get("names", []), "registered_in": reg.get("registered_in", []), "home": None, "policy": None, "error": str(e)[:80]}
        finally: await ctx.close()
        json.dump(data, open(path, "w"))


async def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--out", default=".about"); ap.add_argument("--only", default=""); ap.add_argument("--workers", type=int, default=8)
    a = ap.parse_args(); os.makedirs(a.out, exist_ok=True); reg = registry(); sem = asyncio.Semaphore(a.workers); todo = []
    for _, doc in yamlio.entries("directory"):
        if "closed" in doc or "excluded" in doc: continue
        d = doc["domain"]
        if a.only and d not in a.only.split(","): continue
        todo.append((d, doc))
    async with async_playwright() as p:
        browser = await p.chromium.launch(); done = 0
        for coro in asyncio.as_completed([one(browser, d, s, reg.get(d, {}), a.out, sem) for d, s in todo]):
            await coro; done += 1
            if done % 25 == 0: print(f"{done}/{len(todo)}", flush=True)
        await browser.close()


if __name__ == "__main__":
    asyncio.run(main())
