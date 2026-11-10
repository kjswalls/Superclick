#!/bin/sh
# Builds Superclick.app from the Swift package and signs it.
#
#   scripts/build-app.sh            # release build into build/Superclick.app
#   scripts/build-app.sh --open     # …and launch it
#
# Signing: set SIGN_IDENTITY to a certificate from `security find-identity -v -p codesigning`
# (an "Apple Development" one is fine) so macOS keeps the Accessibility permission across
# rebuilds. Without it the app is signed ad hoc, and each rebuild needs Superclick turned
# off and on again in System Settings → Privacy & Security → Accessibility.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Superclick.app"
CONFIG="${CONFIG:-release}"

cd "$ROOT/app"
swift build -c "$CONFIG" --product Superclick
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Superclick"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Superclick"
cp "$ROOT/app/Support/Info.plist" "$APP/Contents/Info.plist"

IDENTITY="${SIGN_IDENTITY:--}"

# The daemon, compiled into the app so it can run at login (Settings). Needs Bun;
# without it the app still works with `bun run start` from daemon/.
if command -v bun >/dev/null 2>&1; then
  ARCH="$(uname -m | sed s/x86_64/x64/)"
  (cd "$ROOT/daemon" && bun install --frozen-lockfile >/dev/null && \
    bun build "bin/darwin-$ARCH.ts" --compile --outfile "$APP/Contents/MacOS/superclick-daemon")
  mkdir -p "$APP/Contents/Library/LaunchAgents"
  cp "$ROOT/app/Support/dev.superclick.daemon.plist" "$APP/Contents/Library/LaunchAgents/"
  codesign --force --options runtime --timestamp=none --entitlements "$ROOT/app/Support/daemon.entitlements" \
    --sign "$IDENTITY" "$APP/Contents/MacOS/superclick-daemon"
else
  echo "Bun isn't installed, so the daemon isn't bundled. Install it from bun.sh, or run it by hand (README)."
fi

codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
echo "Built $APP (signed with ${SIGN_IDENTITY:-an ad hoc signature})"

if [ "${1:-}" = "--open" ]; then
  # Quit a running copy first so the new build takes the hotkey.
  pkill -x Superclick 2>/dev/null || true
  sleep 0.3
  open "$APP"
fi
