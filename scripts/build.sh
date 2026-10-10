#!/bin/zsh
# Builds build/ABCPlus.app (ad-hoc signed, Apple Silicon).
set -euo pipefail
ROOT="${0:A:h:h}"
APP="$ROOT/build/ABCPlus.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"   # files below are overwritten in place

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -framework AppKit -framework InputMethodKit -framework Carbon \
  "$ROOT"/Sources/*.swift -o "$APP/Contents/MacOS/ABCPlus"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
swift "$ROOT/scripts/make_icon.swift" "$APP/Contents/Resources/icon.tiff"
codesign --force --sign - "$APP"
echo "built: $APP"
