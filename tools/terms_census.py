#!/usr/bin/env python3
"""Read-only census of the "I agree to our terms" prompts that sit in front of search results.

For every directory site whose search_check is `terms_gate` it opens the home page in headless Chromium, copies the text of
the prompt, finds the linked Terms / Acceptable Use / Privacy pages and reads those too. It stores only a fingerprint
(SHA-256 of the whitespace-normalized text), the length and the page address, never the text, and it NEVER clicks
"I agree" or anything else. Sites sharing a fingerprint run the same terms, so one reviewed consent could cover them all.

  python3 tools/terms_census.py [--dir directory] [--out pipeline/terms-census.md] [--workers 4] [--lang fr]

With --lang it asks each site for its pages in that language (Accept-Language, then the page's own hreflang links, a language
switcher or a language path), checks the text really is in that language, and stores it under .terms-cache/<site>/<lang>/. A site
with no translation is reported as such and nothing is stored: the master list keeps the site's own words and never translates them.
"""
import argparse, asyncio, hashlib, os, re, sys, urllib.parse

import yamlio
sys.path.insert(0, os.path.dirname(__file__))
import profile_brokers as P
import terms_lang as TL
from playwright.async_api import async_playwright

UA = "OptOutKit-Profiler/1.0 (open source; polite, robots.txt honored; headless browser)"
GATE = re.compile(r"acceptable use policy|by clicking [“\"']?i agree|i agree.{0,120}(terms|policy)|accept (the )?terms|you must agree"
                  r"|j'accepte.{0,120}(conditions|politique)|accepter les conditions|acepto.{0,120}(términos|condiciones|política)|aceptar los términos"
                  r"|ich stimme.{0,120}(bedingungen|datenschutz)|nutzungsbedingungen akzeptieren", re.I)
DOC = re.compile(r"terms|acceptable use|privacy|conditions|confidentialité|mentions légales|términos|condiciones|privacidad|nutzungsbedingungen|datenschutz|agb", re.I)
LOCALES = {"en": "en-US", "fr": "fr-FR", "es": "es-ES", "de": "de-DE"}


STATES = ["alabama","alaska","arizona","arkansas","california","colorado","connecticut","delaware","district of columbia","florida","georgia","hawaii",
          "idaho","illinois","indiana","iowa","kansas","kentucky","louisiana","maine","maryland","massachusetts","michigan","minnesota","mississippi",
          "missouri","montana","nebraska","nevada","new hampshire","new jersey","new mexico","new york","north carolina","north dakota","ohio","oklahoma",
          "oregon","pennsylvania","rhode island","south carolina","south dakota","tennessee","texas","utah","vermont","virginia","washington",
          "west virginia","wisconsin","wyoming"]


def fp(text, domain=""):
    """Fingerprint of the text with the site's own name and state replaced by a placeholder, so two sites running the same
    terms compare equal. Everything else must match exactly (after whitespace and case normalization)."""
    norm = re.sub(r"\s+", " ", text).strip().lower()
    label = domain.split(".")[0]
    tokens = {label, label.replace("arrests", " arrests"), label.replace("courtrecords", " court records")} - {""}
    for st in sorted(STATES, key=len, reverse=True):
        norm = norm.replace(st, "{state}")
    for t in sorted(tokens, key=len, reverse=True): norm = norm.replace(t, "{site}")
    norm = re.sub(r"\{site\}\.(org|net|com|us)", "{site}", norm)
    norm = re.sub(r"(\{state\}\s*){2,}", "{state} ", norm)
    return hashlib.sha256(norm.encode()).hexdigest()[:12], len(norm)


async def prompt_text(page):
    """The smallest visible element that contains the gate wording."""
    js = """(re) => { const rx = new RegExp(re, 'i'); let best = null;
      for (const el of document.querySelectorAll('div,section,form,dialog,[role=dialog]')) {
        const t = (el.innerText || ''); if (!rx.test(t) || t.length > 9000) continue;
        if (!best || t.length < best.length) best = t; }
      return best; }"""
    return await page.evaluate(js, GATE.pattern)


CACHE = ".terms-cache"


def save_raw(domain, kind, name, text, lang="en"):
    d = os.path.join(CACHE, domain, *([] if lang == "en" else [lang])); os.makedirs(d, exist_ok=True)
    open(os.path.join(d, f"{kind}-{name}.txt"), "w").write(text)


async def switch_language(page, ctx, lang):
    """Moves `page` to its `lang` version when the site has one. Returns whether the text it now shows really is in that language."""
    js = """() => [...document.querySelectorAll('a[href], link[rel=alternate][hreflang]')]
              .map(a => [a.href, (a.innerText||'').trim(), a.getAttribute('hreflang')||''])"""
    declared = (await page.evaluate("() => document.documentElement.lang || ''")).lower()
    if declared.startswith(lang) or TL.detect_lang(await page.inner_text("body")) == lang: return True      # already served in it
    alt = TL.find_alternate(await page.evaluate(js), lang, page.url)
    if not alt or not P.Fetcher().allowed(alt): return False
    await page.goto(alt, wait_until="domcontentloaded", timeout=25000); await page.wait_for_timeout(4000)
    declared = (await page.evaluate("() => document.documentElement.lang || ''")).lower()
    return declared.startswith(lang) or TL.detect_lang(await page.inner_text("body")) == lang


