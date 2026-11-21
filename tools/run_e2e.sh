#!/bin/bash
# Runs the end-to-end UI tests against the fixture brokers: starts fixtures/server.py, compiles the catalog that carries the fixture sites, runs the UI tests
# in AppUITests/FixtureJourneyUITests (or the ones named in the arguments, e.g. -only-testing:...), and stops the server.
#   tools/run_e2e.sh [-destination ...] [xcodebuild test arguments]
# docs/TESTING.md, "End-to-end tests against fixture pages".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PORT=8765
CATALOG="$ROOT/.build/fixtures/Catalog.sqlite"
bash fixtures/build_catalog.sh "$CATALOG"
python3 fixtures/server.py "$PORT" > .build/fixtures/server.log 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/__ready" >/dev/null && break; sleep 0.1; done
export TEST_RUNNER_OPTOUT_FIXTURE_CATALOG="$CATALOG" TEST_RUNNER_OPTOUT_FIXTURE_URL="http://127.0.0.1:$PORT"
ARGS=("$@")
case " ${ARGS[*]:-} " in *" -only-testing:"*) ;; *) ARGS+=(-only-testing:OptOutKitUITests/FixtureJourneyUITests);; esac
xcodebuild test -project OptOutKit.xcodeproj -scheme OptOutKit -skipPackagePluginValidation "${ARGS[@]}"
