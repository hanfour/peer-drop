#!/usr/bin/env bash
# Polls App Store Connect every hour for state changes on the in-flight
# version + recent builds + live version. Alerts via macOS Notification
# Center + iMessage (configured in fastlane/Fastfile :monitor lane).
#
# Run in foreground:
#   ./scripts/asc-monitor-daemon.sh
#
# Run in background (survives shell exit):
#   nohup ./scripts/asc-monitor-daemon.sh >> fastlane/monitor.log 2>&1 &
#
# Stop background:
#   pkill -f asc-monitor-daemon
#
# Override interval (seconds):
#   INTERVAL_SEC=900 ./scripts/asc-monitor-daemon.sh   # 15 min
#
# State file:  .asc-monitor-state.json (gitignored, auto-created)
# Log file:    fastlane/monitor.log
set -euo pipefail
cd "$(dirname "$0")/.."

INTERVAL_SEC=${INTERVAL_SEC:-3600}

echo "[asc-monitor] Starting; polling every ${INTERVAL_SEC}s. Ctrl+C to stop."

while true; do
  fastlane monitor || echo "[asc-monitor] fastlane monitor failed; will retry next cycle."
  sleep "${INTERVAL_SEC}"
done
