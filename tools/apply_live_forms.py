#!/usr/bin/env python3
"""Writes what opening each page in a real browser found into the directory as a `live_form:` block.

Input is the shard files of AppTests/LiveFormDiscoveryTests: `domain<TAB>result<TAB>page<TAB>blockers`. `form` means an opt-out form was
found and filled on the live page (nothing sent). Usage: apply_live_forms.py DIR_WITH_TSV [--dir directory] [--date YYYY-MM-DD]
"""
import argparse, datetime, glob, os

import yamlio


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("shards"); ap.add_argument("--dir", default="directory"); ap.add_argument("--date", default=datetime.date.today().isoformat())
    a = ap.parse_args(); found = missing = 0
    for f in sorted(glob.glob(os.path.join(a.shards, "shard-*.tsv"))):
        for line in open(f):
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 4: continue
            domain, result, page, blockers = parts[:4]; mail = parts[4] if len(parts) > 4 else ""
            path = yamlio.entry_path(a.dir, domain)
            if not os.path.exists(path): continue
            doc = yamlio.load(path)
            ok = result == "form"
            live = {"checked": a.date, "found": ok}
            if blockers == "wall": live["blockers"] = ["wall"]
            if ok: live["page"] = page; live["blockers"] = [b.replace('"', "'") for b in blockers.split(";") if b]
            doc.pop("live_form", None); doc["live_form"] = live
            if mail and "contact_email" not in doc:
                doc["contact_email"] = mail; doc["contact_email_source"] = "browser"
            yamlio.save(path, doc); found += ok; missing += not ok
    print(f"found a form on {found} sites, none on {missing}")


if __name__ == "__main__":
    main()
