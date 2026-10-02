#!/usr/bin/env bash
set -euo pipefail

TARGET="${DRML_TARGET:-x86_64-linux-gnu}"
ARCHIVE="${DRML_ARCHIVE:-local}"
VERSION="${DRML_VERSION:-dev}"

zig build -Dtarget="$TARGET" -Doptimize=ReleaseSafe

binary="zig-out/bin/drml"
stage_binary="drml"
if [[ "$TARGET" == *windows* ]]; then
  binary="zig-out/bin/drml.exe"
elif [[ "$TARGET" == wasm32-wasi* ]]; then
  stage_binary="drml.wasm"
fi
if [[ ! -f "$binary" ]]; then
  echo "release binary not found: $binary" >&2
  exit 1
fi

rm -rf dist
mkdir -p dist/stage
cp "$binary" "dist/stage/$stage_binary"
cp README.md LICENSE dist/stage/
archive="dist/drml-${VERSION}-${ARCHIVE}.zip"
(cd dist/stage && zip -q -r "../$(basename "$archive")" .)
rm -rf dist/stage
printf 'created %s\n' "$archive"
