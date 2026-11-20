#!/usr/bin/env python3
"""Survey every site's opt-out page for forms that are really sign-ups (subscribe, register, account, demo, contact sales).

Opens each site's recorded opt-out page in a headless browser, lists the visible forms, and flags a site when the page the app would use (its opt-out page)
redirects to a sign-up or login address, or when its forms carry sign-up wording or a password field and none looks like a privacy request. Fills nothing.

  PLAYWRIGHT_BROWSERS_PATH=$PWD/.tools-browsers .tools-venv/bin/python tools/survey_signup.py [--workers 8]
Writes pipeline/signup-survey.json: {domain: {url, final, flags: [...], forms: [{buttons, fields, head}]}}
"""
import argparse, asyncio, json, os, re, sys

import yamlio
sys.path.insert(0, os.path.dirname(__file__))
import live_forms as L
from playwright.async_api import async_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "pipeline", "signup-survey.json")
SIGNUP = re.compile(r"subscribe|newsletter|sign.?up|register(?!ed)|create (an? )?account|\bjoin\b|waitlist|\bdemo\b|free trial|get started|contact sales|talk to|activation|log.?in|sign.?in|shortlist|get in touch|send message|contact us|request a (quote|call)|book a|start (your )?(free )?trial", re.I)
OPTOUT = re.compile(r"opt.?out|do not sell|don.?t sell|privacy|delete|deletion|remov|erase|erasure|unsubscribe|suppress|rights|data subject|ccpa|gdpr|personal (information|data)", re.I)
BAD_PATH = re.compile(r"/(sign-?up|register|registration|login|log-in|signin|sign-in|pricing|trial|demo|get-started|subscribe|newsletter|contact-sales|checkout)(/|$|\?)", re.I)


def entries():
    for _, doc in yamlio.entries(os.path.join(ROOT, "directory")):
        if "excluded" in doc: continue
        url = yamlio.live_page(doc) or yamlio.form_page(doc) or yamlio.http(doc.get("opt_out_url"))
        if url: yield doc["domain"], url


async def one(ctx, item, sem):
    dom, url = item
    out = {"url": url, "final": None, "flags": [], "forms": []}
    if True:
        page = await ctx.new_page()
        try:
            await page.goto(url, wait_until="domcontentloaded", timeout=25000)
            await page.wait_for_timeout(3000)
            out["final"] = page.url
            if BAD_PATH.search(page.url.split("#")[0]) and not BAD_PATH.search(url): out["flags"].append("redirects to " + page.url)
            forms = await page.evaluate(L.FORMS_JS)
            vis = [f for f in forms if f.get("visible") and f.get("fields")]
            out["forms"] = [{"buttons": f["buttons"][:4], "head": f.get("head", "")[:60], "fields": [x["label"][:30] for x in f["fields"]][:6], "pw": any(x["type"] == "password" for x in f["fields"])} for f in vis[:6]]
            good = False
            for f in vis:
                text = " ".join(f["buttons"]) + " " + f.get("head", "")
                signup = bool(SIGNUP.search(text)) and not OPTOUT.search(" ".join(f["buttons"]))
                pw = any(x["type"] == "password" for x in f["fields"])
                if not signup and not pw and (OPTOUT.search(text + " " + f.get("text", "")) or len(f["fields"]) >= 3): good = True
            if vis and not good: out["flags"].append("every form looks like a sign-up, login or contact form")
        except Exception as e:
            out["flags"].append("could not open: " + type(e).__name__)
        finally:
            await page.close()
    return dom, out


async def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--workers", type=int, default=8); a = ap.parse_args()
    done = json.load(open(OUT)) if os.path.exists(OUT) else {}
    todo = [e for e in entries() if e[0] not in done]
    sem = asyncio.Semaphore(a.workers)
    async with async_playwright() as pw:
        browser = await pw.chromium.launch()
        ctx = await browser.new_context(user_agent=L.UA, viewport={"width": 390, "height": 844}, ignore_https_errors=True)
        async def bounded(e):
            async with sem:     # the wait for a free slot is not part of the page's time limit
                try: return await asyncio.wait_for(one(ctx, e, sem), 75)
                except Exception: return e[0], {"url": e[1], "final": None, "flags": ["timed out"], "forms": []}
        for i, t in enumerate(asyncio.as_completed([asyncio.create_task(bounded(e)) for e in todo])):
            dom, res = await t; done[dom] = res
            if i % 25 == 0: json.dump(done, open(OUT, "w"), indent=1, sort_keys=True); print(i, len(todo), flush=True)
        await browser.close()
    json.dump(done, open(OUT, "w"), indent=1, sort_keys=True)
    flagged = {d: v for d, v in done.items() if any(not f.startswith(("could not", "timed")) for f in v["flags"])}
    print("surveyed", len(done), "flagged", len(flagged))

asyncio.run(main())
