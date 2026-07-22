#!/usr/bin/env bash
#
# Relaunch Nib in a fresh first-run state so the full onboarding replays:
#   • resets the onboarding-completed flag (state.json)
#   • clears the saved model path (the model file itself is untouched)
#   • restarts the app against the Vite dev server (starting Vite if needed)
#
# Usage:  ./scripts/fresh-onboarding.sh

set -uo pipefail
cd "$(dirname "$0")/.."

printf '{\n  "onboardingCompleted" : false,\n  "completedAt" : null\n}\n' \
  > "$HOME/Library/Application Support/Nib/state.json"
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

# Stable signature so the Accessibility grant survives rebuilds (see dev.sh).
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application|Apple Development/{print $2; exit}')"
[[ -n "$SIGN_ID" ]] && codesign --force -s "$SIGN_ID" .build/debug/loco 2>/dev/null

LOCO_WEB_URL="http://localhost:5173" nohup ./.build/debug/loco > /tmp/loco-run.log 2>&1 &
echo "✅ Nib relaunched — onboarding will open centered."
