#!/usr/bin/env python3
"""Opens sites whose crawl found no readable form in a real (headless) browser, so scripts run, and records whether an opt-out form is there.

For each site: its opt-out page, else its home page; denies cookie prompts; scrolls; lists the visible forms and picks the one that looks
like an opt-out (the same rules as the app's LiveFormPicker); if none, follows up to three opt-out looking links, two levels deep. It also
notes what a person would have to clear (a bot check, a terms prompt). It fills nothing and sends nothing and uses no personal data.

  PLAYWRIGHT_BROWSERS_PATH=$PWD/.tools-browsers .tools-venv/bin/python tools/live_forms.py [--dir directory] [--workers 8] [--out .live-forms] [--only a.com,b.com]
Writes <out>/shard-0.tsv for tools/apply_live_forms.py.
"""
import argparse, asyncio, glob, os, re, sys, urllib.parse
sys.path.insert(0, os.path.dirname(__file__))
import profile_brokers as P
from playwright.async_api import async_playwright

UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
DENY = re.compile(r"^\s*(reject( all)?( cookies| non-essential( cookies)?)?|deny( all)?|decline( all)?|i do not accept( cookies)?|only (necessary|essential)( cookies)?|necessary( cookies)? only|no,? thanks|disagree|refuse( all)?|do not accept)\s*$", re.I)
KNOWN = ["#onetrust-reject-all-handler", "#CybotCookiebotDialogBodyButtonDecline", "button#truste-consent-required", ".cc-deny", "[data-cookiefirst-action=reject]",
         "#cookie-reject", ".osano-cm-denyAll", "#didomi-notice-disagree-button", "button[aria-label*='Reject' i]", "#axeptio_btn_dismiss"]
MARKETING = re.compile(r"subscribe|free trial|get started|sign.?up|log.?in|sign.?in|search|book a|demo|contact us|get in touch|newsletter|join|download|add another", re.I)
OPTOUT = re.compile(r"opt.?out|do not sell|don.?t sell|do-not-sell|privacy|delete|deletion|remove|erase|request|rights|unsubscribe me", re.I)
IDENT = re.compile(r"first|last|name|email|e-mail|address|zip|postal|phone|city", re.I)
FORMS_JS = """() => {
  const vis = e => { const r = e.getBoundingClientRect(), s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
  const label = e => { let t = ''; if (e.id) { const l = document.querySelector('label[for="' + e.id + '"]'); if (l) t = l.innerText; }
    if (!t) { const p = e.closest('label'); if (p) t = p.innerText; } if (!t) t = e.getAttribute('aria-label') || e.placeholder || e.name || '';
    return t.replace(/\\s+/g, ' ').trim().slice(0, 80); };
  return [...document.querySelectorAll('form')].map(f => ({ visible: vis(f),
    fields: [...f.querySelectorAll('input,select,textarea')].filter(e => !['hidden','submit','button','image','reset'].includes(e.type) && vis(e)).map(e => ({ type: e.type || e.tagName.toLowerCase(), label: label(e), name: e.name || e.id || '' })),
    buttons: [...f.querySelectorAll('button,input[type=submit],input[type=button],[role=button]')].filter(vis).map(b => (b.innerText || b.value || '').trim().slice(0, 50)),
    text: (f.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 240) })); }"""
LINKS_JS = """() => [...document.querySelectorAll('a[href]')].map(a => [a.href, (a.innerText || '').trim().slice(0, 80)])"""
BLOCK_JS = """() => { const t = (document.body.innerText || '').toLowerCase(); const out = [];
  if (document.querySelector('iframe[src*="recaptcha"],iframe[src*="hcaptcha"],iframe[src*="challenges.cloudflare"],.cf-turnstile,[class*="turnstile" i],.g-recaptcha,[class*="captcha" i]')) out.push('check');
  if (/verify you are human|i.?m not a robot|confirm you are human/.test(t)) out.push('check');
  if (/by clicking.{0,40}i agree|i agree to (the )?terms|accept (the )?terms/.test(t)) out.push('terms');
  return [...new Set(out)]; }"""


