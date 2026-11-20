#!/usr/bin/env python3
"""Find each broker's other-country and other-region sites, crawl them for an opt-out page, and record them in directory/*.yml.

A broker that runs example.co.uk or fr.example.com operates there: that is a strong region signal (stronger than a policy naming a law). Three ways to find them:
  - the home page's hreflang alternates that name a region (en-GB, fr-FR), pointing at the same brand;
  - links on the home page to the same brand under another country domain or a country subdomain or path (example.co.uk, uk.example.com, example.com/uk/);
  - probing the same name under the main country domains (example.fr, example.de, ...), kept only when the page answers and names the brand.

  regional_sites.py find     write pipeline/regional-sites.json (resumes)
  regional_sites.py validate keep a probed country domain only if its page links back to the broker's main site (same company), else drop it
  regional_sites.py apply    write `regional_sites:` and the matching `regions:` tags into directory/*.yml (adds only)
"""
import concurrent.futures, glob, json, os, re, socket, sys, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "pipeline", "regional-sites.json")
UA = {"User-Agent": "Mozilla/5.0 (Macintosh) OptOutKit-research"}
TLDS = {"co.uk": "GB", "fr": "FR", "de": "DE", "es": "ES", "it": "IT", "nl": "NL", "ie": "IE", "ca": "CA", "com.au": "AU", "com.br": "BR", "in": "IN", "co.nz": "NZ", "se": "SE", "pl": "PL"}
SUBS = {"uk": "GB", "gb": "GB", "fr": "FR", "de": "DE", "es": "ES", "it": "IT", "nl": "NL", "ie": "IE", "ca": "CA", "au": "AU", "br": "BR", "in": "IN", "nz": "NZ", "eu": "EU", "mx": "MX", "ar": "AR", "jp": "JP", "sg": "SG"}
# Language-only paths (/fr/, /de/, /es/, /ca/, /ar/) name a language, not a country, so they are not used.
PATHS = {"uk": "GB", "gb": "GB", "en-gb": "GB", "fr-fr": "FR", "de-de": "DE", "es-es": "ES", "en-ca": "CA", "fr-ca": "CA", "au": "AU", "en-au": "AU", "br": "BR", "pt-br": "BR", "mx": "MX", "es-mx": "MX", "es-ar": "AR", "en-in": "IN", "ie": "IE", "en-ie": "IE"}
LEGAL = re.compile(r"privacy|opt.?out|do.not.sell|data.subject|dsar|your.?rights|unsubscribe|datenschutz|confidentialit|privacidad|protezione.dati", re.I)


def get(url, limit=500_000):
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=10)
        return r.geturl(), r.read(limit).decode("utf-8", "ignore")
    except Exception:
        return None, None


def reg(host):
    p = host.lower().split(".")
    if len(p) > 2 and len(p[-1]) == 2 and p[-2] in ("co", "com", "org", "net", "ac", "gov"): return ".".join(p[-3:])
    return ".".join(p[-2:])


def stem(domain):
    r = reg(domain).split(".")
    return r[0]


def has_dns(host):
    try:
        socket.getaddrinfo(host, 443, proto=socket.IPPROTO_TCP); return True
    except Exception:
        return False


def entries():
    for f in sorted(glob.glob(os.path.join(ROOT, "directory", "*.yml"))):
        s = open(f).read()
        if re.search(r"^excluded:", s, re.M): continue
        yield f, re.search(r'^domain: "(.*)"', s, re.M).group(1)


def region_label(code): return "UK" if code == "GB" else code


def crawl_regional(url, brand):
    """The privacy / opt-out page of a regional site, and whether it has a form."""
    final, html = get(url)
    if not html: return None
    links = []
    for href, label in re.findall(r'(?is)<a[^>]+href="([^"#]+)"[^>]*>(.*?)</a>', html):
        if LEGAL.search(href) or LEGAL.search(re.sub(r"<[^>]+>", " ", label)):
            u = urllib.parse.urljoin(final, href)
            if u.startswith("http") and u not in links: links.append(u)
    page, form = None, False
    for u in links[:3]:
        f2, h2 = get(u, 400_000)
        if h2 and re.search(r"(?i)opt.?out|do not sell|delete|erasure|objection|data subject|rights", h2):
            page = f2 or u; form = bool(re.search(r"(?i)<form", h2)); break
    return {"privacy_page": page, "has_form": form}


