#!/bin/zsh
# Runs scripts/logic_test.swift against the real sources (no GUI, no model server needed).
# swiftc only accepts top-level code in a file named main.swift, hence the temp copy.
set -euo pipefail
ROOT="${0:A:h:h}"
TMP="$(mktemp -d)"
cp "$ROOT/scripts/logic_test.swift" "$TMP/main.swift"
swiftc -O -swift-version 5 "$TMP/main.swift" \
  "$ROOT"/Sources/{Suggester,TextLogic,Memory,Formatting,Config}.swift \
  -framework AppKit -o "$TMP/logic_test"
"$TMP/logic_test"
