#!/usr/bin/env python3
"""Saves each site's rendered opt-out page, for analysis offline: opens the page the app would open in a real (headless) browser, waits
5 seconds after it loads, denies the cookie prompt, scrolls, and writes the page's HTML (and the HTML of each frame) to <out>/<domain>.html.
It fills nothing and sends nothing. <out>/index.tsv lists domain, address asked for, final address, status.

  PLAYWRIGHT_BROWSERS_PATH=$PWD/.tools-browsers .tools-venv/bin/python tools/snapshot_pages.py [--dir directory] [--workers 10] [--out .rendered-html] [--only a.com,b.com]
"""
import argparse, asyncio, os, sys

import yamlio
sys.path.insert(0, os.path.dirname(__file__))
import live_forms as L
from playwright.async_api import async_playwright


def target(doc, domain):
    """The page to snapshot: the site's opt-out page, else a page a form was found on, else its home page."""
    return yamlio.http(doc.get("opt_out_url")) or yamlio.live_page(doc) or yamlio.form_page(doc) or f"https://{domain}/"


async def snap(browser, domain, url, out):
    if True:
        ctx = await browser.new_context(user_agent=L.UA, viewport={"width": 390, "height": 844}, is_mobile=True)
        page = await ctx.new_page(); status = ""; final = ""
        try:
            resp = await page.goto(url, wait_until="domcontentloaded", timeout=25000)
            status = str(resp.status if resp else "")
            await page.wait_for_timeout(5000)
            await L.deny_cookies(page); await page.wait_for_timeout(500)
            for y in range(0, 6000, 900):
                await page.evaluate(f"window.scrollTo(0,{y})"); await page.wait_for_timeout(80)
            final = page.url
            html = await page.content()
            for fr in page.frames[1:]:
                try:
                    if fr.url.startswith("http"): html += f"\n<!-- FRAME {fr.url} -->\n" + await fr.content()
                except Exception: pass
            with open(os.path.join(out, domain + ".html"), "w") as f: f.write(f"<!-- URL {final} -->\n" + html)
        except Exception as e:
            status = "error:" + str(e)[:60].replace("\t", " ").replace("\n", " ")
        finally:
            await ctx.close()
        return domain, url, final, status


async def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--dir", default="directory"); ap.add_argument("--workers", type=int, default=10)
    ap.add_argument("--out", default=".rendered-html"); ap.add_argument("--only", default=""); ap.add_argument("--redo-failed", action="store_true")
    a = ap.parse_args(); os.makedirs(a.out, exist_ok=True)
    targets = []
    for _, s in yamlio.entries(a.dir):
        if "excluded" in s: continue
        d = s["domain"]
        if a.only and d not in a.only.split(","): continue
        if a.redo_failed and os.path.exists(os.path.join(a.out, d + ".html")): continue
        targets.append((d, target(s, d)))
    sem = asyncio.Semaphore(a.workers); done = 0
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        with open(os.path.join(a.out, "index.tsv"), "a" if a.redo_failed else "w") as idx:
            async def guarded(d, u):
                async with sem:         # wait for a free worker first, so queueing never counts against the site's own time
                    try: return await asyncio.wait_for(snap(browser, d, u, a.out), timeout=90)
                    except asyncio.TimeoutError: return d, u, "", "error:timed out"
            for coro in asyncio.as_completed([guarded(d, u) for d, u in targets]):
                r = await coro; done += 1
                idx.write("\t".join(r) + "\n"); idx.flush()
                if done % 50 == 0: print(f"{done}/{len(targets)}", flush=True)
        await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
