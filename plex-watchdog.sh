#!/usr/bin/env bash
# Plex Media Server watchdog.
# Checks port 32400; if nothing is listening, relaunches the app.
# Triggered periodically by ~/Library/LaunchAgents/com.plex.watchdog.plist.

set -euo pipefail

PORT=32400
APP="Plex Media Server"

if /usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  exit 0
fi

echo "[$(date -Iseconds)] Plex not listening on :$PORT — relaunching"
/usr/bin/open -a "$APP"
