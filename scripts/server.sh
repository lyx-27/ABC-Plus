#!/bin/zsh
# Local model server for ABC+: llama.cpp on 127.0.0.1 only, protected by an API key,
# started at login by launchd (independent of any terminal/IDE).
#   server.sh use [light|default|quality]   download (sha256-checked) + switch + restart
#   server.sh start | stop | status | uninstall
set -euo pipefail
SUPPORT="$HOME/Library/Application Support/ABCPlus"
MODELS="$SUPPORT/models"
LOGS="$HOME/Library/Logs/ABCPlus"
LABEL="io.github.lyx-27.abcplus.llama"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PORT=39281
MIRROR="${HF_ENDPOINT:-https://hf-mirror.com}"   # set HF_ENDPOINT=https://huggingface.co to skip the mirror

preset() {   # prints: REPO FILE
  case "$1" in
    light)   echo "mradermacher/Qwen3.5-0.8B-Base-i1-GGUF Qwen3.5-0.8B-Base.i1-Q6_K.gguf" ;;    # 0.63 GB
    default) echo "mradermacher/Qwen3.5-2B-Base-i1-GGUF Qwen3.5-2B-Base.i1-Q6_K.gguf" ;;      # 1.56 GB
    quality) echo "mradermacher/Qwen3.5-4B-Base-i1-GGUF Qwen3.5-4B-Base.i1-Q4_K_M.gguf" ;;   # 2.71 GB
    *) echo "unknown preset '$1' (light|default|quality)" >&2; exit 1 ;;
  esac
}

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

download() {   # REPO FILE
  local repo=$1 file=$2 dest="$MODELS/$2" want
  mkdir -p "$MODELS"
  want=$(curl -sf -m 30 "$MIRROR/api/models/$repo/tree/main" | python3 -c \
    "import sys,json; print([f['lfs']['oid'] for f in json.load(sys.stdin) if f['path']=='$file'][0])")
  if [[ -f "$dest" && "$(sha_of "$dest")" == "$want" ]]; then echo "model ok: $file"; return; fi
  echo "downloading $file from $MIRROR ..."
  curl -fL -C - --retry 3 -o "$dest.part" "$MIRROR/$repo/resolve/main/$file"
  [[ "$(sha_of "$dest.part")" == "$want" ]] || { echo "sha256 mismatch, keeping $dest.part" >&2; exit 1; }
  mv "$dest.part" "$dest"
}

write_plist() {   # MODEL_PATH
  local bin="$(brew --prefix)/bin/llama-server"
  [[ -x "$bin" ]] || { echo "llama-server not found: brew install llama.cpp" >&2; exit 1; }
  mkdir -p "$LOGS" "${PLIST:h}"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$bin</string>
    <string>-m</string><string>$1</string>
    <string>--host</string><string>127.0.0.1</string>
    <string>--port</string><string>$PORT</string>
    <string>--api-key-file</string><string>$SUPPORT/api_key</string>
    <string>-ngl</string><string>99</string>
    <string>-c</string><string>2048</string>
    <string>-np</string><string>1</string>
    <string>-cram</string><string>0</string>
    <string>--checkpoint-min-step</string><string>0</string>
    <string>--no-webui</string>
    <string>--no-slots</string>
    <string>-lv</string><string>2</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOGS/llama.log</string>
  <key>StandardErrorPath</key><string>$LOGS/llama.log</string>
</dict></plist>
EOF
}

start() {
  # bootout returns before launchd has finished removing a running service, and bootstrapping
  # right away fails with "Input/output error". Wait until it is really gone, then retry.
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  local i
  for i in {1..40}; do launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 || break; sleep 0.25; done
  for i in {1..5}; do launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null && return 0; sleep 1; done
  launchctl bootstrap "gui/$UID" "$PLIST"     # last attempt, lets the real error show
}

case "${1:-status}" in
  use)
    [[ -s "$SUPPORT/api_key" ]] || (umask 077; mkdir -p "$SUPPORT"; openssl rand -hex 24 > "$SUPPORT/api_key")
    read -r repo file <<< "$(preset "${2:-default}")"
    download "$repo" "$file"
    write_plist "$MODELS/$file"
    start
    echo "server running with $file (http://127.0.0.1:$PORT)" ;;
  start) start ;;
  stop) launchctl bootout "gui/$UID/$LABEL" ;;
  status)
    launchctl print "gui/$UID/$LABEL" 2>/dev/null | grep -E "^\s+(state|pid) =" || echo "not loaded"
    curl -s -m 3 --noproxy '*' "http://127.0.0.1:$PORT/health"; echo ;;
  uninstall) launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true; rm -f "$PLIST" ;;
  *) echo "usage: server.sh use [light|default|quality] | start | stop | status | uninstall" >&2; exit 1 ;;
esac
