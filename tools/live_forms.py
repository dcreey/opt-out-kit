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
OPTOUT = re.compile(r"opt.?out|do not sell|don.?t sell|do-not-sell|privacy|delete|deletion|remove|erase|request|rights|unsubscribe|suppress|removal", re.I)
IDENT = re.compile(r"first|last|name|email|e-mail|address|zip|postal|phone|city", re.I)
FORMS_JS = """() => {
  const vis = e => { const r = e.getBoundingClientRect(), s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
  const label = e => { let t = ''; if (e.id) { const l = document.querySelector('label[for="' + e.id + '"]'); if (l) t = l.innerText; }
    if (!t) { const p = e.closest('label'); if (p) t = p.innerText; } if (!t) t = e.getAttribute('aria-label') || e.placeholder || e.name || '';
    if (!t) { let n = e.parentElement; for (let i = 0; i < 3 && n && !t; i++, n = n.parentElement) { const tx = (n.innerText || '').replace(/\\s+/g, ' ').trim(); if (tx && tx.length < 80) t = tx; } }
    return t.replace(/\\s+/g, ' ').trim().slice(0, 80); };
  const loose = [...document.querySelectorAll('input,select,textarea')].filter(e => !e.closest('form') && !['hidden','submit','button','image','reset','search'].includes(e.type) && vis(e));
  const pseudo = loose.length >= 1 ? [{ visible: true,
    fields: loose.map(e => ({ type: e.type || e.tagName.toLowerCase(), label: label(e), name: e.name || e.id || '' })),
    buttons: [...document.querySelectorAll('button,input[type=submit],[role=button]')].filter(vis).map(b => (b.innerText || b.value || '').trim().slice(0, 50)).slice(0, 12),
    text: (document.body.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 240) }] : [];
  const head = f => { let n = f; for (let i = 0; i < 6 && n; i++, n = n.parentElement) { let p = n.previousElementSibling; for (let j = 0; j < 8 && p; j++, p = p.previousElementSibling) { if (/^H[1-5]$/.test(p.tagName)) return (p.innerText || '').trim().slice(0, 80); const h = p.querySelector && p.querySelector('h1,h2,h3,h4,h5'); if (h) return (h.innerText || '').trim().slice(0, 80); } } return ''; };
  return pseudo.map(x => Object.assign(x, { head: '' })).concat([...document.querySelectorAll('form')].map(f => ({ visible: vis(f),
    head: head(f), fields: [...f.querySelectorAll('input,select,textarea')].filter(e => !['hidden','submit','button','image','reset'].includes(e.type) && vis(e)).map(e => ({ type: e.type || e.tagName.toLowerCase(), label: label(e), name: e.name || e.id || '' })),
    buttons: [...f.querySelectorAll('button,input[type=submit],input[type=button],[role=button]')].filter(vis).map(b => (b.innerText || b.value || '').trim().slice(0, 50)),
    text: (f.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 240) }))); }"""
PORTAL_HOSTS = re.compile(r"datasubject\.com|privacyportal|onetrust\.com/webform|trustarc\.com|clym|ketch\.com|transcend\.io|osano\.com|securiti|privacycockpit|mine\.io|saymine|ethyca|didomi|submit-irm|privacyengine\.io|trustsuperset\.com|privacy-portal|privacyprocessing\.com|atlassian\.net/servicedesk|\.zendesk\.com/hc/.*request|force\.com/.*(privacy|request|optout)", re.I)
# Links, plus the addresses of embedded privacy portals (a request form shown in a frame cannot be read from the page around it).
LINKS_JS = """() => [...document.querySelectorAll('a[href]')].map(a => [a.href, (a.innerText || '').trim().slice(0, 80), ((a.closest('p,li,td,h1,h2,h3,h4,div') || a.parentElement || {}).innerText || '').trim().slice(0, 160)])
  .concat([...document.querySelectorAll('iframe[src]')].map(f => [f.src, 'privacy portal request form']))"""
EMAIL_JS = """() => { const t = (document.body.innerText || ''); const m = [...document.querySelectorAll('a[href^="mailto:"]')].map(a => a.href.replace('mailto:', '').split('?')[0]);
  return [...new Set(m.concat(t.match(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}/g) || []))].slice(0, 12); }"""
