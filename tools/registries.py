#!/usr/bin/env python3
"""Pulls every state's public data broker registry, joins them, and feeds the directory.

  registries.py fetch [--only ca,tx,or,vt]   download each registry into registries/<state>.json (one normalized shape)
  registries.py merge [--add-sites]          join them by website (and exact business name), write:
        registries/all-brokers.json     every known broker once, with the states it is registered in
        registries/summary.json         counts per state, overlap, and what could not be joined (shown in the app)
        pipeline/registry-seeds.json    per site: business name, privacy-rights page, states (seeds the profiler)
        platforms/ca-drop-coverage.json which sites California's DROP reaches
        (--add-sites also appends missing sites to pipeline/census-sites.txt)

Sources (see jurisdictions/us.yml): California CSV, Texas Excel export (the portal is a web app, so a headless browser clicks
Export), Oregon tab-delimited file (names and addresses only, no websites), Vermont (the bulk download needs a free account, so
drop the file into registries/inbox/vt.csv or vt.xlsx and it is imported). A state that cannot be fetched keeps its last file.
Polite: robots.txt honored, retries with backoff, one request per file. Registries are public records.
"""
import argparse, csv, datetime, glob, io, json, os, re, sys, urllib.parse, urllib.request, zipfile
import xml.etree.ElementTree as ET
sys.path.insert(0, os.path.dirname(__file__))
import profile_brokers as pb

OUT = "registries"
INBOX = os.path.join(OUT, "inbox")
CA_URL = "https://cppa.ca.gov/data_broker_registry/registry.csv"
TX_URL = "https://texas-sos.appianportalsgov.com/data-broker-registry"
OR_BASE = "https://www4.cbs.state.or.us/exs/all/mylicsearch/"
OR_FILE = OR_BASE + "index.cfm?fuseaction=search.download_dfcs_file&download_file=dfcs_db.txt"
UA = pb.UA

DOMAIN = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,}$")


def domains_in(field):
    """Every site in a registry cell, in order. Brokers type these freely ("example.com; https://www.example.com", "com; other.io"),
    so split on separators, drop schemes and paths, and keep only things that are a real hostname."""
    out = []
    for token in re.split(r"[;,\s|]+", (field or "").strip().lower()):
        t = re.sub(r"^[a-z]+://", "", token).split("/")[0].split("?")[0].split(":")[0].strip(".")
        if t and DOMAIN.match(t):
            reg = pb.registrable(t)
            if reg and reg not in out: out.append(reg)
    return out


def norm(name):
    s = re.sub(r"\b(llc|inc|corp|corporation|co|ltd|incorporated|company|lp|l\.l\.c|l\.p)\b\.?", "", (name or "").lower())
    s = re.sub(r"\.(com|org|net|io|us|info|me)\b", "", s)           # "FastPeopleSearch.com" and "FastPeopleSearch" are one name
    return re.sub(r"[^a-z0-9]", "", s)


def record(name, dba="", site_cell="", privacy_cell="", reg_id="", extra=None):
    sites, priv = domains_in(site_cell), domains_in(privacy_cell)
    r = {"name": (name or "").strip(), "dba": (dba or "").strip(), "primary": (sites or priv or [""])[0],
         "sites": sorted(set(sites + priv)), "privacy_url": (privacy_cell or "").strip().split()[0] if (privacy_cell or "").strip() else "",
         "reg_id": reg_id}
    if extra: r.update(extra)
    return r


# ---------- California: CSV ----------

def parse_ca(text):
    rows = list(csv.reader(io.StringIO(text.lstrip("﻿"))))
    header = next(i for i, r in enumerate(rows) if r and r[0].strip().lower().startswith("data broker name"))
    return [record(r[0], r[1], r[2], r[10]) for r in rows[header + 1:] if len(r) >= 11 and r[0].strip()]


def fetch_ca(f):
    if not f.allowed(CA_URL): raise RuntimeError("robots.txt disallows the California registry file")
    st, _, body = f.get(CA_URL)
    if st != 200 or not body: raise RuntimeError(f"California registry download failed (status {st})")
    return CA_URL, parse_ca(body)


