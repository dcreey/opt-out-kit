#!/usr/bin/env python3
"""For sites with no opt-out page on file (or one the crawl was walled from), opens the home page and the usual privacy-page paths in a real headless
browser, scores each page by how much it looks like an opt-out / privacy-request page, and writes the best guesses for a person to confirm.
Reads nothing personal, fills nothing, sends nothing.

  PLAYWRIGHT_BROWSERS_PATH=$PWD/.tools-browsers .tools-venv/bin/python tools/guess_optout_pages.py [--workers 8] [--out .guess/guesses.tsv] [--only a.com,b.com]
"""
import argparse, asyncio, glob, os, re, sys, urllib.parse
from playwright.async_api import async_playwright

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
PATHS = ["/app/optout/search", "/f/optout/search", "/optout/search", "/opt-out/search", "/optout-go", "/opt-out-request", "/optout-request", "/privacy/optout", "/privacy/opt-out", "/privacy/ccpa", "/privacy/do-not-sell", "/ccpa-opt-out", "/ccpa/optout", "/control", "/suppression", "/remove-listing", "/removal-request", "/do-not-sell-or-share", "/data-subject-request", "/rights", "/consumer-rights", "/privacy/rights", "/privacy-rights-request", "/privacy-choices", "/your-privacy-choices", "/do-not-sell", "/do-not-sell-my-personal-information", "/donotsell", "/opt-out", "/optout", "/opt_out",
         "/ccpa", "/privacy-rights", "/privacy-request", "/privacy/request", "/privacy", "/privacy-policy", "/privacy-center", "/remove", "/removal", "/remove-my-info",
         "/data-request", "/dsar", "/legal/privacy", "/legal/privacy-policy", "/legal/ccpa", "/california-privacy", "/ca-privacy"]
OPT = re.compile(r"do not sell|don.?t sell|opt.?out|your privacy choices|privacy choices|delete my|request to delete|right to delete|remove (my|your)|data subject|ccpa|exercise your", re.I)
LINKRE = re.compile(r"opt.?out|do.?not.?sell|privacy.?(choices|rights|request|center|centre)|ccpa|dsar|remov|delete|data.?request|your-privacy", re.I)
PORTAL = re.compile(r"datasubject\.com|privacyportal|onetrust\.com/webform|trustarc\.com|ketch\.com|transcend\.io|osano\.com|securiti|mine\.io|saymine|ethyca|submit-irm|privacyengine|trustsuperset|privacy-portal|zendesk\.com/hc/.*request|force\.com", re.I)
MAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
JS = """() => { const vis=e=>{const r=e.getBoundingClientRect();return r.width>0&&r.height>0};
  const inputs=[...document.querySelectorAll('input,select,textarea')].filter(e=>!['hidden','submit','button','image','reset','search','checkbox'].includes(e.type)&&vis(e)).length;
  return {text:(document.body.innerText||'').replace(/\\s+/g,' ').slice(0,6000), inputs, frames:[...document.querySelectorAll('iframe[src]')].map(f=>f.src),
    links:[...document.querySelectorAll('a[href]')].map(a=>[a.href,(a.innerText||'').trim().slice(0,70)]).slice(0,600), title:document.title}; }"""

def domains(only):
    out = []
    for f in sorted(glob.glob("directory/*.yml")):
        s = open(f).read()
        if re.search(r"^(excluded|closed):", s, re.M) or re.search(r"live_form:\n  checked: [^\n]*\n  found: true", s): continue
        if not (re.search(r"^opt_out_url: null", s, re.M) or 'blockers: ["wall"]' in s): continue
        if only is not None and False: pass
        d = re.search(r'^domain: "([^"]+)"', s, re.M).group(1)
        if not only or d in only: out.append(d)
    return out

