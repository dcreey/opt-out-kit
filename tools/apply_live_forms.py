#!/usr/bin/env python3
"""Writes what opening each page in a real browser found into the directory as a `live_form:` block.

Input is the shard files of AppTests/LiveFormDiscoveryTests: `domain<TAB>result<TAB>page<TAB>blockers`. `form` means an opt-out form was
found and filled on the live page (nothing sent). Usage: apply_live_forms.py DIR_WITH_TSV [--dir directory] [--date YYYY-MM-DD]
"""
import argparse, datetime, glob, os, re, sys


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("shards"); ap.add_argument("--dir", default="directory"); ap.add_argument("--date", default=datetime.date.today().isoformat())
    a = ap.parse_args(); found = missing = 0
    for f in sorted(glob.glob(os.path.join(a.shards, "shard-*.tsv"))):
        for line in open(f):
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 4: continue
            domain, result, page, blockers = parts[:4]
            path = os.path.join(a.dir, re.sub(r"[^a-z0-9]+", "_", domain.lower()).strip("_") + ".yml")
            if not os.path.exists(path): continue
            s = re.sub(r"\nlive_form:\n(?:[ \t]+.*\n?)*", "\n", open(path).read()).rstrip("\n")
            ok = result == "form"
            items = ", ".join('"' + b.replace('"', "'") + '"' for b in blockers.split(";") if b)
            block = f'\nlive_form:\n  checked: "{a.date}"\n  found: {"true" if ok else "false"}\n'
            if ok: block += f'  page: "{page}"\n  blockers: [{items}]\n'
            open(path, "w").write(s + block); found += ok; missing += not ok
    print(f"found a form on {found} sites, none on {missing}")


if __name__ == "__main__":
    main()