# ---------- Oregon: tab-delimited licensee file (names and addresses, no websites) ----------

def parse_or(text):
    out = []
    for line in text.splitlines():
        c = [x.strip() for x in line.split("\t")]
        if len(c) >= 4 and c[1].upper().startswith("DATA-"):
            out.append(record(c[2].title() if c[2].isupper() else c[2], c[3], "", "", c[1],
                              {"address": ", ".join(x for x in (c[4], c[5], c[7]) if x) if len(c) > 7 else ""}))
    return out


def fetch_or(f):
    req = urllib.request.Request(OR_FILE, data=b"group_id=20&profession_name=Data+Broker&profession_id=28&profession_sub_id=28000",
                                 headers={"User-Agent": UA, "Accept": "*/*", "Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=60) as r:
        text = r.read().decode("latin-1")
    recs = parse_or(text)
    if len(recs) < 50: raise RuntimeError(f"Oregon file had only {len(recs)} brokers; the format may have changed")
    return OR_BASE, recs


# ---------- Excel (Texas export, Vermont bulk download): standard library only ----------

def read_xlsx(path):
    z = zipfile.ZipFile(path)
    ns = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    q = "{%s}" % ns["m"]
    shared = []
    if "xl/sharedStrings.xml" in z.namelist():
        shared = ["".join(t.text or "" for t in si.iter(q + "t")) for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall("m:si", ns)]
    rows = []
    for r in ET.fromstring(z.read("xl/worksheets/sheet1.xml")).iter(q + "row"):
        cells = {}
        for c in r.findall("m:c", ns):
            col = re.match(r"[A-Z]+", c.get("r")).group(0)
            v = c.find("m:v", ns)
            if v is not None: cells[col] = shared[int(v.text)] if c.get("t") == "s" else v.text
            else:
                t = c.find("m:is", ns)
                cells[col] = "".join(x.text or "" for x in t.iter(q + "t")) if t is not None else ""
        rows.append(cells)
    return rows


def table(rows):
    """First row that looks like a header (several non-empty cells) onward, as dicts keyed by header text."""
    for i, r in enumerate(rows):
        vals = [v for v in r.values() if (v or "").strip()]
        if len(vals) >= 4:
            keys = {col: (v or "").strip() for col, v in r.items()}
            return [{keys[c]: (v or "").strip() for c, v in row.items() if c in keys} for row in rows[i + 1:]]
    return []


def col(row, *needles):
    for k, v in row.items():
        kl = k.lower()
        if all(n in kl for n in needles): return v
    return ""


def parse_tx_rows(rows):
    return [record(col(r, "full legal name"), "", col(r, "website"), col(r, "consumer rights"), col(r, "registration number"))
            for r in table(rows) if col(r, "full legal name")]


def fetch_tx(f):
    path = os.path.join(INBOX, "tx.xlsx")
    try:
        from playwright.sync_api import sync_playwright
        os.makedirs(INBOX, exist_ok=True)
        with sync_playwright() as p:
            b = p.chromium.launch(); ctx = b.new_context(accept_downloads=True, user_agent=UA); pg = ctx.new_page()
            pg.goto(TX_URL, wait_until="networkidle", timeout=90000); pg.wait_for_timeout(5000)
            with pg.expect_download(timeout=90000) as d:
                pg.get_by_text("EXPORT TO EXCEL", exact=False).first.click()
            d.value.save_as(path); b.close()
    except ImportError:
        if not os.path.exists(path): raise RuntimeError("Texas needs Playwright (see tools/browser_profile.py) or registries/inbox/tx.xlsx")
    recs = parse_tx_rows(read_xlsx(path))
    if len(recs) < 100: raise RuntimeError(f"Texas export had only {len(recs)} brokers; the format may have changed")
    return TX_URL, recs


# ---------- Vermont: imported from a hand-downloaded file ----------

def fetch_vt(f):
    for name in ("vt.xlsx", "vt.csv", "vt.tsv"):
        path = os.path.join(INBOX, name)
        if not os.path.exists(path): continue
        if name.endswith(".xlsx"): rows = table(read_xlsx(path))
        else:
            text = open(path, encoding="utf-8-sig", errors="replace").read()
            rows = list(csv.DictReader(io.StringIO(text), delimiter="\t" if name.endswith("tsv") else ","))
        recs = [record(col(r, "name") or col(r, "business"), col(r, "dba") or col(r, "doing"),
                       col(r, "web") or col(r, "internet") or col(r, "url"), col(r, "opt"), col(r, "id") or col(r, "number"))
                for r in rows if (col(r, "name") or col(r, "business"))]
        if recs: return "https://bizfilings.vermont.gov/online/DatabrokerInquire", recs
    raise RuntimeError("Vermont's bulk download needs a Secretary of State online-services account: download it and save it as registries/inbox/vt.csv or vt.xlsx")


FETCHERS = {"ca": fetch_ca, "tx": fetch_tx, "or": fetch_or, "vt": fetch_vt}


def cmd_fetch(a):
    os.makedirs(OUT, exist_ok=True)
    f = pb.Fetcher()
    today = datetime.date.today().isoformat()
    for code in (a.only.split(",") if a.only else FETCHERS):
        try:
            source, recs = FETCHERS[code](f)
        except Exception as e:
            print(f"{code.upper()}: not updated ({e})"); continue
        json.dump({"jurisdiction": code.upper(), "source": source, "fetched": today, "count": len(recs), "brokers": recs},
                  open(os.path.join(OUT, f"{code}.json"), "w"), indent=1, ensure_ascii=False)
        print(f"{code.upper()}: {len(recs)} brokers ({sum(1 for r in recs if r['primary'])} with a website)")


# ---------- Merge ----------

def load_all():
    out = {}
    for path in sorted(glob.glob(os.path.join(OUT, "??.json"))):
        d = json.load(open(path)); out[d["jurisdiction"]] = d
    return out


def merge(registries):
    """One entry per website. Records with no website (Oregon) join an entry when their name or DBA equals one we know."""
    by_domain, name_to_domain = {}, {}
    for code, d in registries.items():
        for r in d["brokers"]:
            if not r["primary"]: continue
            e = by_domain.setdefault(r["primary"], {"domain": r["primary"], "names": [], "sites": set(), "registered_in": set(), "privacy_urls": {}})
            for n in (r["name"], r["dba"]):
                if n and n not in e["names"]: e["names"].append(n)
                if norm(n): name_to_domain.setdefault(norm(n), r["primary"])
            e["sites"].update(r["sites"]); e["registered_in"].add(code)
            if r["privacy_url"]: e["privacy_urls"].setdefault(code, r["privacy_url"])
    unresolved = []
    for code, d in registries.items():
        for r in d["brokers"]:
            if r["primary"]: continue
            dom = name_to_domain.get(norm(r["name"])) or name_to_domain.get(norm(r["dba"]))
            if dom:
                e = by_domain[dom]; e["registered_in"].add(code)
                if r["name"] not in e["names"]: e["names"].append(r["name"])
            else:
                unresolved.append({"jurisdiction": code, "name": r["name"], "dba": r["dba"], "reg_id": r["reg_id"], "address": r.get("address", "")})
    brokers = []
    for dom, e in sorted(by_domain.items()):
        brokers.append({"domain": dom, "names": e["names"], "sites": sorted(e["sites"]), "registered_in": sorted(e["registered_in"]),
                        "privacy_urls": e["privacy_urls"]})
    return brokers, unresolved


def cmd_merge(a):
    registries = load_all()
    if not registries: sys.exit("no registries yet; run `registries.py fetch` first")
    brokers, unresolved = merge(registries)
    today = datetime.date.today().isoformat()
    json.dump({"generated": today, "count": len(brokers), "brokers": brokers}, open(os.path.join(OUT, "all-brokers.json"), "w"), indent=1, ensure_ascii=False)
    json.dump({"generated": today, "unresolved": unresolved}, open(os.path.join(OUT, "unresolved.json"), "w"), indent=1, ensure_ascii=False)
    summary = {"generated": today, "known_sites": len(brokers), "unresolved": len(unresolved),
               "jurisdictions": {c: {"count": d["count"], "source": d["source"], "fetched": d["fetched"],
                                     "with_website": sum(1 for r in d["brokers"] if r["primary"])} for c, d in registries.items()},
               "in_several": sum(1 for b in brokers if len(b["registered_in"]) > 1)}
    json.dump(summary, open(os.path.join(OUT, "summary.json"), "w"), indent=1)

    seeds = {}
    for b in brokers:
        priv = next(iter(b["privacy_urls"].values()), "")
        seeds[b["domain"]] = {"name": b["names"][0] if b["names"] else b["domain"], "privacy_url": priv, "registered": b["names"], "registered_in": b["registered_in"]}
    json.dump(seeds, open("pipeline/registry-seeds.json", "w"), indent=1, ensure_ascii=False, sort_keys=True)

    added = []
    if a.add_sites:
        have = set()
        for line in open("pipeline/census-sites.txt"):
            if line.strip() and not line.startswith("#"): have.add(pb.registrable(line.split()[0]))
        added = sorted(set(seeds) - have)
        if added:
            with open("pipeline/census-sites.txt", "a") as fh:
                for d in added: fh.write(f"{d}\tregistry\n")

    # California DROP reaches every site registered in California.
    ca_sites = {s for b in brokers if "CA" in b["registered_in"] for s in b["sites"]}
    names_ca = {norm(n): n for b in brokers if "CA" in b["registered_in"] for n in b["names"]}
    cov = {}
    for d in our_domains():
        reg = pb.registrable(d)
        if reg in ca_sites:
            owner = next(b for b in brokers if "CA" in b["registered_in"] and reg in b["sites"])
            cov[d] = {"broker": owner["names"][0], "match": "domain"}
        elif len(norm(reg.split(".")[0])) >= 6 and norm(reg.split(".")[0]) in names_ca:
            cov[d] = {"broker": names_ca[norm(reg.split(".")[0])], "match": "name"}
    os.makedirs("platforms", exist_ok=True)
    json.dump({"fetched": today, "registered": registries["CA"]["count"] if "CA" in registries else 0, "covered": cov},
              open("platforms/ca-drop-coverage.json", "w"), indent=1, ensure_ascii=False, sort_keys=True)
    print(f"{len(brokers)} known broker sites from {len(registries)} registries ({summary['in_several']} in more than one), "
          f"{len(unresolved)} names with no website; {len(cov)} of our sites reached by California DROP"
          + (f"; added {len(added)} sites to the census" if a.add_sites else ""))


def our_domains():
    domains = set()
    for line in open("pipeline/census-sites.txt"):
        if line.strip() and not line.startswith("#"): domains.add(line.split()[0].lower())
    for p in glob.glob("directory/*.yml"):
        m = re.search(r'^domain:\s*"([^"]+)"', open(p).read(), re.M)
        if m: domains.add(m.group(1).lower())
    for p in glob.glob("brokers/*.yml"):
        t = open(p).read()
        for m in re.finditer(r"^\s*-\s*open:\s*(\S+)", t, re.M): domains.add(urllib.parse.urlsplit(m.group(1)).netloc.lower().removeprefix("www."))
        m = re.search(r"^covers:\s*\[(.*?)\]", t, re.M)
        if m: domains.update(x.strip().lower() for x in m.group(1).split(",") if x.strip())
    return sorted(domains)


def main():
    ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fetch"); f.add_argument("--only", default="")
    m = sub.add_parser("merge"); m.add_argument("--add-sites", action="store_true")
    a = ap.parse_args()
    {"fetch": cmd_fetch, "merge": cmd_merge}[a.cmd](a)


if __name__ == "__main__":
    main()
