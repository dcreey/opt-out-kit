#!/usr/bin/env python3
"""Reads each site's privacy policy (and its opt-out page when it has one) in a real headless browser and writes down EVERY link in it with the words of the link
and the sentence around it, every email address, and every embedded frame. Links that look like a way to make a request (opt-out, do not sell, delete, access,
"submit a request", "click here" next to such words, a known privacy-request portal) are scored and listed first, so a person or a script can pick the real form.
Reads nothing personal, fills nothing, sends nothing.

  PLAYWRIGHT_BROWSERS_PATH=$PWD/.tools-browsers .tools-venv/bin/python tools/policy_links.py [--workers 6] [--site-timeout 90] [--out .guess/policy-links.json] [--only a.com,b.com]
Writes the JSON (one entry per site) and prints one line per site as it finishes.
"""
import argparse, asyncio, json, os, re, urllib.parse

import yamlio
from playwright.async_api import async_playwright

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
POLICY_PATHS = ["/privacy", "/privacy-policy", "/privacy-notice", "/privacy_policy", "/legal/privacy", "/legal/privacy-policy", "/policies/privacy", "/privacy-statement", "/privacypolicy"]
POLICY_LINK = re.compile(r"privacy|data.?protection|legal", re.I)
ASK = re.compile(r"opt.?out|do not sell|don.?t sell|do-not-sell|sell or share|limit the use|your privacy (choices|rights)|privacy (request|rights|choices|portal|center|centre)|"
                 r"(submit|make|file|send|exercise)[^.]{0,30}(request|right)|request (form|portal)|data (subject|access|deletion|request)|dsar|delete (my|your)|deletion|remov(e|al)|"
                 r"access (my|your)|ccpa|cpra|gdpr|webform|web form|online form|click here|here\b", re.I)
STRONG = re.compile(r"opt.?out|do not sell|do-not-sell|sell or share|privacy (request|rights|choices|portal)|request (form|portal)|data (subject|access|deletion|request)|dsar|delete (my|your)|removal|submit[^.]{0,20}request|exercise", re.I)
PORTAL = re.compile(r"datasubject\.com|privacyportal|onetrust\.com/webform|trustarc\.com|submit-irm|ketch\.com|transcend\.io|osano\.com|securiti|mine\.io|saymine|ethyca|privacyengine|trustsuperset|privacy-portal|"
                    r"datagrail|clym|usercentrics|cookiebot|bigid|privacy-central|privacycenter|\\.privacy\\.|my\\.onetrust|ccpa\.|request\.|\.zendesk\.com/hc/.*request|force\.com|service-now|servicenow|hs-sites|docs\.google\.com/forms|typeform|jotform|formstack|airtable\.com/shr|smartsheet", re.I)
PATHWORDS = re.compile(r"/(do-?not-?sell|donotsell|opt-?out|optout|remove-my|removal|privacy-?request|data-?request|ccpa|dsar|your-privacy-choices)", re.I)
SKIP = re.compile(r"^(mailto:|tel:|javascript:|#)|facebook\.com|twitter\.com|x\.com/|linkedin\.com|instagram\.com|youtube\.com|apple\.com/app|play\.google\.com|\.(png|jpg|svg|css|js)(\?|$)", re.I)
INDUSTRY = re.compile(r"optout\.networkadvertising\.org|optout\.aboutads\.info|youradchoices|iabprivacy\.com|optoutprescreen|donotcall\.gov|consumer\.ftc\.gov|oag\.ca\.gov|privacy\.ca\.gov", re.I)
DEEP = re.compile(r"ccpa|california|your (privacy )?rights|opt.?out|do.?not.?sell|data.?subject|privacy (notice|statement|policy|center|centre)|legal|consumer", re.I)
CONTACT = re.compile(r"contact", re.I)
BUTTON = re.compile(r"do not sell|don.?t sell|your privacy choices|privacy choices|opt.?out|manage (my )?(privacy|preferences)|california privacy", re.I)
ROUTE = re.compile(r"[^.]*(write to|send (a )?(letter|mail)|by mail|postal|P\.?O\.? Box|call (us|our|toll)|toll.?free|phone number|\\b\\d{3}[-. ]\\d{3}[-. ]\\d{4}\\b|use the (control|setting|toggle)|in the app)[^.]*\\.", re.I)
MAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
JS = """() => {
  const vis = e => { const r = e.getBoundingClientRect(); return r.width > 0 || r.height > 0; };
  const ctx = a => { let n = a.parentElement, t = ''; for (let i = 0; i < 4 && n; i++, n = n.parentElement) { t = (n.innerText || '').replace(/\\s+/g, ' ').trim(); if (t.length > 40) break; } return t.slice(0, 260); };
  return { title: document.title, text: (document.body.innerText || '').replace(/\\s+/g, ' ').slice(0, 400000),
    links: (() => { const out = []; const walk = r => { r.querySelectorAll('a[href]').forEach(a => out.push({ href: a.href, text: (a.innerText || a.getAttribute('aria-label') || a.title || '').replace(/\\s+/g, ' ').trim().slice(0, 140), ctx: ctx(a) }));
      r.querySelectorAll('*').forEach(e => { if (e.shadowRoot) walk(e.shadowRoot); }); }; walk(document); return out; })(),
    frames: [...document.querySelectorAll('iframe[src]')].map(f => f.src), forms: document.forms.length }; }"""

