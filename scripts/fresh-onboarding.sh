#!/usr/bin/env bash
#
# Relaunch Notavo in a fresh first-run state so the full onboarding replays:
#   • resets the onboarding-completed flag (state.json)
#   • clears the saved model path (the model file itself is untouched)
#   • restarts the app against the Vite dev server (starting Vite if needed)
#
# Usage:  ./scripts/fresh-onboarding.sh

set -uo pipefail
cd "$(dirname "$0")/.."

printf '{\n  "onboardingCompleted" : false,\n  "completedAt" : null\n}\n' \
  > "$HOME/Library/Application Support/Notavo/state.json"
defaults delete loco modelPath 2>/dev/null

pkill -f "debug/loco" 2>/dev/null
sleep 1

# Vite serves the card UI; start it if it isn't already running.
if ! lsof -ti:5173 >/dev/null 2>&1; then
  (cd web && nohup npm run dev > /tmp/vite-run.log 2>&1 &)
  sleep 3
fi

if [[ ! -x .build/debug/loco ]]; then
  echo "🔨 no debug binary — building…"
  swift build || exit 1
fi

LOCO_WEB_URL="http://localhost:5173" nohup ./.build/debug/loco > /tmp/loco-run.log 2>&1 &
echo "✅ Notavo relaunched — onboarding will open centered."
