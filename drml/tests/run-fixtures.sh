#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures"
BIN="${DRML_BIN:-$ROOT/zig-out/bin/drml}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass_count=0
fail_count=0
xfail_count=0

run_success() {
  local name="$1"
  shift
  local dir="$TMP/$name"
  mkdir -p "$dir"
  cp -R "$FIXTURES/$name/." "$dir/"
  if ! (cd "$dir" && "$BIN" install --lockfile-only "$@" >stdout 2>stderr); then
    echo "FAIL (expected success): $name"
    cat "$dir/stderr"
    exit 1
  fi
  python3 -m json.tool "$dir/drml-lock.json" >/dev/null
  pass_count=$((pass_count + 1))
  echo "PASS: $name"
}

run_failure() {
  local name="$1"
  local needle="$2"
  local dir="$TMP/$name"
  mkdir -p "$dir"
  cp -R "$FIXTURES/$name/." "$dir/"
  if (cd "$dir" && "$BIN" install --lockfile-only >stdout 2>stderr); then
    echo "FAIL (expected failure): $name"
    cat "$dir/stdout" "$dir/stderr"
    exit 1
  fi
  if ! grep -Fq "$needle" "$dir/stderr"; then
    echo "FAIL (wrong diagnostic): $name; expected '$needle'"
    cat "$dir/stderr"
    exit 1
  fi
  fail_count=$((fail_count + 1))
  echo "EXPECTED FAILURE: $name"
}

run_registry_failure() {
  local name="$1"
  local needle="$2"
  local dir="$TMP/$name"
  mkdir -p "$dir"
  cp -R "$FIXTURES/$name/." "$dir/"
  if (cd "$dir" && "$BIN" install >stdout 2>stderr); then
    echo "FAIL (registry failure expected): $name"
    exit 1
  fi
  grep -Fq "$needle" "$dir/stderr"
  echo "REGISTRY EXPECTED FAILURE: $name"
}

run_build_success() {
  local name="$1"
  local dir="$TMP/$name"
  mkdir -p "$dir"
  cp -R "$FIXTURES/$name/." "$dir/"
  if ! (cd "$dir" && "$BIN" build >stdout 2>stderr); then
    echo "FAIL (build expected success): $name"
    cat "$dir/stderr"
    exit 1
  fi
  test "$(cat "$dir/build-output.txt")" = "build-ok"
  pass_count=$((pass_count + 1))
  echo "BUILD PASS: $name"
}

run_script_success() {
  local name="$1"
  local dir="$TMP/$name-script"
  mkdir -p "$dir"
  cp -R "$FIXTURES/$name/." "$dir/"
  if ! (cd "$dir" && "$BIN" run test run-ok >stdout 2>stderr); then
    echo "FAIL (run expected success): $name"
    cat "$dir/stderr"
    exit 1
  fi
  test "$(cat "$dir/test-output.txt")" = "run-ok"
  if ! (cd "$dir" && "$BIN" test implicit-ok >stdout 2>stderr); then
    echo "FAIL (implicit script expected success): $name"
    cat "$dir/stderr"
    exit 1
  fi
  test "$(cat "$dir/test-output.txt")" = "implicit-ok"
  pass_count=$((pass_count + 1))
  echo "RUN PASS: $name"
}

run_exec_success() {
  local name="$1"
  local dir="$TMP/$name-exec"
  mkdir -p "$dir"
  cp -R "$FIXTURES/$name/." "$dir/"
  if ! (cd "$dir" && "$BIN" exec printf exec-ok >stdout 2>exec-output.txt); then
    echo "FAIL (exec expected success): $name"
    cat "$dir/exec-output.txt"
    exit 1
  fi
  test "$(cat "$dir/exec-output.txt")" = "exec-ok"
  pass_count=$((pass_count + 1))
  echo "EXEC PASS: $name"
}

run_workspace_link_success() {
  local name="$1"
  local dir="$TMP/$name-link"
  mkdir -p "$dir"
  cp -R "$FIXTURES/$name/." "$dir/"
  if ! (cd "$dir" && "$BIN" install >stdout 2>stderr); then
    echo "FAIL (workspace link expected success): $name"
    cat "$dir/stderr"
    exit 1
  fi
  test -L "$dir/node_modules/local-pkg"
  pass_count=$((pass_count + 1))
  echo "WORKSPACE LINK PASS: $name"
}

