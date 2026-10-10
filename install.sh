#!/bin/zsh
# Installs ABC+: builds + registers the input method and starts the local model server.
#   ./install.sh                 default model
#   ./install.sh light|quality   smaller / bigger model (see scripts/server.sh)
set -euo pipefail
ROOT="${0:A:h}"
DEST="$HOME/Library/Input Methods/ABCPlus.app"
SUPPORT="$HOME/Library/Application Support/ABCPlus"

command -v llama-server >/dev/null || brew install llama.cpp

"$ROOT/scripts/build.sh"
pkill -x ABCPlus 2>/dev/null || true      # the system relaunches it on next use
mkdir -p "${DEST:h}" "$SUPPORT"
ditto "$ROOT/build/ABCPlus.app" "$DEST"     # overwrites the previous build in place
"$DEST/Contents/MacOS/ABCPlus" --register

[[ -f "$SUPPORT/config.json" ]] || cp "$ROOT/config.default.json" "$SUPPORT/config.json"
"$ROOT/scripts/server.sh" use "${1:-default}"

echo
echo "Installed. Switch to 'ABC+' in the input menu (or Ctrl+Space / Globe key)."
echo "If it is not listed: System Settings > Keyboard > Input Sources > Edit > + > English > ABC+."
