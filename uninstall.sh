#!/bin/zsh
# Removes the ABC+ input method and its model server.
#   ./uninstall.sh           keeps downloaded models, settings and learned words
#   ./uninstall.sh --purge   also deletes ~/Library/Application Support/ABCPlus and the logs
set -euo pipefail
ROOT="${0:A:h}"
DEST="$HOME/Library/Input Methods/ABCPlus.app"

if [[ -x "$DEST/Contents/MacOS/ABCPlus" ]]; then "$DEST/Contents/MacOS/ABCPlus" --disable || true; fi
pkill -x ABCPlus 2>/dev/null || true
rm -rf "$DEST"
"$ROOT/scripts/server.sh" uninstall || true

if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$HOME/Library/Application Support/ABCPlus" "$HOME/Library/Logs/ABCPlus"
fi
echo "ABC+ removed."
