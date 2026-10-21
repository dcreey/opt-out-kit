#!/usr/bin/env python3
"""Read-only census of the "I agree to our terms" prompts that sit in front of search results.

For every directory site whose search_check is `terms_gate` it opens the home page in headless Chromium, copies the text of
the prompt, finds the linked Terms / Acceptable Use / Privacy pages and reads those too. It stores only a fingerprint
(SHA-256 of the whitespace-normalized text), the length and the page address, never the text, and it NEVER clicks
"I agree" or anything else. Sites sharing a fingerprint run the same terms, so one reviewed consent could cover them all.

  python3 tools/terms_census.py [--dir directory] [--out pipeline/terms-census.md] [--workers 4]
"""
import argparse, asyncio, glob, hashlib, json, os, re, sys, urllib.parse
sys.path.insert(0, os.path.dirname(__file__))
import profile_brokers as P
from playwright.async_api import async_playwright

UA = "OptOutKit-Profiler/1.0 (open source; polite, robots.txt honored; headless browser)"
GATE = re.compile(r"acceptable use policy|by clicking [“\"']?i agree|i agree.{0,120}(terms|policy)|accept (the )?terms|you must agree", re.I)
DOC = re.compile(r"terms|acceptable use|privacy", re.I)


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


def save_raw(domain, kind, name, text):
    d = os.path.join(CACHE, domain); os.makedirs(d, exist_ok=True)
    open(os.path.join(d, f"{kind}-{name}.txt"), "w").write(text)


async def one(browser, domain, sem):
    async with sem:
        ctx = await browser.new_context(user_agent=UA); page = await ctx.new_page()
        out = {"domain": domain, "prompt": None, "docs": []}
        try:
            start = next((u for u in (f"https://{domain}/", f"https://www.{domain}/") if P.Fetcher().allowed(u)), None)
            if not start: return out
            await page.goto(start, wait_until="domcontentloaded", timeout=25000); await page.wait_for_timeout(7000)
            t = await prompt_text(page)
            if t: out["prompt"] = fp(t, domain); save_raw(domain, "prompt", "0", t)
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
                    save_raw(domain, "doc", hashlib.sha1(href.encode()).hexdigest()[:8], f"URL: {href}\n{body}")
                except Exception: pass
                finally: await p2.close()
        except Exception as e:
            out["error"] = str(e)[:80]
        finally:
            await ctx.close()
        return out


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="directory"); ap.add_argument("--out", default="pipeline/terms-census.md"); ap.add_argument("--workers", type=int, default=4)
    a = ap.parse_args()
    domains = []
    for f in sorted(glob.glob(os.path.join(a.dir, "*.yml"))):
        s = open(f).read()
        if re.search(r'^  status: "terms_gate"', s, re.M): domains.append(re.search(r'^domain: "(.*)"', s, re.M).group(1))
    sem = asyncio.Semaphore(a.workers)
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        rows = await asyncio.gather(*(one(browser, d, sem) for d in domains)); await browser.close()
    prompts, docs = {}, {}
    for r in rows:
        if r["prompt"]: prompts.setdefault(r["prompt"][0], {"len": r["prompt"][1], "sites": []})["sites"].append(r["domain"])
        for d in r["docs"]: docs.setdefault(d["fp"][0], {"len": d["fp"][1], "title": d["title"], "sites": set(), "urls": set()})["sites"].add(r["domain"]); docs[d["fp"][0]]["urls"].add(d["url"])
    no_prompt = [r["domain"] for r in rows if not r["prompt"]]
    lines = ["# Terms census (read-only; fingerprints only)", "",
             f"{len(rows)} terms-gated sites. Nothing was accepted. A fingerprint is a SHA-256 of the whitespace-normalized, lowercased text.", "",
             f"## Gate prompts: {len(prompts)} distinct texts", "", "| Fingerprint | Chars | Sites | Examples |", "|---|---|---|---|"]
    for h, v in sorted(prompts.items(), key=lambda kv: -len(kv[1]["sites"])):
        lines.append(f"| {h} | {v['len']} | {len(v['sites'])} | {', '.join(sorted(v['sites'])[:3])} |")
    lines += ["", f"Sites where no prompt text could be read: {len(no_prompt)} ({', '.join(no_prompt[:6])}{'...' if len(no_prompt) > 6 else ''})",
              "", f"## Linked terms and policy pages: {len(docs)} distinct texts", "", "| Fingerprint | Chars | Sites | Page title | Example address |", "|---|---|---|---|---|"]
    for h, v in sorted(docs.items(), key=lambda kv: -len(kv[1]["sites"]))[:40]:
        lines.append(f"| {h} | {v['len']} | {len(v['sites'])} | {v['title']} | {sorted(v['urls'])[0]} |")
    open(a.out, "w").write("\n".join(lines) + "\n"); print("\n".join(lines[:30]))


if __name__ == "__main__":
    asyncio.run(main())
