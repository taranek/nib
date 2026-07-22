#!/usr/bin/env bash
#
# Single-command dev loop for loco:
#   • Vite dev server for the web UI (true hot-module reload — edit web/src and
#     the card/settings update instantly, no restart).
#   • Swift watch + rebuild + relaunch on save (the practical equivalent of hot
#     reload for native code).
#   • llama-server is left warm across Swift relaunches — loco re-attaches to it,
#     so the model isn't reloaded each time.
#
# Usage:  ./dev.sh
# Stop:   Ctrl-C  (tears down vite, loco, and llama-server)

set -uo pipefail
cd "$(dirname "$0")"

export LOCO_WEB_URL="http://localhost:5173"   # point loco at the HMR dev server

VITE_PID=""
LOCO_PID=""

cleanup() {
  echo ""
  echo "⏹  shutting down…"
  [[ -n "$LOCO_PID" ]] && kill "$LOCO_PID" 2>/dev/null
  [[ -n "$VITE_PID" ]] && kill "$VITE_PID" 2>/dev/null
  pkill -f "llama-server.*18080" 2>/dev/null
  exit 0
}
trap cleanup INT TERM EXIT

# 1) Web UI with hot-module reload.
( cd web && npm run dev ) &
VITE_PID=$!

# Fingerprint of all Swift sources (mtimes) to detect saves without a watcher dep.
stamp() { find Sources -name '*.swift' -exec stat -f '%m' {} + 2>/dev/null | sort | md5; }

# Sign debug builds with a stable identity so the Accessibility (TCC) grant
# persists across rebuilds — ad-hoc signatures change identity every build,
# silently revoking the grant.
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application|Apple Development/{print $2; exit}')"

build_and_run() {
  echo "🔨 building…"
  if swift build; then
    [[ -n "$SIGN_ID" ]] && codesign --force -s "$SIGN_ID" .build/debug/loco 2>/dev/null
    [[ -n "$LOCO_PID" ]] && kill "$LOCO_PID" 2>/dev/null
    ./.build/debug/loco &
    LOCO_PID=$!
    echo "▶️  loco running (pid $LOCO_PID)"
  else
    echo "❌ build failed — keeping the previous instance"
  fi
}

build_and_run
LAST=$(stamp)

# 2) Poll for Swift changes; rebuild + relaunch on save.
while true; do
  sleep 1
  NOW=$(stamp)
  if [[ "$NOW" != "$LAST" ]]; then
    LAST="$NOW"
    echo "♻️  swift change detected"
    build_and_run
  fi
done
