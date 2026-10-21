#!/usr/bin/env python3
"""Discover, for each site in directory/, how to ask "is this person listed?" with a plain request, and learn what a
"no results" page looks like by comparing a made-up name against a known common name. The result is written back into
the directory entry as `search_check:`, in the same shape as a broker's `recheck:` block, so the app can scan the site.

  python3 tools/profile_search.py [--dir directory] [--cache .search-cache] [--workers 6] [--refresh] [--only domain,...]

Polite and read-only: honest user agent, robots.txt honored for every URL fetched, one request per second per site,
no form is submitted and no personal data is used (the two names are "Zzyzx Qwertyuiop" and "John Smith").

search_check.status:
  calibrated        the made-up and the known name give clearly different pages, so a check can tell them apart
  blocked           the search page refuses plain requests (bot check, 403)
  robots_disallowed the site's robots.txt asks bots not to fetch its search pages
  undifferentiated  the pages look the same for both names, so a check could not tell
  needs_post        the only search is a POST form (not supported yet)
  needs_browser     the search page is built by JavaScript
  no_search         no name search found
"""
import argparse, concurrent.futures as cf, datetime, glob, json, os, re, sys, time, urllib.parse
sys.path.insert(0, os.path.dirname(__file__))
import profile_brokers as P

MADE_UP = ("Zzyzx", "Qwertyuiop")
KNOWN_NAMES = [("John", "Smith"), ("Michael", "Johnson"), ("James", "Williams")]   # tried in order: a small database may lack one
KNOWN = KNOWN_NAMES[0]
KNOWN_PLACE = {"city": "Springfield", "state": "IL", "state_name": "Illinois"}
PATTERNS = ["name/{first}-{last}", "{first}-{last}", "people/{first}-{last}", "find/{first}-{last}", "person/{first}-{last}",
            "name/{first}_{last}", "search/{first}-{last}", "{first}-{last}/{state_name}/{city}", "results?first={first}&last={last}",
            "people/{first}/{last}", "name/{first}/{last}"]
NEG = re.compile(r"\b(no|not|sorry|zero|didn'?t|did not|couldn'?t|unable|nothing|0)\b", re.I)


def visible(html):
    pg = P.parse(html)
    return re.sub(r"\s+", " ", " ".join(pg.text)).strip(), pg


def words(text): return re.findall(r"[A-Za-z][A-Za-z'’-]*", text)


def ngrams(text, lo, hi):
    """Runs of n consecutive words, sliced from the original text so each one is a real substring of the page
    (punctuation between the words is kept, which matters when the phrase is searched for later)."""
    spans = [m.span() for m in re.finditer(r"[A-Za-z][A-Za-z'’-]*", text)]
    out = []
    for n in range(lo, hi + 1):
        for i in range(len(spans) - n + 1):
            seg = text[spans[i][0]:spans[i + n - 1][1]]
            if not re.search(r"[.!?]\s", seg): out.append(seg)      # stay inside one sentence
    return out


def fill(template, first, last, place, form=False):
    vals = {"first": first, "last": last, "full": f"{first} {last}", "city": place.get("city", ""),
            "state": place.get("state", ""), "state_name": place.get("state_name", "")}
    out = template
    safe = "-._~" if form else "/"
    for k, v in vals.items(): out = out.replace("{" + k + "}", urllib.parse.quote(v, safe=safe if not form else "-._~"))
    return out


def probe(fetcher, req):
    """req = {"method", "url", "body"}; the body is already filled. Returns (state, status, html)."""
    if not fetcher.allowed(req["url"]): return "robots", None, ""
    st, fin, body = fetcher.get(req["url"], req.get("method", "GET"), req.get("body")); time.sleep(1)
    if st is None: return "down", None, ""
    if P.is_blocked(st, body): return "blocked", st, body
    return "ok", st, body


def realise(req, first, last):
    return {"method": req["method"], "url": fill(req["url"], first, last, KNOWN_PLACE),
            "body": fill(req["body"], first, last, KNOWN_PLACE, form=True) if req.get("body") else None}


