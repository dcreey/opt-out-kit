#!/usr/bin/env python3
"""Second pass of search profiling, with a real (headless) browser, for sites a plain request could not read.

For every directory entry whose `search_check` is undifferentiated / needs_browser and has a `candidate` request, it runs the
site's own name search in headless Chromium for a made-up name and a known common name, then classifies what happened:

  calibrated   the two pages differ and the known name shows up: a browser-based check works (`needs_browser: true`)
  terms_gate   the results sit behind an "I agree to our terms" prompt. We never click "I agree" for anyone
  blocked      a bot check appears. We never try to pass it
  undifferentiated  still cannot tell the pages apart

It declines cookie banners ("Reject all"), never accepts terms, honors robots.txt, uses an honest user agent and one
search per site at a time, and uses no personal data. Needs: python -m pip install playwright; playwright install chromium.

  python3 tools/browser_profile.py [--dir directory] [--workers 3] [--only domain,...] [--limit N]
"""
import argparse, asyncio, datetime, os, re, sys, urllib.parse

import yamlio
sys.path.insert(0, os.path.dirname(__file__))
import profile_brokers as P
import profile_search as S
from playwright.async_api import async_playwright

UA = "OptOutKit-Profiler/1.0 (open source; polite, robots.txt honored; headless browser)"
GATE = re.compile(r"acceptable use policy|by clicking [“\"']?i agree|i agree.{0,120}(terms|policy)|accept (the )?terms|you must agree", re.I)
CHALLENGE = re.compile("|".join(map(re.escape, P.HARD_CHALLENGE)), re.I)
REJECT = ["Reject All", "REJECT ALL", "Reject all", "Decline", "Deny", "Only necessary", "No thanks"]


# A terms gate is a prompt with an "I agree" button beside the terms text. Acceptable-use text in a page footer is not one.
GATE_JS = """(re) => { const rx = new RegExp(re, 'i'); let best = null;
  for (const el of document.querySelectorAll('div,section,form,dialog,[role=dialog]')) {
    const t = el.innerText || ''; if (!rx.test(t) || t.length > 9000) continue;
    if (!best || t.length < best.innerText.length) best = el; }
  if (!best) return false;
  const agree = /^\\s*(i agree|i accept|agree|accept)\\s*$/i;
  for (let up = best, d = 0; up && d < 4; up = up.parentElement, d++) {
    for (const b of up.querySelectorAll('button,a,[role=button],input[type=button],input[type=submit]')) {
      if (agree.test(b.innerText || b.value || '')) return true; } }
  return false; }"""


async def settle(page, max_s=12):
    last, stable = -1, 0
    for _ in range(max_s * 2):
        await page.wait_for_timeout(500)
        try: t = await page.inner_text("body")
        except Exception: continue
        loading = re.search(r"loading|please wait|searching", t, re.I) is not None
        if len(t) == last and not loading: stable += 1
        else: stable = 0
        last = len(t)
        if stable >= 4: return


async def decline_banner(page):
    for label in REJECT:
        try:
            await page.get_by_text(label, exact=True).first.click(timeout=800); return True
        except Exception: pass
    return False


async def run_search(ctx, req, first, last):
    """-> (visible_text, state) with state in ok / gate / blocked / error."""
    r = S.realise(req, first, last)
    page = await ctx.new_page()
    try:
        if r["method"] == "POST":
            origin = "{0.scheme}://{0.netloc}/".format(urllib.parse.urlsplit(r["url"]))
            await page.goto(origin, wait_until="domcontentloaded", timeout=25000)
            fields = [[urllib.parse.unquote_plus(k), urllib.parse.unquote_plus(v)] for k, _, v in (p.partition("=") for p in r["body"].split("&"))]
            await page.evaluate("""([action, fields]) => { const f = document.createElement('form'); f.method = 'POST'; f.action = action;
                fields.forEach(([k, v]) => { const i = document.createElement('input'); i.type = 'hidden'; i.name = k; i.value = v; f.appendChild(i); });
                document.body.appendChild(f); f.submit(); }""", [r["url"], fields])
            await page.wait_for_load_state("domcontentloaded", timeout=25000)
        else:
            await page.goto(r["url"], wait_until="domcontentloaded", timeout=25000)
        await settle(page)
        if await decline_banner(page): await settle(page, 5)
        text = re.sub(r"[ \\t]+", " ", await page.inner_text("body")) + "\n" + (await page.title())
        if CHALLENGE.search(text): return text, "blocked"
        if GATE.search(text) and await page.evaluate(GATE_JS, GATE.pattern): return text, "gate"
        return text, "ok"
    except Exception as e:
        return str(e)[:100], "error"
    finally:
        await page.close()


