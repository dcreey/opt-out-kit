#!/usr/bin/env python3
"""Checks what a built app contains (CI's build job runs it on the app it built): the compiled catalog is there, and no data file is shipped beside it.

  check_bundle.py <path/to/OptOutKit.app>    exit 1, naming each problem, when the catalog is missing or a data folder or file was shipped

The app's data is compiled into Catalog.sqlite at build time and read through SQLite (docs/STORAGE.md); a YAML, script or table file in the bundle means a
build step copied the sources in. What the catalog holds is tested on the Mac (Model/CatalogAppTests).
"""
import os, sys

FOLDERS = ["directory", "brokers", "platforms", "jurisdictions", "terms", "PageScripts", "data"]
EXTENSIONS = {".yml", ".yaml", ".js", ".tsv"}


def problems(app):
    out = []
    if not os.path.isfile(os.path.join(app, "Catalog.sqlite")):
        out.append("no Catalog.sqlite: the catalog build step did not run")
    for folder in FOLDERS:
        if os.path.exists(os.path.join(app, folder)):
            out.append(f"{folder}/ is shipped; it belongs compiled into the catalog")
    for root, _, files in os.walk(app):
        for f in files:
            if os.path.splitext(f)[1].lower() in EXTENSIONS:
                out.append(f"a data file is shipped: {os.path.relpath(os.path.join(root, f), app)}")
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    found = problems(sys.argv[1])
    for p in found:
        print(f"::error::{p}")
    if not found:
        print(f"{sys.argv[1]}: the catalog and no data files")
    sys.exit(1 if found else 0)


if __name__ == "__main__":
    main()
