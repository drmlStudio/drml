#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${DRML_BIN:-$ROOT/zig-out/bin/drml}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/package.json" <<'JSON'
{"name":"drml-live-install-fixture","version":"0.1.0","devDependencies":{"is-number":"7.0.0"}}
JSON

(cd "$TMP" && "$BIN" install >stdout 2>stderr)
test -f "$TMP/node_modules/is-number/package.json"
python3 - "$TMP/drml-lock.json" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1]))
pkg = lock["packages"]["is-number"]
assert pkg["version"] == "7.0.0"
assert pkg["dev"] is True
assert pkg["integrity"].startswith("sha512-")
print("live install: PASS")
PY