run_success minimal-exact
run_success all-dependency-types --include-optional-peers
run_success package-manager-npm
run_success package-manager-pnpm
run_success package-manager-yarn
run_success package-manager-bun
run_success scoped-package
run_build_success build-script
run_script_success build-script
run_exec_success build-script
run_success range-version
run_success workspace-protocol
run_workspace_link_success workspace-protocol
run_success git-dependency
run_success foreign-package-lock-json
run_success foreign-npm-shrinkwrap-json
run_success foreign-pnpm-lock-yaml
run_success foreign-yarn-lock
run_success foreign-bun-lock
run_success foreign-bun-lockb
run_success omit-dev --omit-dev
run_success optional-peer
cp "$TMP/optional-peer/drml-lock.json" "$TMP/optional-peer-default-lock.json"
run_success optional-peer --include-optional-peers
run_success workspace-dev
run_success lifecycle-option --run-scripts

python3 - <<'PY' "$TMP/omit-dev/drml-lock.json" "$TMP/optional-peer-default-lock.json" "$TMP/optional-peer/drml-lock.json" "$TMP/workspace-dev/drml-lock.json"
import json, sys
omit_dev, optional_peer_default, optional_peer, workspace_dev = [json.load(open(path)) for path in sys.argv[1:]]
assert omit_dev["packages"] == {}
assert optional_peer_default["packages"] == {}
assert optional_peer["packages"] == {"react": {
    "requested": "18.3.1", "version": "18.3.1",
    "source": "https://registry.npmjs.org/react/-/react-18.3.1.tgz",
    "integrity": None, "dev": False, "optional": False, "peer": True}}
assert workspace_dev["packages"]["typescript"]["dev"] is True
PY

python3 - <<'PY' "$TMP/range-version/drml-lock.json" "$TMP/git-dependency/drml-lock.json"
import json, sys
range_lock, git_lock = [json.load(open(path)) for path in sys.argv[1:]]
assert range_lock["packages"]["left-pad"]["version"] == "1.3.0"
assert git_lock["packages"]["demo"]["source"] == "git+https://github.com/example/demo.git"
PY

python3 - <<'PY' "$TMP/all-dependency-types/drml-lock.json"
import json, sys
lock = json.load(open(sys.argv[1]))
assert lock["packageManager"] == "pnpm@9.15.0"
assert set(lock["packages"]) == {"left-pad", "typescript", "fsevents", "react"}
assert lock["packages"]["typescript"]["dev"] is True
assert lock["packages"]["fsevents"]["optional"] is True
assert lock["packages"]["react"]["peer"] is True
PY

auto_failures=(
  "invalid-dependencies-type|InvalidDependencySpec"
  "invalid-peer-meta|InvalidDependencySpec"
  "invalid-package-manager|InvalidPackageManager"
)
for item in "${auto_failures[@]}"; do
  IFS='|' read -r name needle <<< "$item"
  run_failure "$name" "$needle"
done

run_success monorepo-root
run_success nested-package

if [[ "${DRML_LIVE_TESTS:-0}" == "1" ]]; then
  run_registry_failure nonexistent-package PackageNotFound
  run_registry_failure nonexistent-version PackageVersionNotFound
else
  echo "SKIP: registry existence fixtures (set DRML_LIVE_TESTS=1)"
fi

missing="$TMP/missing-manifest"
mkdir -p "$missing"
if (cd "$missing" && "$BIN" install --lockfile-only >stdout 2>stderr); then
  echo "FAIL (missing package.json unexpectedly succeeded)"
  exit 1
fi
echo "EXPECTED FAILURE: missing-package-json"
fail_count=$((fail_count + 1))

echo "Fixture summary: $pass_count passed, $fail_count expected failures, $xfail_count known registry gaps"

run_check_success() {
  local name="$1"
  local dir="$TMP/check-$name"
  mkdir -p "$dir"
  cp -R "$ROOT/tests/check-fixtures/$name/." "$dir/"
  if ! (cd "$dir" && "$BIN" check >stdout 2>stderr); then
    echo "FAIL (checker expected success): $name"
    cat "$dir/stderr"
    exit 1
  fi
  echo "CHECK PASS: $name"
}