WANT_MAIL = re.compile(r"privacy|dpo|optout|opt-out|dsar|rights|ccpa|gdpr|legal|compliance|dataprotection|consumer|removal|remove|unsubscribe|suppress|inquir", re.I)
BAD_MAIL = re.compile(r"sales@|support@|press@|careers?@|jobs@|billing@|abuse@|noreply|no-reply|example\.|sentry|wixpress|cloudflare|info@", re.I)
HOSTED_LANDING = r"datasubject\.com|atlassian\.net/servicedesk|submit-irm\.trustarc|privacyengine\.io|trustsuperset\.com"
# Clicks the first button or empty link whose words are about opting out (marked so it is clicked once); 1 when it clicked something.
CLICK_JS = """() => { const re = /do not sell|don.?t sell|opt.?out|your privacy choices|privacy choices|exercise.*rights|submit (a )?request|make a request/i;
  const el = [...document.querySelectorAll('button,[role=button],a')].find(e => !e.dataset.okClicked && re.test((e.innerText || '').trim()) && (e.innerText || '').trim().length < 60
    && (e.tagName !== 'A' || !e.getAttribute('href') || e.getAttribute('href').startsWith('#') || e.getAttribute('href').startsWith('javascript')));
  if (!el) return 0; el.dataset.okClicked = '1'; el.click(); return 1; }"""
BLOCK_JS = """() => { const t = (document.body.innerText || '').toLowerCase(); const out = [];
  if (document.querySelector('iframe[src*="recaptcha"],iframe[src*="hcaptcha"],iframe[src*="challenges.cloudflare"],.cf-turnstile,[class*="turnstile" i],.g-recaptcha,[class*="captcha" i]')) out.push('check');
  if (/verify you are human|i.?m not a robot|confirm you are human/.test(t)) out.push('check');
  if (/by clicking.{0,40}i agree|i agree to (the )?terms|accept (the )?terms/.test(t)) out.push('terms');
  return [...new Set(out)]; }"""


def score(form, ctx=""):
    fields = [f for f in form["fields"] if f["type"] not in ("password",)]
    if not fields: return -100          # a form wrapper can have no size while its fields show; only the fields count
    buttons = " ".join(form["buttons"]); s = 0
    if OPTOUT.search(buttons): s += 4
    if OPTOUT.search(form["text"]): s += 2
    if MARKETING.search(buttons): s -= 6
    if MARKETING.search(form["text"]) and not OPTOUT.search(buttons): s -= 3
    if OPTOUT.search(form.get("head", "")): s += 3          # the heading just above the form is about opting out
    if OPTOUT.search(ctx): s += 3          # the page's own address or title is about opting out
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
        resp = await page.goto(url, wait_until="domcontentloaded", timeout=25000); await page.wait_for_timeout(4500)
        await deny_cookies(page); await page.wait_for_timeout(500)
        for y in range(0, 6000, 900): await page.evaluate(f"window.scrollTo(0,{y})"); await page.wait_for_timeout(80)
        forms = await page.evaluate(FORMS_JS)
        if (resp is None or resp.status in (401, 403, 429, 503)) and not forms and WALL.search((await page.evaluate("document.body ? document.body.innerText : ''"))[:600]):
            WALLED.add(urllib.parse.urlsplit(url).netloc.replace("www.", ""))
        for fr in page.frames[1:]:                  # forms embedded in frames (HubSpot, Clym, Ketch) are read in their own frame
            try: forms += await fr.evaluate(FORMS_JS)
            except Exception: pass
        if resp is not None and resp.status >= 400: forms = []          # an error page is never the opt-out form (its search box is not)
        ctx = (await page.title()) + " " + urllib.parse.urlsplit(page.url).path
        best = max(((score(f, ctx), f) for f in forms), key=lambda x: x[0], default=(-100, None))
        # A "Do Not Sell or Share" button or empty link opens the form in a panel or a frame: click it and read again.
        if best[0] < 5 and not (resp is not None and resp.status >= 400):
            for _ in range(2):
                try:
                    n = await page.evaluate(CLICK_JS)
                    if not n: break
                    await page.wait_for_timeout(3000)
                    more = await page.evaluate(FORMS_JS)
                    for fr in page.frames[1:]:
                        try: more += await fr.evaluate(FORMS_JS)
                        except Exception: pass
                    cand = max(((score(f, ctx), f) for f in more), key=lambda x: x[0], default=(-100, None))
                    if cand[0] > best[0]: best = cand
                    if best[0] >= 5: break
                except Exception: break
        links = await page.evaluate(LINKS_JS)
        for m in await page.evaluate(EMAIL_JS):
            if WANT_MAIL.search(m) and not BAD_MAIL.search(m): MAILS.setdefault(urllib.parse.urlsplit(url).netloc.replace("www.", ""), m.lower())
        # A hosted privacy portal that opens on a choice (location, request type) shows its form only after one, so its landing page counts.
        if best[0] < 5 and re.search(HOSTED_LANDING, page.url): best = (5, best[1])
        blockers = await page.evaluate(BLOCK_JS) if best[0] >= 5 else []
        return best[0] if best[0] >= 5 else None, blockers, links, page.url
    except Exception:
        return None, [], [], url
    finally:
        await page.close()


