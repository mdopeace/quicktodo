#!/bin/bash
# Renders docs/screenshots/*.png from the real TodoView via AppKit.
# No screen-recording permission needed: it renders off-screen, so the result
# is identical on every machine and can be regenerated whenever the UI changes.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="docs/screenshots"
CORE=".build/out/Products/Debug"
BIN="$(mktemp -d)/shots"
trap 'rm -rf "$(dirname "$BIN")"' EXIT

# QuickTodoCore ships as a real module (TodoView imports it), so link its
# object file rather than recompiling the sources into the driver.
swift build
swiftc -parse-as-library -O -o "$BIN" \
  -I "$CORE" \
  $(ls Sources/QuickTodo/*.swift | grep -v '/main\.swift$') \
  scripts/screenshots-main.swift \
  "$CORE/QuickTodoCore.o"

mkdir -p "$OUT"
"$BIN" "$OUT"
echo "wrote $OUT/*.png"
