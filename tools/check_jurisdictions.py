#!/usr/bin/env python3
"""Checks jurisdictions/*.yml and reports law facts nobody has reviewed lately.

State laws change slowly, so facts carry a `reviewed:` date and this flags anything older than --max-days (default 180). It also
checks that every live registry names an importer that exists, every deletion platform exists, and the registry files that the
app shows counts from are present. Exit 1 when something is stale or broken, so a scheduled job can open a reminder.
Usage: check_jurisdictions.py [--max-days 180] [--today YYYY-MM-DD]
"""
import argparse, datetime, glob, os, re, sys

IMPORTERS = {"ca", "tx", "or", "vt"}      # tools/registries.py FETCHERS
# A value as written in the file, quoted ('single', the style of the hand-written YAML: .yamllint.yml) or not.
Q = r"""['"]?"""


def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] == "'": return v[1:-1].replace("''", "'")
    if len(v) >= 2 and v[0] == v[-1] == '"': return v[1:-1]
    return v


def entries(path):
    text = open(path).read()
    blocks = re.split(r"\n  - id: ", text)[1:]
    for b in blocks:
        jid = unquote(b.split("\n", 1)[0])
        yield jid, b


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-days", type=int, default=180); ap.add_argument("--today", default="")
    a = ap.parse_args()
    today = datetime.date.fromisoformat(a.today) if a.today else datetime.date.today()
    platforms = {os.path.basename(p)[:-4] for p in glob.glob("platforms/*.yml")}
    problems, stale, total = [], [], 0
    for path in sorted(glob.glob("jurisdictions/*.yml")):
        for jid, b in entries(path):
            total += 1
            m = re.search(r"^    reviewed:\s*" + Q + r"(\d{4}-\d{2}-\d{2})", b, re.M)
            if not m: problems.append(f"{jid}: no reviewed date"); continue
            age = (today - datetime.date.fromisoformat(m.group(1))).days
            if age > a.max_days: stale.append((jid, m.group(1), age))
            if path.endswith("countries.yml"):
                if not re.search(r"^    regulator:\n      name:", b, re.M): problems.append(f"{jid}: no regulator")
            if not re.search(r"^    sources: \[" + Q + r"https://", b, re.M): problems.append(f"{jid}: no sources")
            for pm in re.finditer(r"^        as_of: " + Q + r"(\d{4}-\d{2}-\d{2})", b, re.M):       # pending laws go stale faster than law texts
                if (today - datetime.date.fromisoformat(pm.group(1))).days > 90: stale.append((jid + " (pending law)", pm.group(1), (today - datetime.date.fromisoformat(pm.group(1))).days))
            for pm in re.finditer(r"^        stage: (\S+)", b, re.M):
                if unquote(pm.group(1)) not in ("proposed", "advancing", "passed"): problems.append(f"{jid}: unknown pending stage {pm.group(1)}")
            if re.search(r"^      status: " + Q + "live", b, re.M) and not path.endswith("countries.yml"):
                f = re.search(r"""^      fetcher: ['"]([^'"]*)['"]""", b, re.M)
                if not f or f.group(1) not in IMPORTERS: problems.append(f"{jid}: live registry without a known importer")
            d = re.search(r"^    deletion_platform:\s*(\S+)", b, re.M)
            if d and unquote(d.group(1)) not in platforms: problems.append(f"{jid}: deletion platform {d.group(1)} does not exist")
    for need in ("registries/summary.json", "registries/all-brokers.json"):
        if not os.path.exists(need): problems.append(f"{need} is missing: run tools/registries.py fetch && merge")
    print(f"{total} jurisdictions checked; {len(stale)} not reviewed in {a.max_days} days; {len(problems)} problems")
    for jid, d, age in stale: print(f"  STALE {jid}: last reviewed {d} ({age} days ago)")
    for p in problems: print("  PROBLEM", p)
    return 1 if stale or problems else 0


if __name__ == "__main__":
    sys.exit(main())
