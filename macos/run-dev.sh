#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
osascript -e 'tell application id "dev.pijoo.menubar" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -TERM -f "^$SCRIPT_DIR/build/Pijoo.app/Contents/MacOS/Pijoo$" >/dev/null 2>&1 || true
PIJOO_APP_ONLY=1 PIJOO_DEVELOPMENT=1 PIJOO_SKIP_SELF_TESTS=1 PIJOO_SIGN_IDENTITY=- \
  "$SCRIPT_DIR/build-app.sh"
open -n "$SCRIPT_DIR/build/Pijoo.app"