def mine(made_text, known_text, brand=""):
    """Phrases that explain the difference: negative wording present for the made-up name only, and brand text on both."""
    bad = {"zzyzx", "qwertyuiop"}
    only_made = []
    known_set = set(ngrams(known_text, 3, 5))
    NOUN = re.compile(r"result|found|find|match|record|listing|person|people|profile|report", re.I)
    scored, seen = [], set()
    for g in ngrams(made_text, 3, 5):
        gl = g.lower()
        if gl in seen or g in known_set or any(b in gl for b in bad): continue
        seen.add(gl)
        m = NEG.search(g)
        if not m or not NOUN.search(g): continue
        score = 2 + (2 if m.start() == 0 else 0) + (1 if len(g.split()) == 3 else 0) + (1 if not re.search(r"\b[A-Z][a-z]+ [A-Z][a-z]+ [A-Z][a-z]+", g) else -2)
        scored.append((-score, made_text.find(g), g))
    scored.sort()
    only_made = [g for sc, _, g in scored if -sc >= 4][:2]
    valid = []
    kset = set(g.lower() for g in ngrams(known_text, 2, 3))
    cands = [g for g in ngrams(made_text[:1500], 2, 3) if g.lower() in kset and not any(b in g.lower() for b in bad)]
    cands.sort(key=lambda g: (brand not in g.lower().replace(" ", ""), -len(g)))      # brand-bearing phrases first
    for g in cands:
        if g.lower() not in [v.lower() for v in valid]: valid.append(g)
        if len(valid) >= 2: break
    return only_made[:2], valid


def judge(status, text, spec, name, city):
    """Python mirror of OptOutKitCore.Rechecker, so calibration here predicts what the app will conclude."""
    low = text.lower()
    if status in (403, 429, 503) or (any(m in low for m in P.HARD_CHALLENGE) and not any(v.lower() in low for v in spec["valid_page"])):
        return "blocked"
    if not any(v.lower() in low for v in spec["valid_page"]): return "unrecognized"
    if any(n.lower() in low for n in spec.get("no_results", [])): return "removed"
    hit = all(w in low for w in name.lower().split())
    place_hit = True if spec.get("ignore_location") else (city.lower() in low)
    return "listed" if hit and place_hit else "removed"


def find_search_forms(home_html, base):
    """GET/POST forms on the home page that look like a person-name search."""
    pg = P.parse(home_html); out = []
    for i, f in enumerate(pg.forms):
        ins = [x for x in pg.inputs if x["form"] == i and x["type"] not in ("submit", "button", "image", "reset")]
        names = " ".join(x["name"] + " " + x["ph"].lower() for x in ins)
        if re.search(r"first|fname", names) and re.search(r"last|lname", names) or re.search(r"\bfull.?name|person|\bname\b", names):
            out.append((f, ins))
    return out, pg


def state_param(ins, name):
    """How to fill a state field: {state} for 2-letter codes, {state_name} for full names, None if the options fit neither."""
    for x in ins:
        if x["name"] == name:
            if "IL" in x["opts"]: return "{state}"
            if "Illinois" in x["opts"]: return "{state_name}"
            if not x["opts"] and x["type"] != "select": return "{state}"
    return None


def requests_from_form(form, ins, base):
    """Candidate searches for a form: first with every field we can fill, then names only (some sites ignore the rest)."""
    action = urllib.parse.urljoin(base, form["action"]) if form["action"] else base
    method = form["method"].upper()
    names, extra = [], []
    for x in ins:
        n = x["raw_name"] or x["name"]
        if not n or x["type"] in ("checkbox", "radio", "file", "password", "submit", "button"): continue
        low = x["name"]
        if re.search(r"first|fname", low): names.append((n, "{first}"))
        elif re.search(r"last|lname", low): names.append((n, "{last}"))
        elif re.search(r"full.?name|person|^name$|\bq\b|query", low): names.append((n, "{full}"))
        elif re.search(r"city", low): extra.append((n, "{city}"))
        elif re.search(r"state", low):
            sp = state_param(ins, x["name"])
            if sp: extra.append((n, sp))
        elif x["type"] == "hidden" and 0 < len(x["value"]) < 20: names.append((n, x["value"]))
    if not [1 for _, v in names if v.startswith("{")]: return []
    out = []
    for fields in ([*names, *extra], names) if extra else (names,):
        q = "&".join(f"{k}={v}" for k, v in fields)
        if method == "GET": out.append({"method": "GET", "url": action + ("&" if "?" in action else "?") + q, "body": None})
        else: out.append({"method": "POST", "url": action, "body": q})
    return out


