#!/usr/bin/env python3
"""Tag each directory site with the places whose residents it collects data about.

Every site came from a US state registry, so `US` is always in the list. Other places are added only on evidence, and the evidence is stored:
  - the IAB Europe TCF Global Vendor List (adtech vendors that run under EU consent rules), matched by the vendor's privacy-policy domain;
  - the site's own opt-out and policy pages naming a non-US law or place (GDPR, EEA, UK GDPR, PIPEDA, LGPD, ...);
  - a country code in the domain (example.co.uk).
No evidence leaves the list as ["US"]; that is "not shown to reach anywhere else", not "proved US-only".

  tag_regions.py fetch      download the pages into pipeline/region-pages/ (resumes)
  tag_regions.py ico CSV    match our sites' company names to the ICO register of data protection fee payers (a UK presence signal); writes pipeline/ico-matches.json
  tag_regions.py apply      read the pages, the vendor list and the ICO matches, write `regions:` into directory/*.yml
"""
import concurrent.futures, glob, json, os, re, sys, urllib.request, urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAGES = os.path.join(ROOT, "pipeline", "region-pages")
GVL = os.path.join(ROOT, "pipeline", "tcf-vendor-list.json")
UA = {"User-Agent": "Mozilla/5.0 (Macintosh) OptOutKit-research"}

SIGNALS = [  # (code, regex)
    ("EU", r"\bGDPR\b|General Data Protection Regulation|European Economic Area|\bEEA\b|\bEU residents|residents of the (EU|European Union)|Article 27"),
    ("UK", r"UK GDPR|United Kingdom|\bUK residents|Data Protection Act 2018"),
    ("CA", r"\bPIPEDA\b|Quebec|Law 25|residents of Canada|Canadian residents|\bCASL\b"),
    ("AU", r"Australian Privacy Principles|Privacy Act 1988|residents of Australia"),
    ("BR", r"\bLGPD\b|Lei Geral"),
    ("IN", r"\bDPDP\b|residents of India"),
    ("JP", r"\bAPPI\b|residents of Japan"),
    ("KR", r"\bPIPA\b|Personal Information Protection Act of Korea"),
    ("SG", r"\bPDPA\b"),
    ("AR", r"Ley 25\.?326|Argentine Personal Data|Agencia de Acceso a la Informaci"),
    ("MX", r"LFPDPPP|Ley Federal de Protecci[o\u00f3]n de Datos"),
    ("CO", r"Ley 1581|Habeas Data"),
    ("CL", r"Ley 19\.?628|Ley 21\.?719"),
    ("CH", r"\bnDSG\b|Swiss Federal Act on Data Protection"),
    ("ZA", r"\bPOPIA\b|Protection of Personal Information Act"),
    ("NZ", r"New Zealand Privacy Act|Privacy Act 2020"),
]
CCTLD = {"uk": "UK", "de": "EU", "fr": "EU", "es": "EU", "it": "EU", "nl": "EU", "ie": "EU", "eu": "EU", "se": "EU", "dk": "EU", "pl": "EU", "be": "EU", "at": "EU",
         "ca": "CA", "au": "AU", "br": "BR", "in": "IN", "jp": "JP", "kr": "KR", "sg": "SG"}


def entries():
    for f in sorted(glob.glob(os.path.join(ROOT, "directory", "*.yml"))):
        s = open(f).read()
        if re.search(r"^excluded:", s, re.M): continue
        dom = re.search(r'^domain: "(.*)"', s, re.M).group(1)
        urls = []
        for pat in (r'"source": "(https?://[^"]+)"', r'^opt_out_url: "(https?://[^"]+)"', r'^  page: "(https?://[^"]+)"', r'"page": "(https?://[^"]+)"'):
            urls += re.findall(pat, s, re.M)
        yield f, dom, list(dict.fromkeys(urls))[:3] or ["https://" + dom + "/privacy"]


def fetch_one(item):
    f, dom, urls = item
    out = os.path.join(PAGES, dom + ".txt")
    if os.path.exists(out): return
    text = ""
    for u in urls:
        try:
            raw = urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=12).read(600_000).decode("utf-8", "ignore")
            text += " " + re.sub(r"<[^>]+>", " ", re.sub(r"(?s)<(script|style).*?</\1>", " ", raw))
        except Exception:
            pass
    open(out, "w").write(re.sub(r"\s+", " ", text)[:400_000])


LEGAL_LINK = re.compile(r"privacy|terms|legal|policy|conditions|datenschutz|gdpr|dsar|your.?rights", re.I)