def queue(only):
    out = []
    for _, doc in yamlio.entries("directory"):
        if "excluded" in doc or "closed" in doc: continue
        d = doc["domain"]; u = doc.get("opt_out_url") or ""
        if only and d in only:            # a site named on the command line is always read
            out.append((d, u)); continue
        if "opt_out_form" in doc: continue
        live = doc.get("live_form") or {}
        if live.get("found") is True and "business" not in " ".join(str(b) for b in live.get("blockers") or []): continue
        if not only: out.append((d, u))
    return out

async def visit(ctx, url, clicks=False):
    page = await ctx.new_page()
    try:
        r = await page.goto(url, wait_until="domcontentloaded", timeout=15000)
        await page.wait_for_timeout(2500)
        # Footers are often built after the page loads: scroll to the very bottom, wait, and scroll again.
        for _ in range(2):
            for y in range(0, 40000, 2500): await page.evaluate("window.scrollTo(0,%d)" % y); await page.wait_for_timeout(80)
            await page.wait_for_timeout(1200)
        data = await page.evaluate(JS); data["status"] = r.status if r else 0; data["final"] = page.url
        if clicks:
            # A "Do Not Sell" or "Your Privacy Choices" that is a button, not a link: press it and read what opens (a dialog, a frame, another page).
            seen = {l["href"] for l in data["links"]}
            for name in ("button", "link"):
                try:
                    loc = page.get_by_role(name, name=BUTTON)
                    for i in range(min(2, await loc.count())):
                        try:
                            async with ctx.expect_page(timeout=2500) as pop: await loc.nth(i).click(timeout=2000)
                            np = await pop.value; data["links"].append({"href": np.url, "text": "(opened by pressing the button)", "ctx": ""}); await np.close()
                        except Exception:
                            try: await loc.nth(i).click(timeout=1500)
                            except Exception: pass
                        await page.wait_for_timeout(1500)
                        more = await page.evaluate(JS)
                        for l in more["links"]:
                            if l["href"] not in seen: seen.add(l["href"]); l["text"] = "(after pressing a privacy button) " + l["text"]; data["links"].append(l)
                        data["frames"] += [f for f in more["frames"] if f not in data["frames"]]
                except Exception: pass
        return data
    except Exception:
        return None
    finally:
        await page.close()

def score(link, host):
    h, t, c = link["href"], link["text"], link["ctx"]
    if SKIP.search(h): return 0, []
    why, n = [], 0
    if PORTAL.search(h): n += 4; why.append("portal host")
    if STRONG.search(t): n += 4; why.append("link text")
    elif ASK.search(t): n += 2; why.append("weak link text")
    if STRONG.search(h): n += 2; why.append("url words")
    if PATHWORDS.search(urllib.parse.urlparse(h).path): n += 3; why.append("url path")
    if STRONG.search(c): n += 2; why.append("sentence")
    if INDUSTRY.search(h): n = max(0, n - 6); why.append("industry-wide opt-out, not this site's own")
    other = urllib.parse.urlparse(h).netloc.replace("www.", "") != host.replace("www.", "")
    if other and n: n += 1
    return n, why

