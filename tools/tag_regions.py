#!/usr/bin/env python3
"""Tag each directory site with the places whose residents it collects data about.

Every site came from a US state registry, so `US` is always in the list. Other places are added only on evidence, and the evidence is stored:
  - the IAB Europe TCF Global Vendor List (adtech vendors that run under EU consent rules), matched by the vendor's privacy-policy domain;
  - the site's own opt-out and policy pages naming a non-US law or place (GDPR, EEA, UK GDPR, PIPEDA, LGPD, ...);
  - a country code in the domain (example.co.uk).
No evidence leaves the list as ["US"]; that is "not shown to reach anywhere else", not "proved US-only".

  tag_regions.py fetch      download the pages into pipeline/region-pages/ (resumes)
  tag_regions.py apply      read the pages and the vendor list, write `regions:` into directory/*.yml
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


def registrable(host):
    p = host.lower().split(".")
    return ".".join(p[-3:]) if len(p) > 2 and len(p[-1]) == 2 and p[-2] in ("co", "com", "org", "net") else ".".join(p[-2:])


def main(cmd):
    os.makedirs(PAGES, exist_ok=True)
    if cmd == "fetch":
        with concurrent.futures.ThreadPoolExecutor(16) as ex: list(ex.map(fetch_one, entries()))
        return
    gvl = json.load(open(GVL))["vendors"]
    vendor_domains = {}
    for v in gvl.values():
        for u in v.get("urls", []):
            if u.get("privacy"):
                h = urllib.parse.urlparse(u["privacy"]).hostname
                if h: vendor_domains[registrable(h)] = v["name"]
    counts = {}
    for f, dom, _ in entries():
        ev, regions = [], ["US"]
        if registrable(dom) in vendor_domains:
            regions.append("EU"); ev.append("listed on the IAB Europe TCF vendor list as " + vendor_domains[registrable(dom)])
        tld = dom.rsplit(".", 1)[-1]
        if tld in CCTLD and CCTLD[tld] not in regions: regions.append(CCTLD[tld]); ev.append("country domain ." + tld)
        page = os.path.join(PAGES, dom + ".txt")
        text = open(page).read() if os.path.exists(page) else ""
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