def score(form):
    fields = [f for f in form["fields"] if f["type"] not in ("password",)]
    if not form["visible"] or not fields: return -100
    buttons = " ".join(form["buttons"]); s = 0
    if OPTOUT.search(buttons): s += 4
    if OPTOUT.search(form["text"]): s += 2
    if MARKETING.search(buttons): s -= 6
    if MARKETING.search(form["text"]) and not OPTOUT.search(buttons): s -= 3
    s += min(4, sum(1 for f in fields if IDENT.search(f["label"] + " " + f["name"])))
    if any(f["type"] == "email" or re.search("e-?mail", f["label"] + f["name"], re.I) for f in fields): s += 2
    if any(f["type"] == "password" for f in form["forms_pw"]) if False else False: s -= 8
    return s


async def deny_cookies(page):
    for sel in KNOWN:
        try: await page.locator(sel).first.click(timeout=600); return True
        except Exception: pass
    for frame in page.frames:
        try:
            for loc in await frame.get_by_role("button").all():
                if DENY.match((await loc.inner_text(timeout=250)).strip()): await loc.click(timeout=700); return True
        except Exception: pass
    return False


async def look(ctx, url):
    page = await ctx.new_page()
    try:
        await page.goto(url, wait_until="domcontentloaded", timeout=25000); await page.wait_for_timeout(4500)
        await deny_cookies(page); await page.wait_for_timeout(500)
        for y in range(0, 6000, 900): await page.evaluate(f"window.scrollTo(0,{y})"); await page.wait_for_timeout(80)
        forms = await page.evaluate(FORMS_JS)
        best = max(((score(f), f) for f in forms), key=lambda x: x[0], default=(-100, None))
        links = await page.evaluate(LINKS_JS)
        blockers = await page.evaluate(BLOCK_JS) if best[0] >= 4 else []
        return best[0] if best[0] >= 4 else None, blockers, links, page.url
    except Exception:
        return None, [], [], url
    finally:
        await page.close()


def good_links(base, links, own):
    seen, out = set(), []
    for href, text in links:
        u = urllib.parse.urljoin(base, href).split("#")[0]
        if not u.startswith("http") or u in seen: continue
        if P.registrable(urllib.parse.urlsplit(u).netloc) != own and not any(k in u for k in P.PORTALS): continue
        sc = P.link_score(u, text)
        if sc >= 6: seen.add(u); out.append((sc, u))
    return [u for _, u in sorted(out, reverse=True)[:3]]


async def site(browser, domain, opt_url, sem):
    async with sem:
        ctx = await browser.new_context(user_agent=UA, viewport={"width": 390, "height": 844}, is_mobile=True)
        try:
            own = P.registrable(domain); tried = set(); frontier = [u for u in (opt_url, f"https://{domain}/") if u]
            for depth in range(3):
                nxt = []
                for u in frontier[:4]:
                    if u in tried: continue
                    tried.add(u)
                    sc, blockers, links, final = await look(ctx, u)
                    if sc: return domain, "form", final, ";".join(("check:a bot check" if b == "check" else b) for b in blockers)
                    nxt += good_links(final, links, own)
                frontier = [u for u in nxt if u not in tried]
                if not frontier: break
            return domain, "none", "", ""
        except Exception as e:
            return domain, "error:" + str(e)[:40], "", ""
        finally:
            await ctx.close()


async def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--dir", default="directory"); ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--out", default=".live-forms"); ap.add_argument("--only", default="")
    a = ap.parse_args(); os.makedirs(a.out, exist_ok=True)
    targets = []
    for f in sorted(glob.glob(os.path.join(a.dir, "*.yml"))):
        s = open(f).read()
        if re.search(r"^opt_out_form: ", s, re.M): continue
        d = re.search(r'^domain: "([^"]+)"', s, re.M).group(1); m = re.search(r'^opt_out_url: "([^"]+)"', s, re.M)
        if a.only and d not in a.only.split(","): continue
        targets.append((d, m.group(1) if m else None))
    sem = asyncio.Semaphore(a.workers); done = 0
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        with open(os.path.join(a.out, "shard-0.tsv"), "w") as out:
            for coro in asyncio.as_completed([site(browser, d, u, sem) for d, u in targets]):
                d, r, page, bl = await coro; done += 1
                out.write(f"{d}\t{r}\t{page}\t{bl}\n"); out.flush()
                if done % 25 == 0: print(f"{done}/{len(targets)}", flush=True)
        await browser.close()


if __name__ == "__main__":
    asyncio.run(main())
