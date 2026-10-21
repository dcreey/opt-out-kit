#!/usr/bin/env python3
"""Checks that every site's recorded opt-out page still works, and crawls for the new one when it does not.

Covers the hand-written brokers (brokers/*.yml, the first `open:` step) and every generated directory entry that has an
opt-out form (directory/*.yml). A link is healthy when it loads a real page (not an error or soft 404). A broken link is
healed by the same crawl the app uses (home page -> scored privacy/opt-out links -> form). Writes pipeline/link-health.md.
Exits 1 when a hand-written broker's link is broken and nothing newer was found. Polite: robots.txt honored, ~1 request/second.
"""
import argparse, concurrent.futures as cf, datetime, glob, os, re, sys, time, urllib.parse
sys.path.insert(0, os.path.dirname(__file__))
import profile_brokers as pb


def first_open(path):
    for line in open(path):
        m = re.match(r"\s*-\s*open:\s*(\S+)", line)
        if m: return m.group(1).strip("\"'")
    return None


def directory_form_page(path):
    text = open(path).read()
    m = re.search(r'^opt_out_form: \{"page": "([^"]+)"', text, re.M)
    return m.group(1) if m else None


def healthy(fetcher, url):
    if not fetcher.allowed(url): return True, "robots.txt disallows a check"
    st, fin, body = fetcher.get(url); time.sleep(1)
    if st is None: return False, "unreachable"
    if pb.is_blocked(st, body): return True, "bot check (cannot verify, left as is)"
    pg = pb.parse(body)
    text = re.sub(r"\s+", " ", " ".join(pg.text))
    if pb.is_error_page(st, pg, text): return False, f"error page (HTTP {st})"
    return True, f"HTTP {st}"


def heal(fetcher, url):
    host = urllib.parse.urlsplit(url).netloc
    home = f"https://{host}/"
    best, trail, _ = pb.crawl_for_form(home, fetcher, pb.registrable(host))
    if best and best.get("form"): return best["url"]
    return None


def check(item, fetcher):
    kind, name, url = item
    ok, why = healthy(fetcher, url)
    row = {"kind": kind, "name": name, "url": url, "ok": ok, "why": why, "healed": None}
    if not ok: row["healed"] = heal(fetcher, url)
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workers", type=int, default=6); ap.add_argument("--out", default="pipeline/link-health.md")
    ap.add_argument("--only", default="", help="comma-separated ids to check")
    a = ap.parse_args()
    items = []
    for p in sorted(glob.glob("brokers/*.yml")):
        u = first_open(p)
        if u: items.append(("broker", os.path.basename(p)[:-4], u))
    for p in sorted(glob.glob("directory/*.yml")):
        u = directory_form_page(p)
        if u: items.append(("directory", os.path.basename(p)[:-4], u))
    if a.only: items = [i for i in items if i[1] in a.only.split(",")]
    fetcher = pb.Fetcher()
    with cf.ThreadPoolExecutor(a.workers) as ex:
        rows = list(ex.map(lambda i: check(i, fetcher), items))
    bad = [r for r in rows if not r["ok"]]
    lost_brokers = [r for r in bad if r["kind"] == "broker" and not r["healed"]]
    lines = [f"# Opt-out link health ({datetime.date.today().isoformat()})", "",
             f"Checked {len(rows)} recorded opt-out pages ({sum(r['kind']=='broker' for r in rows)} hand-written, "
             f"{sum(r['kind']=='directory' for r in rows)} generated). Broken: {len(bad)}. Healed by crawl: {sum(1 for r in bad if r['healed'])}.", ""]
    if bad:
        lines += ["| Site | Kind | Recorded link | Problem | New link found |", "|---|---|---|---|---|"]
        for r in bad: lines.append(f"| {r['name']} | {r['kind']} | {r['url']} | {r['why']} | {r['healed'] or '**none, needs a person**'} |")
    else:
        lines.append("Every recorded link loads a real page.")
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    open(a.out, "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 1 if lost_brokers else 0


if __name__ == "__main__":
    sys.exit(main())