run_check_failure() {
  local name="$1"
  local dir="$TMP/check-$name"
  mkdir -p "$dir"
  cp -R "$ROOT/tests/check-fixtures/$name/." "$dir/"
  if (cd "$dir" && "$BIN" check >stdout 2>stderr); then
    echo "FAIL (checker expected failure): $name"
    exit 1
  fi
  for package in not-declared @scope/missing another-missing dynamic-missing; do
    grep -Fq "imported package '$package'" "$dir/stderr"
  done
  echo "CHECK EXPECTED FAILURE: $name"
}

run_check_success clean
run_check_failure missing

audit_root="$ROOT/tests/audit-fixtures"

run_audit_install_failure() {
  local name="$1"
  local needle="$2"
  local dir="$TMP/audit-$name"
  mkdir -p "$dir"
  cp -R "$audit_root/$name/." "$dir/"
  if (cd "$dir" && "$BIN" install --lockfile-only >stdout 2>stderr); then
    echo "FAIL (audit expected failure): $name"
    exit 1
  fi
  grep -Fq "$needle" "$dir/stderr"
  echo "AUDIT EXPECTED FAILURE: $name"
}

run_audit_check_failure() {
  local name="$1"
  shift
  local dir="$TMP/audit-$name"
  mkdir -p "$dir"
  cp -R "$audit_root/$name/." "$dir/"
  if (cd "$dir" && "$BIN" check >stdout 2>stderr); then
    echo "FAIL (audit checker expected failure): $name"
    exit 1
  fi
  for package in "$@"; do
    grep -Fq "imported package '$package'" "$dir/stderr"
  done
  echo "AUDIT CHECK EXPECTED FAILURE: $name"
}

run_audit_check_success() {
  local name="$1"
  local dir="$TMP/audit-$name"
  mkdir -p "$dir"
  cp -R "$audit_root/$name/." "$dir/"
  (cd "$dir" && "$BIN" check >stdout 2>stderr)
  echo "AUDIT CHECK PASS: $name"
}

run_audit_install_failure non-object-array InvalidManifest
run_audit_install_failure non-object-null InvalidManifest
run_audit_install_failure leading-zero UnsupportedVersionRange
run_audit_check_success duplicate-conflict

for command in "install unexpected-argument" "check unexpected-argument" "init one two"; do
  dir="$TMP/audit-cli-${command// /-}"
  mkdir -p "$dir"
  if (cd "$dir" && "$BIN" $command >stdout 2>stderr); then
    echo "FAIL (audit expected CLI argument failure): $command"
    exit 1
  fi
  grep -Fq "InvalidArguments" "$dir/stderr"
done
echo "AUDIT CLI ARGUMENTS: PASS"

for name in escaped-name scoped-url duplicate-same duplicate-conflict; do
  dir="$TMP/audit-$name"
  mkdir -p "$dir"
  cp -R "$audit_root/$name/." "$dir/"
  (cd "$dir" && "$BIN" install --lockfile-only >stdout 2>stderr)
  python3 -m json.tool "$dir/drml-lock.json" >/dev/null
done
python3 - <<'PY' "$TMP/audit-escaped-name/drml-lock.json" "$TMP/audit-scoped-url/drml-lock.json" "$TMP/audit-duplicate-same/drml-lock.json" "$TMP/audit-duplicate-conflict/drml-lock.json"
import json, sys
escaped, scoped, duplicate, conflict = [json.load(open(path)) for path in sys.argv[1:]]
assert escaped["name"] == 'a"b'
assert scoped["packages"]["@scope/pkg"]["source"].endswith("/@scope/pkg/-/pkg-1.2.3.tgz")
assert list(duplicate["packages"]) == ["foo"]
assert duplicate["packages"]["foo"]["dev"] is False
assert conflict["packages"]["foo"]["requested"] == "1.2.3"
PY
echo "AUDIT LOCKFILE ASSERTIONS: PASS"

run_audit_check_success regex-clean
run_audit_check_failure multiline-missing multiline-missing-package
run_audit_check_failure comment-missing import-comment-missing require-comment-missing
