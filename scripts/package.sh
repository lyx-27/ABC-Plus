#!/bin/zsh
# Builds the release bundle: dist/ABC-Plus-<version>-macos-arm64.zip
# The bundle holds the prebuilt app plus the installer, so users need no compiler.
set -euo pipefail
ROOT="${0:A:h:h}"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist")"
NAME="ABC-Plus-$VERSION-macos-arm64"
OUT="$ROOT/dist"

"$ROOT/scripts/build.sh"

STAGE="$(mktemp -d)/$NAME"          # fresh temp dir each time, nothing to clean up by hand
mkdir -p "$STAGE/build" "$STAGE/scripts" "$OUT"
ditto "$ROOT/build/ABCPlus.app" "$STAGE/build/ABCPlus.app"
cp "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/config.default.json" "$ROOT/LICENSE" "$STAGE/"
cp "$ROOT/Install ABC+.command" "$ROOT/Uninstall ABC+.command" "$STAGE/"
cp "$ROOT/scripts/server.sh" "$STAGE/scripts/"
cat > "$STAGE/READ ME FIRST.txt" <<EOF
ABC+ $VERSION

Install:  double-click "Install ABC+.command".
Remove:   double-click "Uninstall ABC+.command".

If macOS says it cannot verify the file: open System Settings > Privacy & Security,
scroll down and click "Open Anyway" next to the message, then double-click it again.
The app is not notarized by Apple. The source is at https://github.com/lyx-27/ABC-Plus

Needs an Apple Silicon Mac and macOS 14 or later. The installer sets up Homebrew and
llama.cpp if they are missing (it asks first) and downloads the language model once.
EOF

ZIP="$OUT/$NAME.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP"
( cd "$OUT" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256" )
echo "built: $ZIP"
cat "$ZIP.sha256"