def fetch_legal(item):
    """The site's own privacy policy and terms of use, found by their links on the home page."""
    f, dom, urls = item
    out = os.path.join(PAGES, dom + ".legal.txt")
    if os.path.exists(out): return
    text = ""
    try:
        base = "https://" + dom + "/"
        home = urllib.request.urlopen(urllib.request.Request(base, headers=UA), timeout=12).read(600_000).decode("utf-8", "ignore")
        links = []
        for href, label in re.findall(r'(?is)<a[^>]+href="([^"#]+)"[^>]*>(.*?)</a>', home):
            if LEGAL_LINK.search(href) or LEGAL_LINK.search(re.sub(r"<[^>]+>", " ", label)):
                u = urllib.parse.urljoin(base, href)
                if u.startswith("http") and u not in links and urllib.parse.urlparse(u).hostname and registrable(urllib.parse.urlparse(u).hostname) == registrable(dom):
                    links.append(u)
        for u in links[:4]:
            try:
                raw = urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=12).read(800_000).decode("utf-8", "ignore")
                text += " " + re.sub(r"<[^>]+>", " ", re.sub(r"(?s)<(script|style).*?</\1>", " ", raw))
            except Exception:
                pass
    except Exception:
        pass
    open(out, "w").write(re.sub(r"\s+", " ", text)[:600_000])


def registrable(host):
    p = host.lower().split(".")
    return ".".join(p[-3:]) if len(p) > 2 and len(p[-1]) == 2 and p[-2] in ("co", "com", "org", "net") else ".".join(p[-2:])


def norm(name):
    n = re.sub(r"[^a-z0-9 ]", " ", name.lower().replace("&", " and "))
    n = re.sub(r"\b(inc|llc|ltd|limited|corp|corporation|co|company|plc|lp|llp|incorporated|the|uk|usa|us)\b", " ", n)
    return re.sub(r"\s+", " ", n).strip()


def ico_match(csv_path):
    import csv
    csv.field_size_limit(10**8)
    ours = {}
    for f in sorted(glob.glob(os.path.join(ROOT, "directory", "*.yml"))):
        s = open(f).read()
        dom = re.search(r'^domain: "(.*)"', s, re.M).group(1)
        name = re.search(r'^name: "(.*)"', s, re.M)
        # Only the company's legal name, and only a name distinctive enough to be one company (two words, or a long single word).
        n = norm(name.group(1)) if name else ""
        if len(n.split()) >= 2 or len(n) >= 8: ours.setdefault(n, set()).add(dom)
    out = {}
    with open(csv_path, newline="", encoding="utf-8", errors="ignore") as fh:
        for row in csv.DictReader(fh):
            names = [row["Organisation_name"]] + [t for t in re.split(r"[;,]", row.get("Trading_names") or "") if t.strip()]
            for nm in names:
                for d in ours.get(norm(nm), ()):
                    out.setdefault(d, {"name": row["Organisation_name"], "ref": row["Registration_number"]})
    json.dump(out, open(os.path.join(ROOT, "pipeline", "ico-matches.json"), "w"), indent=1, sort_keys=True)
    print(len(out), "sites matched on the ICO register")


def main(cmd):
    os.makedirs(PAGES, exist_ok=True)
    if cmd == "ico":
        return ico_match(sys.argv[2])
    if cmd == "fetch":
        with concurrent.futures.ThreadPoolExecutor(16) as ex: list(ex.map(fetch_one, entries()))
        return
    if cmd == "fetch-legal":
        with concurrent.futures.ThreadPoolExecutor(24) as ex: list(ex.map(fetch_legal, entries()))
        return
    gvl = json.load(open(GVL))["vendors"]
    vendor_domains = {}
    for v in gvl.values():
        for u in v.get("urls", []):
            if u.get("privacy"):
                h = urllib.parse.urlparse(u["privacy"]).hostname
                if h: vendor_domains[registrable(h)] = v["name"]
    ICO = json.load(open(os.path.join(ROOT, "pipeline", "ico-matches.json"))) if os.path.exists(os.path.join(ROOT, "pipeline", "ico-matches.json")) else {}
    counts = {}
    for f, dom, _ in entries():
        ev, regions = [], ["US"]
        if registrable(dom) in vendor_domains:
            regions.append("EU"); ev.append("listed on the IAB Europe TCF vendor list as " + vendor_domains[registrable(dom)])
        ico = ICO.get(dom)
        if ico and "UK" not in regions:
            regions.append("UK"); ev.append("on the UK ICO register of fee payers as %s (ref %s)" % (ico["name"], ico["ref"]))
        tld = dom.rsplit(".", 1)[-1]
        if tld in CCTLD and CCTLD[tld] not in regions: regions.append(CCTLD[tld]); ev.append("country domain ." + tld)
        page = os.path.join(PAGES, dom + ".txt")
        text = open(page).read() if os.path.exists(page) else ""
        legal = os.path.join(PAGES, dom + ".legal.txt")
        if os.path.exists(legal): text += " " + open(legal).read()
        for code, rx in SIGNALS:
            m = re.search(rx, text)
            if m and code not in regions:
                regions.append(code); ev.append("its pages mention " + m.group(0))
        s = open(f).read()
        s = re.sub(r"^regions: .*\n", "", s, flags=re.M)
        line = "regions: " + json.dumps({"list": regions, "evidence": "; ".join(ev) or "registered with a US state; nothing found for other places", "checked": "2026-10-26"}, ensure_ascii=False) + "\n"
        s = s.rstrip("\n") + "\n" + line
        open(f, "w").write(s)
        key = "+".join(regions); counts[key] = counts.get(key, 0) + 1
    for k, v in sorted(counts.items(), key=lambda x: -x[1]): print(v, k)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "apply")
