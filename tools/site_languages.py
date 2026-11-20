#!/usr/bin/env python3
"""Record which languages each broker's site is offered in, and the translated address of its opt-out page.

Offering a site in French or Japanese is a signal the broker serves people there, so languages tied to one country add that region (with the evidence).
English, Spanish, Portuguese, Chinese, Arabic and Russian are spoken in too many countries to say, so they are recorded but add no region.

  site_languages.py find    write pipeline/site-languages.json (resumes)
  site_languages.py apply   write `languages:` and the matching `regions:` tags into directory/*.yml (adds only)
"""
import concurrent.futures, json, os, re, sys, urllib.parse, urllib.request

import yamlio

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "pipeline", "site-languages.json")
UA = {"User-Agent": "Mozilla/5.0 (Macintosh) OptOutKit-research"}
# language -> the one country it points to
ONE_COUNTRY = {"fr": "FR", "de": "DE", "it": "IT", "nl": "NL", "pl": "PL", "sv": "SE", "da": "DK", "fi": "FI", "nb": "NO", "no": "NO", "el": "GR", "cs": "CZ", "hu": "HU",
               "ro": "RO", "tr": "TR", "ja": "JP", "ko": "KR", "he": "IL", "th": "TH", "vi": "VN", "id": "ID", "bg": "BG", "hr": "HR", "sk": "SK", "sl": "SI", "lt": "LT", "lv": "LV", "et": "EE"}
NAMES = {"fr": "French", "de": "German", "it": "Italian", "nl": "Dutch", "pl": "Polish", "sv": "Swedish", "da": "Danish", "fi": "Finnish", "nb": "Norwegian", "no": "Norwegian",
         "el": "Greek", "cs": "Czech", "hu": "Hungarian", "ro": "Romanian", "tr": "Turkish", "ja": "Japanese", "ko": "Korean", "he": "Hebrew", "th": "Thai", "vi": "Vietnamese",
         "id": "Indonesian", "bg": "Bulgarian", "hr": "Croatian", "sk": "Slovak", "sl": "Slovenian", "lt": "Lithuanian", "lv": "Latvian", "et": "Estonian"}


def get(url, limit=500_000):
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=10)
        return r.geturl(), r.read(limit).decode("utf-8", "ignore")
    except Exception:
        return None, None


def entries():
    for f, doc in yamlio.entries(os.path.join(ROOT, "directory")):
        if "excluded" in doc: continue
        yield f, doc["domain"], yamlio.form_page(doc) or yamlio.live_page(doc) or yamlio.http(doc.get("opt_out_url"))


def langs_of(html, base):
    """(set of primary language codes, {language tag: address}) from one page."""
    found, pages = set(), {}
    m = re.search(r'(?is)<html[^>]+lang="([^"]+)"', html)
    if m: found.add(m.group(1).lower().replace("_", "-").split("-")[0])
    for tag in re.findall(r"(?is)<(?:link|a)\b[^>]*hreflang=[^>]+>", html):
        h = re.search(r'hreflang="([^"]+)"', tag); u = re.search(r'href="([^"#]+)"', tag)
        if not h or h.group(1).lower() == "x-default": continue
        tag_ = h.group(1).replace("_", "-")
        found.add(tag_.lower().split("-")[0])
        if u: pages.setdefault(tag_, urllib.parse.urljoin(base, u.group(1)))
    return found, pages


def find_one(item):
    f, dom, opt = item
    langs, pages = set(), {}
    for url in dict.fromkeys(["https://" + dom + "/", opt] if opt else ["https://" + dom + "/"]):
        fin, html = get(url)
        if not html: continue
        l, p = langs_of(html, fin or url)
        langs |= l
        if url == opt: pages = p
    return dom, {"list": sorted(langs), "pages": pages}


def main(cmd):
    if cmd == "find":
        done = json.load(open(OUT)) if os.path.exists(OUT) else {}
        todo = [e for e in entries() if e[1] not in done]
        with concurrent.futures.ThreadPoolExecutor(32) as ex:
            for i, (dom, res) in enumerate(ex.map(find_one, todo)):
                done[dom] = res
                if i % 100 == 0: print(i, len(todo), flush=True)
        json.dump(done, open(OUT, "w"), indent=1, sort_keys=True)
        print("sites offered in a language other than English:", sum(1 for v in done.values() if set(v["list"]) - {"en"}))
        return
    data = json.load(open(OUT)); n = 0; tagged = 0
    for f, dom, _ in entries():
        res = data.get(dom)
        if not res or not res["list"]: continue
        doc = yamlio.load(f)
        doc.pop("languages", None)
        # Translations of the opt-out page must live on the site itself or on a privacy portal, not on a tracker or analytics host.
        def same(u):
            h = urllib.parse.urlparse(u).hostname or ""
            return h.endswith(dom.split(".", 1)[-1] if dom.count(".") > 1 else dom) or dom.rsplit(".", 1)[0].split(".")[-1] in h or re.search(r"onetrust|trustarc|datasubject|ketch|transcend|osano|securiti|zendesk|force\.com", h)
        pages = {k: v for k, v in res["pages"].items() if same(v)}
        doc["languages"] = {"list": res["list"], "pages": pages, "checked": "2026-10-26"}
        if doc.get("regions"):
            r = yamlio.plain(doc["regions"])
            for code in (res["list"] if len(res["list"]) <= 15 else []):   # a picker with dozens of languages is a worldwide signal (GLOBAL below), not a list of countries
                c = ONE_COUNTRY.get(code)
                if c and c not in r["list"] and ("EU" not in r["list"] or True):
                    r["list"].append(c); tagged += 1
                    r["evidence"] = (r.get("evidence", "") + "; offers its site in " + NAMES[code]).lstrip("; ")
            # Many languages, or many regions, together suggest the broker serves people everywhere, not in one place.
            others = [x for x in r["list"] if x not in ("US", "GLOBAL")]
            if "GLOBAL" not in r["list"] and (len(res["list"]) >= 8 or len(others) >= 4):
                why = ("its site is offered in %d languages" % len(res["list"])) if len(res["list"]) >= 8 else ("it was found in %d regions besides the US" % len(others))
                r["list"].append("GLOBAL"); r["evidence"] = (r.get("evidence", "") + "; " + why + ", which suggests it serves people worldwide").lstrip("; ")
            doc["regions"] = r
        yamlio.save(f, doc); n += 1
    print("updated", n, "sites; region tags added from languages:", tagged)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "find")