MAILS = {}
WALL = re.compile(r"security verification|you have been blocked|sorry, you have been blocked|just a moment|attention required|verify you are (a )?human|access denied", re.I)
WALLED = set()


def good_links(base, links, own):
    seen, out = set(), []
    for href, text, *around in links:
        u = urllib.parse.urljoin(base, href).split("#")[0]
        if not u.startswith("http") or u in seen or "clym-widget.net" in u: continue     # a consent-widget bridge, not a form
        if P.registrable(urllib.parse.urlsplit(u).netloc) != own and not any(k in u for k in P.PORTALS) and not PORTAL_HOSTS.search(u) \
                and not re.search(r"opt[\\s_-]?out|do[\\s_-]?not[\\s_-]?sell|privacy[\\s_-]?request", u, re.I): continue
        sc = max(P.link_score(u, text), P.link_score(u, text + " " + (around[0] if around else "")) - 2) + (8 if PORTAL_HOSTS.search(u) else 0)
        if sc >= 6: seen.add(u); out.append((sc, u))
    return [u for _, u in sorted(out, reverse=True)[:5]]


async def site(browser, domain, opt_url, sem):
    async with sem:
        ctx = await browser.new_context(user_agent=UA, viewport={"width": 390, "height": 844}, is_mobile=True)
        try:
            own = P.registrable(domain); tried = set(); frontier = [u for u in (opt_url, f"https://{domain}/") if u]
            # Sites built from one template (the arrests and court-records families) keep their removal form at the same path.
            frontier += [f"https://{domain}/request-portal/", f"https://www.{domain}/request-portal/"]
            for depth in range(3):
                nxt = []
                for u in frontier[:6]:
                    if u in tried: continue
                    tried.add(u)
                    sc, blockers, links, final = await look(ctx, u)
                    if domain in WALLED: return domain, "none", "", "wall"        # a bot wall in front of the whole site: never retried
                    fh = urllib.parse.urlsplit(final)
                    if sc and (fh.path not in ("", "/") or P.registrable(fh.netloc) != fh.netloc.replace("www.", "")): return domain, "form", final, ";".join(("check:a bot check" if b == "check" else b) for b in blockers)
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
        if re.search(r'blockers: \["wall"\]', s): continue            # walled off by a bot check: not recrawled
        targets.append((d, m.group(1) if m else None))
    sem = asyncio.Semaphore(a.workers); done = 0
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        with open(os.path.join(a.out, "shard-0.tsv"), "w") as out:
            async def guarded(d, u):
                # A hard limit per site, tried twice, so one hung page can never stall the run.
                for _ in range(2):
                    try: return await asyncio.wait_for(site(browser, d, u, sem), timeout=240)
                    except asyncio.TimeoutError: pass
                return d, "error:timed out twice", "", ""
            for coro in asyncio.as_completed([guarded(d, u) for d, u in targets]):
                d, r, page, bl = await coro; done += 1
                mail = next((m for k, m in MAILS.items() if d.endswith(k) or k.endswith(d)), "")
                out.write(f"{d}\t{r}\t{page}\t{bl}\t{mail}\n"); out.flush()
                if done % 25 == 0: print(f"{done}/{len(targets)}", flush=True)
        await browser.close()


if __name__ == "__main__":
    asyncio.run(main())