def evaluate(fetcher, template, home_host):
    """Fetch the made-up and the known name through a request template (a URL string or a request dict);
    return a calibrated spec or the reason it cannot be."""
    req = {"method": "GET", "url": template, "body": None} if isinstance(template, str) else template
    uses_place = any(k in (req["url"] + (req.get("body") or "")) for k in ("{city}", "{state}", "{state_name}", "{city_slug}"))
    r_n = realise(req, *MADE_UP)
    if not r_n["url"].startswith("https://"): return {"status": "no_search"}
    sn, stn, bn = probe(fetcher, r_n)
    if sn == "robots": return {"status": "robots_disallowed"}
    if sn in ("blocked", "down"): return {"status": "blocked" if sn == "blocked" else "no_search"}
    tn, pn = visible(bn)
    known = None
    for kn in KNOWN_NAMES:                       # the first common name that actually appears on its own results page
        sk, stk, bk = probe(fetcher, realise(req, *kn))
        if sk == "robots": return {"status": "robots_disallowed"}
        if sk in ("blocked", "down"): return {"status": "blocked" if sk == "blocked" else "no_search"}
        tk, pk = visible(bk)
        if all(w.lower() in tk.lower() for w in kn): known = kn; break
        if tk == tn: break                          # identical to the made-up page: this URL does not search at all
    if known is None: return {"status": "undifferentiated"}
    # Script-rendered: a big page shell with scripts but almost no readable text. A tiny identical 404 is not that.
    if len(tn) < 300 and len(tk) < 300 and len(bn) > 3000 and len(pn.scripts) >= 2 and not pn.forms:
        return {"status": "needs_browser"}
    if tn == tk or (abs(len(tn) - len(tk)) < 40 and stn == stk and not (set(words(tn)) ^ set(words(tk)) - {"zzyzx", "qwertyuiop", "john", "smith"})):
        return {"status": "undifferentiated"}
    # the known name must actually show up on its own results page, or there is nothing for a listing to look like
    if not all(w.lower() in tk.lower() for w in known): return {"status": "undifferentiated"}
    brand = re.sub(r"[^a-z]", "", P.registrable(home_host).split(".")[0])
    no_results, valid = mine(tn, tk, brand)
    if not valid: return {"status": "undifferentiated"}
    spec = {"search_url": req["url"], "valid_page": valid, "no_results": no_results, "ignore_location": not uses_place}
    if req["method"] == "POST": spec["method"] = "POST"; spec["body"] = req["body"]
    r_n = judge(stn, tn, spec, " ".join(MADE_UP), KNOWN_PLACE["city"])
    r_k = judge(stk, tk, spec, " ".join(known), KNOWN_PLACE["city"])
    if r_n == "removed" and r_k == "listed":
        spec["calibration"] = {"listed_name": " ".join(known), **({"city": KNOWN_PLACE["city"], "state": KNOWN_PLACE["state"]} if uses_place else {})}
        return {"status": "calibrated", **spec, "evidence": {"made_up": stn, "known": stk}}
    return {"status": "undifferentiated", "evidence": {"made_up": f"{stn}:{r_n}", "known": f"{stk}:{r_k}"}}


def discover(domain, fetcher):
    start = next((u for u in (f"https://{domain}/", f"https://www.{domain}/") if fetcher.allowed(u)), None)
    if start is None: return {"status": "robots_disallowed"}
    st, final, html = fetcher.get(start); time.sleep(1)
    if st is None: return {"status": "no_search"}
    if P.is_blocked(st, html): return {"status": "blocked"}
    host = urllib.parse.urlsplit(final).netloc
    forms, pg = find_search_forms(html, final)
    results = []
    # 1. the site's own search form (GET or POST), with every fillable field first, then names only
    tried = 0
    for f, ins in forms:
        for req in requests_from_form(f, ins, final):
            r = evaluate(fetcher, req, host); results.append(r); tried += 1
            if r["status"] == "calibrated": return r
        if tried >= 4: break
    # 2. common name-search URL patterns on the same host
    for pat in PATTERNS:
        r = evaluate(fetcher, f"https://{host}/{pat}", host)
        if r["status"] == "calibrated": return r
        results.append(r)
    for want in ("robots_disallowed", "blocked", "needs_browser", "undifferentiated"):
        if any(r["status"] == want for r in results): return {"status": want}
    return {"status": "no_search"}


def find_candidate(domain, fetcher):
    """The first fillable search request on the home page, for sites where a plain request gets only a loading shell.
    A browser (the app's web view) can then try it. Returns None when the home page has no usable name search."""
    start = next((u for u in (f"https://{domain}/", f"https://www.{domain}/") if fetcher.allowed(u)), None)
    if start is None: return None
    st, final, html = fetcher.get(start); time.sleep(1)
    if st is None or P.is_blocked(st, html): return None
    forms, pg = find_search_forms(html, final)
    for f, ins in forms:
        reqs = requests_from_form(f, ins, final)
        if reqs: return reqs[0]
    return None