async def one(browser, domain, sem, lang="en"):
    async with sem:
        ctx = await browser.new_context(user_agent=UA, locale=LOCALES[lang], extra_http_headers={"Accept-Language": f"{LOCALES[lang]},{lang};q=0.9,en;q=0.3"})
        page = await ctx.new_page()
        out = {"domain": domain, "prompt": None, "docs": [], "lang": lang, "translated": True}
        try:
            start = next((u for u in (f"https://{domain}/", f"https://www.{domain}/") if P.Fetcher().allowed(u)), None)
            if not start: return out
            await page.goto(start, wait_until="domcontentloaded", timeout=25000); await page.wait_for_timeout(7000)
            if lang != "en":
                out["translated"] = await switch_language(page, ctx, lang)
                if not out["translated"]: return out          # no translation: keep the original, store nothing
                start = page.url
            t = await prompt_text(page)
            if t: out["prompt"] = fp(t, domain); save_raw(domain, "prompt", "0", t, lang)
            links = await page.evaluate("() => [...document.querySelectorAll('a[href]')].map(a => [a.href, (a.innerText||'').trim()])")
            seen = set()
            for href, label in links:
                if not DOC.search(label + " " + href) or href in seen or not href.startswith("http"): continue
                if urllib.parse.urlsplit(href).netloc.split(".")[-2:] != urllib.parse.urlsplit(start).netloc.split(".")[-2:]: continue
                seen.add(href)
                if len(seen) > 4: break
                if not P.Fetcher().allowed(href): continue
                p2 = await ctx.new_page()
                try:
                    await p2.goto(href, wait_until="domcontentloaded", timeout=20000); await p2.wait_for_timeout(1500)
                    body = await p2.inner_text("body")
                    out["docs"].append({"url": href.split("#")[0], "title": (await p2.title())[:60], "fp": fp(body, domain)})
                    save_raw(domain, "doc", hashlib.sha1(href.encode()).hexdigest()[:8], f"URL: {href}\n{body}", lang)
                except Exception: pass
                finally: await p2.close()
        except Exception as e:
            out["error"] = str(e)[:80]
        finally:
            await ctx.close()
        return out


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="directory"); ap.add_argument("--out", default=""); ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--lang", default="en", choices=TL.LANGUAGES); ap.add_argument("--only", default="", help="comma-separated domains")
    a = ap.parse_args()
    if not a.out: a.out = "pipeline/terms-census.md" if a.lang == "en" else f"pipeline/terms-census-{a.lang}.md"
    domains = []
    for _, doc in yamlio.entries(a.dir):
        if any(isinstance(v, dict) and v.get("status") == "terms_gate" for v in doc.values()): domains.append(doc["domain"])
    if a.only: domains = a.only.split(",")             # named sites are read whether or not they show a terms gate
    sem = asyncio.Semaphore(a.workers)
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        rows = await asyncio.gather(*(one(browser, d, sem, a.lang) for d in domains)); await browser.close()
    prompts, docs = {}, {}
    for r in rows:
        if r["prompt"]: prompts.setdefault(r["prompt"][0], {"len": r["prompt"][1], "sites": []})["sites"].append(r["domain"])
        for d in r["docs"]: docs.setdefault(d["fp"][0], {"len": d["fp"][1], "title": d["title"], "sites": set(), "urls": set()})["sites"].add(r["domain"]); docs[d["fp"][0]]["urls"].add(d["url"])
    no_prompt = [r["domain"] for r in rows if not r["prompt"] and r["translated"]]
    untranslated = [r["domain"] for r in rows if not r["translated"]]
    lines = [f"# Terms census, {a.lang} (read-only; fingerprints only)", "",
             f"{len(rows)} terms-gated sites. Nothing was accepted. A fingerprint is a SHA-256 of the whitespace-normalized, lowercased text.", "",
             f"## Gate prompts: {len(prompts)} distinct texts", "", "| Fingerprint | Chars | Sites | Examples |", "|---|---|---|---|"]
    for h, v in sorted(prompts.items(), key=lambda kv: -len(kv[1]["sites"])):
        lines.append(f"| {h} | {v['len']} | {len(v['sites'])} | {', '.join(sorted(v['sites'])[:3])} |")
    if a.lang != "en":
        lines += ["", f"Sites with no {a.lang} version (their original wording stays as it is): {len(untranslated)} of {len(rows)}"]
    lines += ["", f"Sites where no prompt text could be read: {len(no_prompt)} ({', '.join(no_prompt[:6])}{'...' if len(no_prompt) > 6 else ''})",
              "", f"## Linked terms and policy pages: {len(docs)} distinct texts", "", "| Fingerprint | Chars | Sites | Page title | Example address |", "|---|---|---|---|---|"]
    for h, v in sorted(docs.items(), key=lambda kv: -len(kv[1]["sites"]))[:40]:
        lines.append(f"| {h} | {v['len']} | {len(v['sites'])} | {v['title']} | {sorted(v['urls'])[0]} |")
    open(a.out, "w").write("\n".join(lines) + "\n"); print("\n".join(lines[:30]))


if __name__ == "__main__":
    asyncio.run(main())
