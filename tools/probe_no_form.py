#!/usr/bin/env python3
"""A deep second look at sites recorded as having no opt-out form: both a phone-sized and a desktop-sized browser, longer waits, collapsed sections
opened, buttons clicked, frames read, and links followed three deep. Prints what it finds so a person can check each one.
Usage: probe_no_form.py LIST.tsv   (domain<TAB>opt-out page<TAB>has email<TAB>walled)"""
import asyncio, os, sys, urllib.parse
sys.path.insert(0, os.path.dirname(__file__))
import live_forms as L
import profile_brokers as P
from playwright.async_api import async_playwright


async def probe(browser, domain, start, mobile):
    ctx = await browser.new_context(user_agent=L.UA if mobile else None, viewport={"width": 390, "height": 844} if mobile else {"width": 1280, "height": 900}, is_mobile=mobile)
    own = P.registrable(domain); tried = set(); frontier = [u for u in (start, f"https://{domain}/") if u]
    try:
        for depth in range(3):
            nxt = []
            for u in frontier[:6]:
                if u in tried: continue
                tried.add(u)
                sc, blockers, links, final = await asyncio.wait_for(L.look(ctx, u), timeout=80)
                if sc and urllib.parse.urlsplit(final).path not in ("", "/"): return ("FORM", final, sc, blockers)
                if domain in L.WALLED: return ("WALL", u, 0, [])
                nxt += L.good_links(final, links, own)
            frontier = [u for u in nxt if u not in tried]
            if not frontier: break
        return ("none", "", 0, [])
    except Exception as e: return ("error", str(e)[:40], 0, [])
    finally: await ctx.close()


async def main():
    rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
    async with async_playwright() as p:
        browser = await p.chromium.launch(); sem = asyncio.Semaphore(6)
        async def one(r):
            async with sem:
                m = await probe(browser, r[0], r[1] or None, True)
                d = await probe(browser, r[0], r[1] or None, False) if m[0] != "FORM" else ("-", "", 0, [])
                return r[0], m, d
        for coro in asyncio.as_completed([one(r) for r in rows]):
            dom, m, d = await coro
            print(f"{dom}\tmobile={m[0]} {m[1][:90]} {m[2]}\tdesktop={d[0]} {d[1][:90]}", flush=True)
        await browser.close()


if __name__ == "__main__":
    asyncio.run(main())
