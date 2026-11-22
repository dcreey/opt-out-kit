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
python3 "$ROOT/fixtures/add_terms.py" "$WORK/terms/library.yml"          # the fixture terms prompts, reviewed, for the terms-accepted journey
mkdir -p "$WORK/App"; cp -R "$ROOT/App/PageScripts" "$WORK/App/PageScripts"
cp -R "$ROOT/fixtures/sites" "$WORK/directory"
cp -R "$ROOT/fixtures/flows" "$WORK/brokers"
# The fixture sites point at the server on port 8765; a run on another port (OPTOUT_FIXTURE_PORT, tools/run_e2e.sh) gets its own copy pointing there.
PORT="${OPTOUT_FIXTURE_PORT:-8765}"
if [ "$PORT" != 8765 ]; then sed -i.bak "s#127.0.0.1:8765#127.0.0.1:$PORT#g" "$WORK"/directory/*.yml "$WORK"/brokers/*.yml 2>/dev/null || true; rm -f "$WORK"/directory/*.bak "$WORK"/brokers/*.bak; fi
swift run --package-path "$ROOT/Packages/OptOutKitCore" catalog-builder "$WORK" "$OUT"
