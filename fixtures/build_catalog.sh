#!/bin/bash
# Compiles the integration build's catalog: the app's own data (flows' laws, platforms, jurisdictions, terms, page scripts, ZIP codes) with the fixture brokers
# of fixtures/sites in place of the real directory, so the app loads fixture sites exactly as it loads real ones. Writes <output.sqlite> (default
# .build/fixtures/Catalog.sqlite). The UI tests are run against it by tools/run_e2e.sh. docs/TESTING.md, "End-to-end tests against fixture pages".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/.build/fixtures/Catalog.sqlite}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
for d in platforms jurisdictions terms registries data; do cp -R "$ROOT/$d" "$WORK/$d"; done
mkdir -p "$WORK/App"; cp -R "$ROOT/App/PageScripts" "$WORK/App/PageScripts"
cp -R "$ROOT/fixtures/sites" "$WORK/directory"
cp -R "$ROOT/fixtures/flows" "$WORK/brokers"
swift run --package-path "$ROOT/Packages/OptOutKitCore" catalog-builder "$WORK" "$OUT"