async def profile_one(browser, entry, sem):
    async with sem:
        sc = entry["check"]; cand = sc["candidate"]
        if not P.Fetcher().allowed(cand["url"]): return entry, {"status": "robots_disallowed"}
        ctx = await browser.new_context(user_agent=UA)
        try:
            tn, sn = await run_search(ctx, cand, *S.MADE_UP)
            if sn in ("gate", "blocked", "error"): return entry, {"status": {"gate": "terms_gate", "blocked": "blocked", "error": "undifferentiated"}[sn]}
            known = None
            for kn in S.KNOWN_NAMES:
                tk, sk = await run_search(ctx, cand, *kn)
                if sk in ("gate", "blocked"): return entry, {"status": "terms_gate" if sk == "gate" else "blocked"}
                if sk == "ok" and all(w.lower() in tk.lower() for w in kn): known = kn; break
                if tk == tn: break
            if known is None or tn == tk: return entry, {"status": "undifferentiated"}
            brand = re.sub(r"[^a-z]", "", P.registrable(entry["domain"]).split(".")[0])
            no_results, valid = S.mine(tn, tk, brand)
            if not valid: return entry, {"status": "undifferentiated"}
            uses_place = any(k in (cand["url"] + (cand.get("body") or "")) for k in ("{city}", "{state}", "{state_name}"))
            spec = {"search_url": cand["url"], "valid_page": valid, "no_results": no_results, "ignore_location": not uses_place, "needs_browser": True}
            if cand["method"] == "POST": spec["method"] = "POST"; spec["body"] = cand["body"]
            a = S.judge(200, tn, spec, " ".join(S.MADE_UP), S.KNOWN_PLACE["city"]); b = S.judge(200, tk, spec, " ".join(known), S.KNOWN_PLACE["city"])
            if a == "removed" and b == "listed":
                spec["calibration"] = {"listed_name": " ".join(known), **({"city": S.KNOWN_PLACE["city"], "state": S.KNOWN_PLACE["state"]} if uses_place else {})}
                return entry, {"status": "calibrated", **spec}
            return entry, {"status": "undifferentiated"}
        finally:
            await ctx.close()


def load_entries(d, only, limit):
    out = []
    for f, doc in yamlio.entries(d):
        check = doc.get("search_check") or {}
        if check.get("status") not in ("undifferentiated", "needs_browser", "terms_gate") or not check.get("candidate"): continue
        dom = doc["domain"]
        if only and dom not in only: continue
        out.append({"file": f, "domain": dom, "check": {"candidate": yamlio.plain(check["candidate"])}})
    return out[:limit] if limit else out


def write_result(entry, r):
    doc = yamlio.load(entry["file"])
    cand = entry["check"]["candidate"]
    r = {**r, "candidate": cand, "checked": datetime.date.today().isoformat()} if r["status"] != "calibrated" else {**r, "checked": datetime.date.today().isoformat()}
    doc.pop("search_check", None); doc["search_check"] = r
    yamlio.save(entry["file"], doc)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="directory"); ap.add_argument("--workers", type=int, default=3)
    ap.add_argument("--only", default=""); ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    entries = load_entries(a.dir, [x for x in a.only.split(",") if x], a.limit)
    sem = asyncio.Semaphore(a.workers)
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        results = await asyncio.gather(*(profile_one(browser, e, sem) for e in entries))
        await browser.close()
    from collections import Counter
    c = Counter()
    for e, r in results: write_result(e, r); c[r["status"]] += 1
    print(f"{len(results)} sites with a candidate search:", dict(c))


if __name__ == "__main__":
    asyncio.run(main())
