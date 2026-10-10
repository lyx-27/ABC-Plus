#!/bin/zsh
# Installs ABC+: registers the input method and starts the local model server.
#   ./install.sh                 default model
#   ./install.sh light|quality   smaller / bigger model (see scripts/server.sh)
#   ./install.sh --check         only check the prerequisites, change nothing
# Works from a source checkout (builds the app first) and from the downloaded release
# bundle (uses the prebuilt build/ABCPlus.app, no compiler needed).
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="${0:A:h}"
DEST="$HOME/Library/Input Methods/ABCPlus.app"
SUPPORT="$HOME/Library/Application Support/ABCPlus"
PRESET="default"
CHECK=0

for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    light|default|quality) PRESET="$arg" ;;
    *) echo "usage: ./install.sh [light|default|quality] [--check]" >&2; exit 1 ;;
  esac
done

fail() { echo "x $*" >&2; exit 1; }
ok()   { echo "ok  $*"; }

# 1. This Mac
[[ "$(uname -m)" == "arm64" ]] || fail "ABC+ needs an Apple Silicon Mac."
(( $(sw_vers -productVersion | cut -d. -f1) >= 14 )) || fail "ABC+ needs macOS 14 or later."
ok "Apple Silicon, macOS $(sw_vers -productVersion)"

# 2. The app: build it from source, or use the one in the release bundle
if [[ -d "$ROOT/Sources" ]]; then
  xcrun --find swiftc >/dev/null 2>&1 || fail "Swift compiler not found. Run: xcode-select --install"
  ok "building from source"
else
  [[ -d "$ROOT/build/ABCPlus.app" ]] || fail "build/ABCPlus.app is missing. Download the release again."
  ok "using the prebuilt app"
fi

# 3. llama.cpp (the local model server)
if command -v llama-server >/dev/null; then
  ok "llama.cpp found"
else
  if ! command -v brew >/dev/null; then
    echo "Homebrew is needed to install llama.cpp, and it is not installed."
    if [[ $CHECK -eq 1 ]]; then fail "Homebrew missing (a real install would offer to install it)."; fi
    [[ -t 0 ]] || fail "Install Homebrew first: https://brew.sh"
    read -q "?Install Homebrew now, using the official script from brew.sh? [y/N] " || { echo; fail "Install Homebrew first: https://brew.sh"; }
    echo
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
  [[ $CHECK -eq 1 ]] && { ok "Homebrew found; a real install would run: brew install llama.cpp"; } || brew install llama.cpp
fi

if [[ $CHECK -eq 1 ]]; then
  echo "All checks passed. Nothing was changed."
  exit 0
fi

# 4. Install
[[ -d "$ROOT/Sources" ]] && "$ROOT/scripts/build.sh"
pkill -x ABCPlus 2>/dev/null || true      # the system relaunches it on next use
mkdir -p "${DEST:h}" "$SUPPORT"
ditto "$ROOT/build/ABCPlus.app" "$DEST"     # overwrites the previous build in place
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true   # downloaded copies carry this flag
"$DEST/Contents/MacOS/ABCPlus" --register
[[ -f "$SUPPORT/config.json" ]] || cp "$ROOT/config.default.json" "$SUPPORT/config.json"
"$ROOT/scripts/server.sh" use "$PRESET"
echo
echo "Installed. Switch to 'ABC+' in the input menu (or Ctrl+Space / Globe key)."
echo "If it is not listed: System Settings > Keyboard > Input Sources > Edit > + > English > ABC+."
