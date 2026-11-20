#!/usr/bin/env python3
"""Finds opt-out forms that live in an embedded frame (OneTrust, HubSpot, TrustSuperset, Google Forms and similar) and records the frame's own
address as the page to open, because the app's live path reads the top page only and cannot reach into another site's frame.

Usage: resolve_iframe_forms.py --domains a.com,b.com [--apply] [--dir directory] [--date YYYY-MM-DD]
Without --apply it only prints what it found: `domain<TAB>old page<TAB>frame page<TAB>score`.
"""
import argparse, asyncio, datetime, os, re, sys
sys.path.insert(0, os.path.dirname(__file__))
import live_forms as L
from playwright.async_api import async_playwright

SKIP = re.compile(r"recaptcha|hcaptcha|challenges\.cloudflare|cookiebot|onetrust\.com/consent|doubleclick|googletagmanager|facebook|clym-widget|hubspot\.com/feedback|youtube|vimeo", re.I)


def current_page(text):
    for pat in (r'^  page: "([^"]+)"', r'^opt_out_form: \{"page": "([^"]+)"', r'^opt_out_url: "([^"]+)"'):
        m = re.search(pat, text, re.M)
        if m: return m.group(1)
    return None


async def find(ctx, url):
    page = await ctx.new_page()
    try:
        await page.goto(url, wait_until="domcontentloaded", timeout=30000); await page.wait_for_timeout(5500)
        await L.deny_cookies(page); await page.wait_for_timeout(800)
        best = (-100, None)
        main = max((L.score(f, "privacy request") for f in await page.evaluate(L.FORMS_JS)), default=-100)
        for fr in page.frames[1:]:
            if not fr.url.startswith("http") or SKIP.search(fr.url): continue
            try: forms = await fr.evaluate(L.FORMS_JS)
            except Exception: continue
            for f in forms:
                sc = L.score(f, "privacy request opt out")
                if sc > best[0]: best = (sc, fr.url)
        return main, best
    except Exception: return -100, (-100, None)
    finally: await page.close()


async def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--domains", required=True); ap.add_argument("--apply", action="store_true")
    ap.add_argument("--dir", default="directory"); ap.add_argument("--date", default=datetime.date.today().isoformat())
    a = ap.parse_args()
    async with async_playwright() as p:
        browser = await p.chromium.launch(); sem = asyncio.Semaphore(6)
        async def one(d):
            path = os.path.join(a.dir, re.sub(r"[^a-z0-9]+", "_", d.lower()).strip("_") + ".yml")
            if not os.path.exists(path): return d, None, None, -100
            text = open(path).read(); old = current_page(text) or "https://" + d
            async with sem:
                ctx = await browser.new_context(user_agent=L.UA, viewport={"width": 390, "height": 844}, is_mobile=True)
                try: main_score, (score, frame) = await asyncio.wait_for(find(ctx, old), timeout=70)
                except asyncio.TimeoutError: main_score, (score, frame) = -100, (-100, None)
                finally: await ctx.close()
            if frame and score >= 5 and score > main_score:
                if a.apply:
                    text = re.sub(r"\nopt_out_form: \{.*\}\n", "\n", text)
                    text = re.sub(r"\nlive_form:\n(?:[ \t]+.*\n?)*", "\n", text).rstrip("\n") + f'\nlive_form:\n  checked: "{a.date}"\n  found: true\n  page: "{frame}"\n  blockers: []\n'
                    open(path, "w").write(text)
                return d, old, frame, score
            return d, old, None, score
        for coro in asyncio.as_completed([one(d) for d in a.domains.split(",")]):
            print("\t".join(str(x) for x in await coro), flush=True)
        await browser.close()


if __name__ == "__main__":
    asyncio.run(main())
