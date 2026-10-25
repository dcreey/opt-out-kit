#!/usr/bin/env python3
"""Re-opens the page of every form we recorded (read from the page or found live) and checks it is the real opt-out form.

A form passes when the page loads, a form there scores as an opt-out form, the page itself is about opting out (title, address or the
heading above the form), and the form's buttons are not a newsletter, search, login or contact button. Anything else is `suspect` with
the reasons, and the crawler is run again from the site's home page to propose a better page (`alt`).
Output: TSV `domain, source, page, verdict, reasons, score, alt`. Usage: audit_forms.py --out DIR [--only a.com,b.com]
"""
import argparse, asyncio, glob, os, re, sys, urllib.parse
sys.path.insert(0, os.path.dirname(__file__))
import live_forms as L
import profile_brokers as P
from playwright.async_api import async_playwright

BAD_BUTTON = re.compile(r"subscribe|sign.?up|log.?in|sign.?in|search|newsletter|download|demo|get started|join", re.I)
ABOUT = re.compile(r"opt.?out|do not sell|don.?t sell|privacy|delete|deletion|remov|erase|request|rights|choices|unsubscribe|suppress|data subject|dsar|ccpa", re.I)


def targets(only):
    out = []
    for f in sorted(glob.glob("directory/*.yml")):
        s = open(f).read()
        if re.search(r"^(closed|excluded):", s, re.M): continue
        d = re.search(r'^domain: "([^"]+)"', s, re.M).group(1)
        if only and d not in only: continue
        m = re.search(r'^opt_out_form: \{"page": "([^"]+)"', s, re.M)
        if m: out.append((d, "page", m.group(1))); continue
        m = re.search(r'^live_form:\n  checked: "[^"]*"\n  found: true\n  page: "([^"]+)"', s, re.M)
        if m: out.append((d, "live", m.group(1)))
    return out


async def audit(ctx, url):
    audit.links = []
    page = await ctx.new_page(); reasons = []
    try:
        resp = await page.goto(url, wait_until="domcontentloaded", timeout=30000); await page.wait_for_timeout(4500)
        await L.deny_cookies(page); await page.wait_for_timeout(500)
        for y in range(0, 6000, 900): await page.evaluate(f"window.scrollTo(0,{y})"); await page.wait_for_timeout(80)
        try:
            if await page.evaluate(L.EXPAND_JS): await page.wait_for_timeout(1500)
        except Exception: pass
        forms = await page.evaluate(L.FORMS_JS)
        for fr in page.frames[1:]:
            try: forms += await fr.evaluate(L.FORMS_JS)
            except Exception: pass
        if max((L.score(f, "") for f in forms), default=-100) < 5:           # a button that opens the form in a panel or frame
            for _ in range(2):
                try:
                    if not await page.evaluate(L.CLICK_JS): break
                    await page.wait_for_timeout(3000); forms = await page.evaluate(L.FORMS_JS)
                    for fr in page.frames[1:]:
                        try: forms += await fr.evaluate(L.FORMS_JS)
                        except Exception: pass
                    if max((L.score(f, "") for f in forms), default=-100) >= 5: break
                except Exception: break
        title = await page.title(); path = urllib.parse.urlsplit(page.url).path
        text = (await page.evaluate("document.body ? document.body.innerText : ''"))[:1500]
        if resp is not None and resp.status >= 400:
            return -100, [f"HTTP {resp.status}"] if not L.WALL.search(text[:600]) else ["bot wall"]
        ctxs = title + " " + path
        scored = sorted(((L.score(f, ctxs), f) for f in forms), key=lambda x: -x[0])
        if re.search(L.HOSTED_LANDING, page.url): return 5, []      # a hosted portal that shows its form after a choice
        if not scored or scored[0][0] <= -100: return -100, ["no form on the page"]
        sc, best = scored[0]
        if sc < 5: reasons.append(f"best form scores {sc}")
        host = urllib.parse.urlsplit(page.url).netloc.replace("www.", "")
        if path in ("", "/") and P.registrable(host) == host: reasons.append("the page is a home page")
        if not ABOUT.search(ctxs + " " + best.get("head", "") + " " + text[:500]): reasons.append("page is not about opting out")
        bad = [b for b in best["buttons"] if BAD_BUTTON.search(b)]
        if bad and not any(L.OPTOUT.search(b) for b in best["buttons"]): reasons.append("button says " + bad[0])
        ident = sum(1 for f in best["fields"] if L.IDENT.search(f["label"] + " " + f["name"]))
        optout_page = L.OPTOUT.search(ctxs + " " + best.get("head", "") + " " + text[:300]) and re.search(r"do.?not.?sell|opt.?out|privacy|request|choices|rights", ctxs + " " + best.get("head", "") + " " + text[:300], re.I)
        if ident < 1 and not (optout_page and len(best["fields"]) >= 1 and (any(re.search(r"submit|send|request|continue|opt", b, re.I) for b in best["buttons"]) or re.search(r"rights form|request form|opt.?out form|privacy request", best.get("head", "") + " " + text[:300], re.I))):         # a form that opens as a first step (one menu) is still the form
            reasons.append("no name/email/address fields")
        audit.links = await page.evaluate(L.LINKS_JS)
        return sc, reasons
    except Exception as e:
        return -100, ["page did not load: " + re.sub(r"\s+", " ", str(e).split("Call log")[0])[:60]]
    finally: await page.close()


async def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--out", required=True); ap.add_argument("--only", default=""); ap.add_argument("--workers", type=int, default=8)
    a = ap.parse_args(); os.makedirs(a.out, exist_ok=True); sem = asyncio.Semaphore(a.workers)
    todo = targets(set(a.only.split(",")) if a.only else None)
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        async def one(d, src, url):
            # A hard limit per site, tried twice, so one hung page can never stall the run.
            for attempt in (1, 2):
                try: return await asyncio.wait_for(one_try(d, src, url), timeout=420)
                except asyncio.TimeoutError: pass
            return d, src, url, "suspect", "timed out twice", -100, ""
        async def one_try(d, src, url):
            async with sem:
                ctx = await browser.new_context(user_agent=L.UA, viewport={"width": 390, "height": 844}, is_mobile=True)
                try:
                    sc, reasons = await audit(ctx, url); alt = ""
                    if reasons:
                        # Candidates: the best opt-out links on this page and on the home page, plus the template path; each must pass its own audit.
                        own = P.registrable(d); links = list(audit.links)
                        try:
                            await audit(ctx, "https://" + d + "/"); links += audit.links
                        except Exception: pass
                        cands = L.good_links(url, links, own) + [f"https://{d}/request-portal/", f"https://www.{d}/request-portal/", f"https://www.{d}/privacy-request-portal", f"https://{d}/privacy-request-portal"]
                        for c in list(dict.fromkeys(cands))[:8]:
                            if c.split("#")[0] == url.split("#")[0]: continue
                            sc2, why2 = await audit(ctx, c)
                            if not why2 and sc2 >= 5: alt = c; break
                    return d, src, url, "suspect" if reasons else "ok", "; ".join(reasons), sc, alt
                finally: await ctx.close()
        done = 0
        with open(os.path.join(a.out, "audit.tsv"), "w") as out:
            for coro in asyncio.as_completed([one(*t) for t in todo]):
                out.write("\t".join(map(str, await coro)) + "\n"); out.flush(); done += 1
                if done % 25 == 0: print(f"{done}/{len(todo)}", flush=True)
        await browser.close()


if __name__ == "__main__":
    asyncio.run(main())