async def work(browser, d, opt_url, sem, results, out, limit):
    async with sem:
        async def run():
            ctx = await browser.new_context(user_agent=UA, viewport={"width": 1280, "height": 900})
            try:
                pages, seen = [], set()
                home = None
                for base in ("https://www." + d, "https://" + d):
                    home = await visit(ctx, base, clicks=True)
                    if home and home["status"] and home["status"] < 400: break
                    home = None
                host = urllib.parse.urlparse(home["final"]).netloc if home else "www." + d
                root = "https://" + host
                cands = []
                if opt_url: cands.append(opt_url)
                def mine(u):
                    h = urllib.parse.urlparse(u).netloc.replace("www.", "")
                    base = d.replace("www.", "")
                    return h == base or h.endswith("." + base) or base.endswith("." + h) or h.split(".")[-2:] == base.split(".")[-2:]
                if home:
                    cands += [l["href"].split("#")[0] for l in home["links"] if POLICY_LINK.search(l["href"] + " " + l["text"]) and not SKIP.search(l["href"]) and mine(l["href"])][:6]
                cands += [root + p for p in POLICY_PATHS]
                for u in dict.fromkeys(cands):
                    if len(pages) >= 2 or len(seen) >= 12: break
                    seen.add(u)
                    p = await visit(ctx, u)
                    if p and p["status"] < 400 and len(p["text"]) > 1500 and re.search(r"privacy|personal (information|data)", p["text"], re.I):
                        p["url"] = u; pages.append(p)
                # The policy often points to the page that holds the details (a legal site, a California notice, a rights page): read up to six of those too.
                deep = []
                for p in list(pages):
                    for l in p["links"]:
                        h = l["href"].split("#")[0]
                        if h in seen or SKIP.search(h) or not mine(h) or not DEEP.search(h + " " + l["text"]): continue
                        if h not in deep: deep.append(h)
                for u in deep[:4]:
                    seen.add(u)
                    p = await visit(ctx, u)
                    if p and p["status"] < 400 and len(p["text"]) > 800:
                        p["url"] = u; pages.append(p)
                links, emails, frames = {}, set(), set()
                for p in pages + ([home] if home else []):
                    for l in p["links"]:
                        if l["href"] not in links: links[l["href"]] = l
                    emails |= {m.replace("%20", "").strip(".") for m in MAIL.findall(p["text"]) + [l["href"][7:].split("?")[0] for l in p["links"] if l["href"].startswith("mailto:")]}
                    frames |= set(p["frames"])
                # A way to contact the site, for the ones with no request form and no email (the request goes in the contact form); and the sentences that name a
                # postal address, a phone number or a setting in an app.
                contact = []
                for p in pages + ([home] if home else []):
                    for l in p["links"]:
                        if CONTACT.search(l["href"] + " " + l["text"]) and mine(l["href"]) and not SKIP.search(l["href"]) and l["href"] not in [c["href"] for c in contact]:
                            contact.append({"href": l["href"], "text": l["text"]})
                routes = []
                for p in pages:
                    for m in ROUTE.finditer(p["text"]):
                        t = m.group(0).strip()
                        if 20 < len(t) < 300 and t not in routes and re.search(r"privacy|request|opt|delete|data|information", t, re.I): routes.append(t)
                scored = []
                for l in links.values():
                    n, why = score(l, host)
                    scored.append({"href": l["href"], "text": l["text"], "ctx": l["ctx"], "score": n, "why": why})
                scored.sort(key=lambda x: -x["score"])
                good = [x for x in scored if x["score"] >= 4]
                return {"d": d, "policy_pages": [p["url"] for p in pages], "home_ok": bool(home), "n_links": len(links), "emails": sorted(emails)[:8], "frames": sorted(frames)[:5], "contact_routes": contact[:4], "route_sentences": routes[:3],
                        "candidates": good[:10], "all": [{"href": x["href"], "text": x["text"]} for x in scored][:400]}
            finally:
                await ctx.close()
        try: r = await asyncio.wait_for(run(), timeout=limit)
        except asyncio.TimeoutError: r = {"d": d, "error": "timed out after %ds" % limit}
        except Exception as e: r = {"d": d, "error": type(e).__name__}
        results[d] = r
        json.dump(results, open(out, "w"))
        print("done %s: %s" % (d, ("%d policy page(s), %d links, %d candidate(s)%s" % (len(r.get("policy_pages", [])), r.get("n_links", 0), len(r.get("candidates", [])), (", top: " + r["candidates"][0]["href"][:80]) if r.get("candidates") else "")) if "error" not in r else r["error"]), flush=True)

async def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--workers", type=int, default=6); ap.add_argument("--site-timeout", type=int, default=90)
    ap.add_argument("--out", default=".guess/policy-links.json"); ap.add_argument("--only", default=""); ap.add_argument("--blind", action="store_true", help="ignore the page on file (for testing the crawl against known answers)"); a = ap.parse_args()
    only = set(filter(None, a.only.split(","))); q = queue(only)
    if a.blind: q = [(d, "") for d, _ in q]
    print(len(q), "sites", flush=True)
    results = json.load(open(a.out)) if os.path.exists(a.out) and only else {}
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    sem = asyncio.Semaphore(a.workers)
    async with async_playwright() as pw:
        b = await pw.chromium.launch(headless=True)
        await asyncio.gather(*[work(b, d, u, sem, results, a.out, a.site_timeout) for d, u in q])
        await b.close()
    print("wrote", a.out, len(results), flush=True)
asyncio.run(main())