def score(url, status, p):
    t = p["text"].lower(); n = 0; why = []
    if status and status >= 400: return -9, ["http %s" % status]
    if len(t) < 250: return -5, ["empty"]
    if re.search(r"page not found|404|no longer exists|not be found", p["title"].lower() + t[:300]): return -6, ["not found"]
    hits = len(OPT.findall(t)); n += min(hits, 4); why.append("terms:%d" % hits)
    if p["inputs"] >= 2: n += 3; why.append("form:%d" % p["inputs"])
    if any(PORTAL.search(f) for f in p["frames"]) or any(PORTAL.search(l[0]) for l in p["links"]): n += 3; why.append("portal")
    if re.search(r"/(opt.?out|do.?not.?sell|privacy.?(choices|rights|request)|ccpa|dsar|remov)", url, re.I): n += 1
    if re.search(r"just a moment|verify you are human|access denied|attention required", t[:400]): return -4, ["wall"]
    return n, why

async def visit(ctx, url):
    page = await ctx.new_page()
    try:
        r = await page.goto(url, wait_until="domcontentloaded", timeout=15000)
        await page.wait_for_timeout(1800)
        p = await page.evaluate(JS)
        return page.url, r.status if r else 0, p
    except Exception:
        return None
    finally:
        await page.close()

async def work(browser, d, sem, rows, out, limit):
    async with sem:
      try:
        r = await asyncio.wait_for(work_one(browser, d), timeout=limit)
      except asyncio.TimeoutError:
        r = (d, "", -9, "site timed out after %ds" % limit, "")
      except Exception as e:
        r = (d, "", -9, "error %s" % type(e).__name__, "")
      rows.append(r)
      with open(out, "a") as f: f.write("\t".join(str(x) for x in r) + "\n")
      print("done %s score=%s %s" % (r[0], r[2], r[1][:90]), flush=True)

async def work_one(browser, d):
    if True:
        ctx = await browser.new_context(user_agent=UA, viewport={"width": 1280, "height": 900})
        try:
            cands, seen, home = [], set(), None
            for base in ("https://www." + d, "https://" + d):
                v = await visit(ctx, base)
                if v and v[1] and v[1] < 400: home = v; break
            if not home: return (d, "", -9, "home unreachable", "")
            host = urllib.parse.urlparse(home[0])
            root = "%s://%s" % (host.scheme, host.netloc)
            for href, txt in home[2]["links"]:
                if LINKRE.search(href + " " + txt) and not href.startswith(("mailto:", "tel:", "javascript:")) and href.split("#")[0] not in seen:
                    seen.add(href.split("#")[0]); cands.append(href.split("#")[0])
            cands = cands[:8] + [root + p for p in PATHS]
            best = (-99, "", [], ""); mails = set(MAIL.findall(home[2]["text"]))
            tried = 0
            for u in dict.fromkeys(cands):
                if tried >= 60: break
                tried += 1
                v = await visit(ctx, u)
                if not v: continue
                final, st, p = v
                sc, why = score(final, st, p)
                if sc > best[0]: best = (sc, final, why, p["title"][:60])
                for m in MAIL.findall(p["text"]):
                    if re.search(r"privacy|optout|opt-out|dsar|legal|compliance|remov", m, re.I): mails.add(m)
                if sc >= 8: break
            return (d, best[1], best[0], ",".join(best[2]), best[3] + " | " + " ".join(sorted(mails)[:3]))
        finally:
            await ctx.close()

async def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--workers", type=int, default=8); ap.add_argument("--out", default=".guess/guesses.tsv"); ap.add_argument("--only", default=""); ap.add_argument("--chrome", action="store_true"); ap.add_argument("--site-timeout", type=int, default=120)
    a = ap.parse_args(); ds = domains(set(filter(None, a.only.split(","))))
    print(len(ds), "sites", flush=True)
    rows = []; sem = asyncio.Semaphore(a.workers)
    os.makedirs(os.path.dirname(a.out), exist_ok=True); open(a.out, "w").close()
    async with async_playwright() as pw:
        b = await pw.chromium.launch(headless=not a.chrome, channel="chrome" if a.chrome else None)
        await asyncio.gather(*[work(b, d, sem, rows, a.out, a.site_timeout) for d in ds])
        await b.close()
    print("wrote", a.out, len(rows), flush=True)
asyncio.run(main())
