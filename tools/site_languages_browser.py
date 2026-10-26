#!/usr/bin/env python3
"""Find the language pickers that only exist after the page's scripts run, which tools/site_languages.py cannot see.

Opens each site's home page and opt-out page in a real (headless) browser, then looks in the rendered page for:
  - links and <option>s whose text is a language's own name (Francais, Deutsch, ...), or whose address has a language path or ?lang= parameter;
  - the same after opening a language menu (a button or link labelled Language, a globe, or showing the current language code).
It fills nothing and sends nothing. Results are merged into pipeline/site-languages.json (adds only); then run `site_languages.py apply`.

  PLAYWRIGHT_BROWSERS_PATH=$PWD/.tools-browsers .tools-venv/bin/python tools/site_languages_browser.py [--workers 6] [--only a.com,b.com]
"""
import argparse, asyncio, json, os, re, sys, urllib.parse
sys.path.insert(0, os.path.dirname(__file__))
import site_languages as S
from playwright.async_api import async_playwright

UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
# A language's own name -> its code.
ENDONYMS = {"français": "fr", "francais": "fr", "deutsch": "de", "español": "es", "espanol": "es", "italiano": "it", "nederlands": "nl", "português": "pt", "portugues": "pt",
            "polski": "pl", "svenska": "sv", "dansk": "da", "suomi": "fi", "norsk": "nb", "ελληνικά": "el", "čeština": "cs", "magyar": "hu", "română": "ro", "türkçe": "tr",
            "日本語": "ja", "한국어": "ko", "中文": "zh", "简体中文": "zh", "繁體中文": "zh", "עברית": "he", "ไทย": "th", "tiếng việt": "vi", "bahasa indonesia": "id",
            "русский": "ru", "العربية": "ar", "български": "bg", "hrvatski": "hr", "slovenčina": "sk", "english": "en", "français (canada)": "fr", "español (méxico)": "es"}
CODES = {"en", "fr", "de", "es", "it", "nl", "pt", "pl", "sv", "da", "fi", "nb", "no", "el", "cs", "hu", "ro", "tr", "ja", "ko", "zh", "he", "th", "vi", "id", "ru", "ar", "bg", "hr", "sk", "sl", "lt", "lv", "et"}
COLLECT = r"""() => {
  const out = [];
  const vis = e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  document.querySelectorAll('a[href],option,[lang][href],[hreflang]').forEach(e => {
    const t = (e.innerText || e.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 40);
    out.push({ t, href: e.getAttribute('href') || e.value || '', lang: (e.getAttribute('lang') || e.getAttribute('hreflang') || '').toLowerCase(), vis: vis(e) });
  });
  return { html: (document.documentElement.getAttribute('lang') || '').toLowerCase(), items: out.slice(0, 1500) };
}"""
OPEN_MENU = r"""() => {
  const re = /^(language|languages|select language|choose language|change language|idioma|langue|sprache|lingua|taal|言語|언어)\b/i;
  for (const e of document.querySelectorAll('button,a,[role=button],[aria-haspopup],summary')) {
    const t = ((e.getAttribute('aria-label') || '') + ' ' + (e.innerText || '')).trim();
    const r = e.getBoundingClientRect();
    if (r.width > 0 && r.height > 0 && (re.test(t) || /^(en|us|en-us|en-gb|🌐)$/i.test((e.innerText || '').trim()) || /lang|locale|globe/i.test((e.className || '') + (e.id || '')))) { try { e.click(); return true; } catch (x) {} }
  }
  return false;
}"""


def classify(items, base):
    langs, pages = set(), {}
    for it in items:
        code = None
        t = it["t"].lower()
        if t in ENDONYMS: code = ENDONYMS[t]
        elif it["lang"] and it["lang"].split("-")[0] in CODES: code = it["lang"].split("-")[0]
        else:
            h = it["href"]
            m = re.search(r"[?&](?:lang|language|locale|hl)=([a-z]{2})(?:[-_][A-Za-z]{2})?\b", h) or re.search(r"^(?:https?://[^/]+)?/([a-z]{2})(?:-[a-z]{2})?/", h)
            if m and m.group(1) in CODES and (t in ENDONYMS or len(t) <= 3 or it["lang"]): code = m.group(1)
        if code:
            langs.add(code)
            if it["href"] and not it["href"].startswith(("javascript", "#")): pages.setdefault(code, urllib.parse.urljoin(base, it["href"]))
    return langs, pages


async def one(ctx, item, sem):
    f, dom, opt = item
    langs, pages = set(), {}
    async with sem:
        for url in dict.fromkeys(["https://" + dom + "/"] + ([opt] if opt else [])):
            page = await ctx.new_page()
            try:
                await page.goto(url, wait_until="domcontentloaded", timeout=20000)
                await page.wait_for_timeout(2500)
                for step in range(2):
                    data = await page.evaluate(COLLECT)
                    l, p = classify(data["items"], page.url)
                    if data["html"]: l.add(data["html"].replace("_", "-").split("-")[0])
                    l &= CODES
                    langs |= l
                    if url == opt: pages.update({k: v for k, v in p.items() if k in l})
                    if step == 0:
                        if not await page.evaluate(OPEN_MENU): break
                        await page.wait_for_timeout(800)
            except Exception:
                pass
            finally:
                await page.close()
    return dom, {"list": sorted(langs), "pages": pages}


async def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--workers", type=int, default=6); ap.add_argument("--only", default="")
    a = ap.parse_args()
    todo = [e for e in S.entries() if not a.only or e[1] in a.only.split(",")]
    data = json.load(open(S.OUT)) if os.path.exists(S.OUT) else {}
    done_path = S.OUT.replace(".json", "-browser.json")
    done = json.load(open(done_path)) if os.path.exists(done_path) else {}
    todo = [e for e in todo if e[1] not in done]
    sem = asyncio.Semaphore(a.workers)
    async with async_playwright() as pw:
        browser = await pw.chromium.launch()
        ctx = await browser.new_context(user_agent=UA, viewport={"width": 390, "height": 844}, ignore_https_errors=True)
        tasks = [asyncio.create_task(one(ctx, e, sem)) for e in todo]
        for i, t in enumerate(asyncio.as_completed(tasks)):
            dom, res = await t
            done[dom] = res
            if i % 25 == 0:
                json.dump(done, open(done_path, "w"), indent=1, sort_keys=True); print(i, len(todo), flush=True)
        await browser.close()
    json.dump(done, open(done_path, "w"), indent=1, sort_keys=True)
    added = 0
    for dom, res in done.items():
        cur = data.setdefault(dom, {"list": [], "pages": {}})
        before = set(cur["list"])
        cur["list"] = sorted(before | set(res["list"]))
        for k, v in res["pages"].items(): cur["pages"].setdefault(k, v)
        added += len(set(cur["list"]) - before)
    json.dump(data, open(S.OUT, "w"), indent=1, sort_keys=True)
    print("languages added from rendered pages:", added, "; sites now offered in a language other than English:", sum(1 for v in data.values() if set(v["list"]) - {"en"}))


asyncio.run(main())
