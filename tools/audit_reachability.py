#!/usr/bin/env python3
"""Audits that every site on the to-do list (every directory entry that is not `closed:` or `excluded:`) has at least one working way in:
an opt-out page that loads, or an email address whose domain accepts mail.

For each entry it checks, in order: the live-form page, `opt_out_url`, the stored form's page (each loads a real page: not an error, not a soft 404,
not an unreachable host; a bot wall counts as reachable because a person's browser gets through it), then the contact email's domain (an MX or address
record on a public resolver), and only if all of those fail the bare domain's front page.

  ok    a working opt-out page or a mailable address
  weak  only the front page of the site works (a person has to find the way)
  none  nothing works

Writes pipeline/reachability.json (every result) and prints the entries that are not ok. Polite: two requests per host at a time.
Usage: audit_reachability.py [--dir directory] [--out pipeline/reachability.json] [--workers 24]
"""
import argparse, collections, concurrent.futures as cf, datetime, glob, json, os, re, subprocess, threading

import yamlio

UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
BLOCK = re.compile(r"just a moment|attention required|cf-chl|captcha|are you a human|access denied|enable javascript and cookies|ddos|incapsula|akamai|perimeterx|px-captcha|security check|verify you are human", re.I)
SOFT404 = re.compile(r"<title>[^<]*(404|not found|page unavailable|no longer available|doesn.t exist|does not exist|page cannot be found)[^<]*</title>", re.I)
HOST_GATES = collections.defaultdict(lambda: threading.Semaphore(2))
GATE_LOCK = threading.Lock()


def gate(host):
    with GATE_LOCK:
        return HOST_GATES[host]


def parse(path):
    t = yamlio.load(path)
    e = {"id": t.get("id"), "domain": t.get("domain"), "name": t.get("name"), "url": t.get("opt_out_url"), "email": t.get("contact_email"),
         "closed": "closed" in t, "excluded": "excluded" in t}
    e["form_page"] = (t.get("opt_out_form") or {}).get("page")
    live = t.get("live_form") or {}
    e["live_page"] = live.get("page") if live.get("found") is True else None
    return e


def fetch(url):
    """(verdict, detail): ok | blocked (reachable) | dead."""
    host = re.sub(r"^https?://([^/:]+).*", r"\1", url)
    with gate(host):
        try:
            r = subprocess.run(["curl", "-sL", "-A", UA, "--max-time", "25", "--max-filesize", "400000", "-o", "-", "-w", "\n__CODE__%{http_code} %{url_effective}", url],
                               capture_output=True, text=True, errors="replace", timeout=40)
        except subprocess.TimeoutExpired:
            return "dead", "timeout"
    out = r.stdout
    m = re.search(r"\n__CODE__(\d+) (\S*)$", out)
    if not m:
        return "dead", f"curl exit {r.returncode}"
    code, final = int(m.group(1)), m.group(2)
    body = out[:m.start()]
    if code == 0:
        return "dead", f"no response (curl {r.returncode})"
    if code in (403, 429, 503, 401, 999) and BLOCK.search(body) or code in (403, 429, 999):
        return "blocked", f"HTTP {code}, bot wall"
    if code >= 400:
        return "dead", f"HTTP {code}"
    if SOFT404.search(body[:6000]):
        return "dead", f"HTTP {code}, but the page says not found"
    if BLOCK.search(body[:4000]) and len(re.sub(r"<[^>]+>", "", body)) < 1500:
        return "blocked", f"HTTP {code}, bot wall"
    return "ok", f"HTTP {code}" + ("" if final.rstrip("/") == url.rstrip("/") else f" -> {final[:80]}")


def mail_ok(domain):
    for kind in ("MX", "A"):
        out = subprocess.run(["dig", "@8.8.8.8", domain, kind, "+short", "+time=5", "+tries=2"], capture_output=True, text=True).stdout.strip()
        if out and "no servers could be reached" not in out:
            if kind == "MX" and out.strip() == "0 .":
                return False, "null MX (the domain refuses mail)"
            return True, f"{kind} record"
    return False, "no MX or address record"


def audit(e):
    res = {"id": e["id"], "name": e["name"], "domain": e["domain"], "pages": {}, "email": None}
    seen = []
    for label, u in (("live_form", e["live_page"]), ("opt_out_url", e["url"]), ("form_page", e["form_page"])):
        if u and u not in seen:
            seen.append(u); res["pages"][u] = (label,) + fetch(u)
    if e["email"]:
        ok, why = mail_ok(e["email"].split("@")[-1])
        res["email"] = {"address": e["email"], "ok": ok, "why": why}
    page_ok = any(v[1] in ("ok", "blocked") for v in res["pages"].values())
    mail = bool(res["email"] and res["email"]["ok"])
    if page_ok or mail:
        res["status"] = "ok"
    else:
        front = None
        for h in (f"https://{e['domain']}/", f"https://www.{e['domain']}/"):
            v, d = fetch(h)
            if v in ("ok", "blocked"): front = (h, v, d); break
        res["front"] = front
        res["status"] = "weak" if front else "none"
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="directory"); ap.add_argument("--out", default="pipeline/reachability.json"); ap.add_argument("--workers", type=int, default=24)
    a = ap.parse_args()
    entries = [parse(p) for p in sorted(glob.glob(os.path.join(a.dir, "*.yml")))]
    todo = [e for e in entries if e["id"] and not e["closed"] and not e["excluded"]]
    print(f"{len(entries)} entries, {len(todo)} on the to-do list (closed and excluded left out)", flush=True)
    results = []
    with cf.ThreadPoolExecutor(a.workers) as ex:
        for i, r in enumerate(ex.map(audit, todo), 1):
            results.append(r)
            if i % 100 == 0: print(f"  {i}/{len(todo)}", flush=True)
    counts = collections.Counter(r["status"] for r in results)
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    json.dump({"checked": datetime.date.today().isoformat(), "counts": counts, "results": results}, open(a.out, "w"), indent=1)
    print("RESULT", dict(counts))
    for r in results:
        if r["status"] != "ok":
            print(f"{r['status'].upper():5} {r['id']}: " + "; ".join(f"{lab} {v} ({d})" for u, (lab, v, d) in r["pages"].items()) + (f"; email {r['email']['address']}: {r['email']['why']}" if r["email"] else "; no email") + (f"; front page {r['front'][2]}" if r.get("front") else ""))
    dead_mail = [r for r in results if r["email"] and not r["email"]["ok"]]
    print(f"\n{len(dead_mail)} listed emails whose domain cannot take mail:")
    for r in dead_mail: print(f"  {r['id']}: {r['email']['address']} ({r['email']['why']})")


if __name__ == "__main__":
    main()
