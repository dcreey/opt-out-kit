#!/usr/bin/env python3
"""Look at an opt-out page the way a person would, and report what is really on it. Sends nothing.

Loads each URL in headless Chromium at phone size, denies cookie prompts, scrolls the whole page, then lists every visible form (its
fields, labels, required marks, buttons) and any bot check, and saves a full-page screenshot. Used to check what the crawler found.

  PLAYWRIGHT_BROWSERS_PATH=$PWD/.tools-browsers .tools-venv/bin/python tools/inspect_form.py URL [URL ...] [--out .inspect]
"""
import argparse, asyncio, json, os, re
from playwright.async_api import async_playwright

UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
DENY = re.compile(r"^\s*(reject( all)?( cookies)?|deny( all)?|decline( all)?|i do not accept cookies|only (necessary|essential)( cookies)?|necessary( cookies)? only|no,? thanks|disagree|refuse( all)?|do not accept)\s*$", re.I)
KNOWN = ["#onetrust-reject-all-handler", "#CybotCookiebotDialogBodyButtonDecline", "button#truste-consent-required", ".cc-deny", "[data-cookiefirst-action=reject]",
         "#cookie-reject", ".osano-cm-denyAll", "#didomi-notice-disagree-button", "button[aria-label*='Reject' i]"]

JS = """() => {
  const vis = e => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
  const label = e => { let t = '';
    if (e.id) { const l = document.querySelector('label[for="' + e.id + '"]'); if (l) t = l.innerText; }
    if (!t) { const p = e.closest('label'); if (p) t = p.innerText; }
    if (!t) t = e.getAttribute('aria-label') || e.placeholder || e.getAttribute('title') || '';
    if (!t && e.previousElementSibling) t = e.previousElementSibling.innerText || '';
    return t.replace(/\\s+/g, ' ').trim().slice(0, 80); };
  const out = [];
  document.querySelectorAll('form').forEach((f, i) => {
    const fields = [...f.querySelectorAll('input,select,textarea')].filter(e => !['hidden','submit','button','image'].includes(e.type)).map(e => ({
      type: e.tagName.toLowerCase() === 'select' ? 'select' : e.type, name: e.name || e.id, label: label(e), required: e.required || /\\*/.test(label(e)), visible: vis(e),
      options: e.tagName.toLowerCase() === 'select' ? [...e.options].slice(0, 8).map(o => o.text.trim()) : undefined }));
    const buttons = [...f.querySelectorAll('button,input[type=submit],input[type=button],a.button,[role=button]')].map(b => ({ text: (b.innerText || b.value || '').trim().slice(0, 40), visible: vis(b), type: b.type }));
    out.push({ index: i, action: f.getAttribute('action'), method: f.method, visible: vis(f), fields, buttons, text: f.innerText.replace(/\\s+/g, ' ').trim().slice(0, 200) }); });
  const frames = [...document.querySelectorAll('iframe')].map(f => f.src).filter(s => /captcha|turnstile|hcaptcha|recaptcha/i.test(s));
  return { title: document.title, forms: out, captchaFrames: frames, bodyLen: document.body.innerText.length }; }"""


async def deny_cookies(page):
    for sel in KNOWN:
        try:
            await page.locator(sel).first.click(timeout=700); return sel
        except Exception: pass
    for frame in page.frames:
        for role in ("button", "link"):
            try:
                for loc in await frame.get_by_role(role).all():
                    t = (await loc.inner_text(timeout=300)).strip()
                    if DENY.match(t): await loc.click(timeout=800); return t
            except Exception: pass
    return None


async def main():
    ap = argparse.ArgumentParser(); ap.add_argument("urls", nargs="+"); ap.add_argument("--out", default=".inspect")
    a = ap.parse_args(); os.makedirs(a.out, exist_ok=True)
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        for url in a.urls:
            ctx = await browser.new_context(user_agent=UA, viewport={"width": 390, "height": 844}, device_scale_factor=2, is_mobile=True)
            page = await ctx.new_page()
            try:
                await page.goto(url, wait_until="domcontentloaded", timeout=30000); await page.wait_for_timeout(5000)
                denied = await deny_cookies(page); await page.wait_for_timeout(800)
                for y in range(0, 12000, 700):
                    await page.evaluate(f"window.scrollTo(0,{y})"); await page.wait_for_timeout(120)
                await page.evaluate("window.scrollTo(0,0)")
                info = await page.evaluate(JS)
                name = re.sub(r"[^a-z0-9]+", "_", url.lower()).strip("_")[:60]
                await page.screenshot(path=os.path.join(a.out, name + ".png"), full_page=True)
                print("=" * 8, url, "| title:", info["title"], "| cookie prompt denied via:", denied, "| captcha frames:", info["captchaFrames"])
                for f in info["forms"]:
                    if not f["fields"]: continue
                    print(f"  form#{f['index']} visible={f['visible']} {f['method']} action={f['action']}")
                    for fld in f["fields"]: print("     field", json.dumps(fld))
                    print("     buttons", [b["text"] for b in f["buttons"] if b["visible"]], "| text:", f["text"][:110])
            except Exception as e:
                print("=" * 8, url, "ERROR", str(e)[:120])
            await ctx.close()
        await browser.close()

asyncio.run(main())