def find_one(item):
    f, dom = item
    found = {}
    brand = stem(dom)
    final, html = get("https://" + dom + "/")
    base = final or "https://" + dom + "/"
    def add(region, url, how):
        if region and region != "US" and region not in found: found[region] = {"region": region, "url": url, "how": how}
    if html:
        for tag in re.findall(r"(?is)<link[^>]+hreflang=[^>]+>", html):
            m = re.search(r'hreflang="([^"]+)"', tag); h = re.search(r'href="([^"]+)"', tag)
            if not (m and h): continue
            parts = m.group(1).replace("_", "-").split("-")
            if len(parts) == 2 and len(parts[1]) == 2:
                u = urllib.parse.urljoin(base, h.group(1)); host = urllib.parse.urlparse(u).hostname or ""
                if stem(host) == brand: add(parts[1].upper(), u, "hreflang " + m.group(1))
        for href in re.findall(r'(?i)<a[^>]+href="([^"#]+)"', html):
            u = urllib.parse.urljoin(base, href); p = urllib.parse.urlparse(u); host = (p.hostname or "").lower()
            if not host or stem(host) != brand: continue
            if reg(host) != reg(dom):
                tld = reg(host)[len(brand) + 1:]
                if tld in TLDS: add(TLDS[tld], u, "country domain")
            else:
                sub = host[: -len(reg(host)) - 1] if host != reg(host) else ""
                if sub.split(".")[0] in SUBS: add(SUBS[sub.split(".")[0]], u, "country subdomain")
            seg = (p.path.strip("/").split("/") or [""])[0].lower()
            if seg in PATHS and host == (urllib.parse.urlparse(base).hostname or "").lower(): add(PATHS[seg], u, "country path")
    # Probing the same name under main country domains; kept only if the page names the brand.
    if len(brand) >= 4:
        for tld, code in TLDS.items():
            if code in found or reg(dom).endswith("." + tld): continue
            host = brand + "." + tld
            if not has_dns(host): continue
            fin, h = get("https://" + host + "/", 200_000)
            if h and len(re.findall(re.escape(brand), h, re.I)) >= 3 and re.search(r"(?i)<title>[^<]*" + re.escape(brand), h):
                add(code, fin, "probed country domain")
    out = []
    for r in list(found.values())[:6]:
        c = crawl_regional(r["url"], brand) or {}
        out.append({**r, **c})
    return dom, out


def main(cmd):
    if cmd == "find":
        done = json.load(open(OUT)) if os.path.exists(OUT) else {}
        todo = [e for e in entries() if e[1] not in done]
        with concurrent.futures.ThreadPoolExecutor(32) as ex:
            for i, (dom, res) in enumerate(ex.map(find_one, todo)):
                done[dom] = res
                if i % 50 == 0: json.dump(done, open(OUT, "w"), indent=1, sort_keys=True); print(i, len(todo), flush=True)
        json.dump(done, open(OUT, "w"), indent=1, sort_keys=True)
        print("sites with a regional site:", sum(1 for v in done.values() if v), "of", len(done))
        return
    if cmd == "validate":
        data = json.load(open(OUT))
        def check(item):
            dom, res = item
            keep = []
            for x in res:
                if not x["how"].startswith("probed"): keep.append(x); continue
                fin, html = get(x["url"], 400_000)
                host = urllib.parse.urlparse(fin or "").hostname or ""
                backlink = html and re.search(r'(?i)href="[^"]*' + re.escape(reg(dom)), html) and reg(host) != reg(dom)
                if backlink: keep.append({**x, "how": "probed country domain that links back to " + reg(dom)})
            return dom, keep
        with concurrent.futures.ThreadPoolExecutor(32) as ex: data = dict(ex.map(check, data.items()))
        json.dump(data, open(OUT, "w"), indent=1, sort_keys=True)
        print("sites with a regional site:", sum(1 for v in data.values() if v), "regional sites:", sum(len(v) for v in data.values()))
        return
    data = json.load(open(OUT)); n = 0
    for f, dom in entries():
        res = data.get(dom)
        if not res: continue
        s = open(f).read()
        res = [x for x in res if not (x["how"] == "country path" and (urllib.parse.urlparse(x["url"]).path.strip("/").split("/") or [""])[0].lower() not in PATHS)]
        if not res: continue
        s = re.sub(r"^regional_sites: .*\n", "", s, flags=re.M)
        s = s.rstrip("\n") + "\nregional_sites: " + json.dumps(res, ensure_ascii=False) + "\n"
        m = re.search(r"^regions: (\{.*\})$", s, re.M)
        if m:
            r = json.loads(m.group(1))
            for x in res:
                if x["how"].startswith("probed"): continue      # same name under a country domain: kept as a lead, not as evidence
                lab = region_label(x["region"])
                if lab not in r["list"]:
                    r["list"].append(lab)
                    r["evidence"] = (r.get("evidence", "") + "; has a " + lab + " site at " + x["url"] + " (" + x["how"] + ")").lstrip("; ")
            s = s[:m.start()] + "regions: " + json.dumps(r, ensure_ascii=False) + s[m.end():]
        open(f, "w").write(s); n += 1
    print("updated", n)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "find")