def to_flow(v):
    return "\n".join(["search_check:"] + [f"  {k}: {json.dumps(x)}" for k, x in v.items() if k != "evidence"]) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="directory"); ap.add_argument("--cache", default=".search-cache")
    ap.add_argument("--workers", type=int, default=6); ap.add_argument("--refresh", action="store_true")
    ap.add_argument("--only", default="")
    ap.add_argument("--candidates", action="store_true", help="record the search request for sites a plain request cannot read")
    a = ap.parse_args()
    os.makedirs(a.cache, exist_ok=True)
    skip = {"unreachable", "blocked", "robots_disallowed"}
    entries = []
    for f in sorted(glob.glob(os.path.join(a.dir, "*.yml"))):
        s = open(f).read(); d = re.search(r'^domain: "(.*)"', s, re.M).group(1)
        auto = re.search(r'^automation: "(.*)"', s, re.M).group(1)
        if a.only and d not in a.only.split(","): continue
        entries.append((f, d, auto))
    fetcher = P.Fetcher()

    if a.candidates:
        todo = []
        for f, d, auto in entries:
            t = open(f).read()
            if re.search(r'^  status: "(undifferentiated|needs_browser)"', t, re.M): todo.append((f, d))
        def cand(item):
            f, d = item; return f, find_candidate(d, fetcher)
        with cf.ThreadPoolExecutor(a.workers) as ex: found = list(ex.map(cand, todo))
        n = 0
        for f, c in found:
            if not c: continue
            t = open(f).read()
            t = re.sub(r"\n  candidate: .*", "", t)
            t = re.sub(r'(\nsearch_check:\n(?:  .*\n)*?)', lambda m: m.group(1), t)
            t = t.rstrip("\n") + "\n  candidate: " + json.dumps(c) + "\n"
            open(f, "w").write(t); n += 1
        print(f"{n} of {len(todo)} sites have a candidate search request"); return

    def work(item):
        f, d, auto = item
        cache = os.path.join(a.cache, d + ".json")
        if os.path.exists(cache) and not a.refresh and time.time() - os.path.getmtime(cache) < 30 * 86400:
            return f, json.load(open(cache))
        r = {"status": "blocked"} if auto == "blocked" else {"status": "no_search"} if auto == "unreachable" else discover(d, fetcher)
        r["checked"] = datetime.date.today().isoformat()
        json.dump(r, open(cache, "w")); return f, r

    with cf.ThreadPoolExecutor(a.workers) as ex: results = list(ex.map(work, entries))
    # Propagation: sibling sites often run the same platform (the *arrests.org network). Try each calibrated site's URL
    # pattern on its look-alike siblings; a sibling is calibrated only if it passes its own made-up vs known test.
    def label(d): return d.split(".")[0]
    def tld(d): return ".".join(d.split(".")[1:])
    def common_suffix(a, b):
        n = 0
        while n < min(len(a), len(b)) and a[-1 - n] == b[-1 - n]: n += 1
        return n
    calibrated = [(f, r) for f, r in results if r["status"] == "calibrated"]
    domains = {f: re.search(r'^domain: "(.*)"', open(f).read(), re.M).group(1) for f, _ in results}
    skip_status = {"blocked", "robots_disallowed"}
    todo = [(f, r) for f, r in results if r["status"] not in {"calibrated"} | skip_status]
    def propagate(item):
        f, r = item; d = domains[f]
        for cf_, cr in calibrated:
            cd = domains[cf_]
            if cd == d or tld(cd) != tld(d) or common_suffix(label(cd), label(d)) < 6: continue
            path = urllib.parse.urlsplit(cr["search_url"]).path
            host = urllib.parse.urlsplit(f"https://www.{d}/").netloc
            if not fetcher.allowed(f"https://{host}{path}"): continue
            nr = evaluate(fetcher, f"https://{host}{path}".replace("%7B", "{").replace("%7D", "}") if False else f"https://{host}" + re.sub(r"%7B(\w+)%7D", r"{\1}", path), host)
            if nr["status"] == "calibrated":
                nr["checked"] = datetime.date.today().isoformat(); nr["via"] = "sibling pattern"; return f, nr
        return f, r
    with cf.ThreadPoolExecutor(a.workers) as ex: promoted = dict(ex.map(propagate, todo))
    results = [(f, promoted.get(f, r)) for f, r in results]
    from collections import Counter
    counts = Counter()
    for f, r in results:
        s = open(f).read()
        s = re.sub(r"\nsearch_check:\n(?:  .*\n)+", "\n", s)         # replace a previous result
        s = s.rstrip("\n") + "\n" + to_flow({k: v for k, v in r.items()}) 
        open(f, "w").write(s); counts[r["status"]] += 1
    lines = [f"# Search-check profile ({datetime.date.today()})", "", f"{len(results)} sites.", "", "| Result | Sites |", "|---|---|"]
    lines += [f"| {k} | {v} |" for k, v in counts.most_common()]
    open(os.path.join(a.dir, "SEARCH-REPORT.md"), "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
