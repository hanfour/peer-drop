#!/usr/bin/env bash
# Prerequisites: Node.js, npm dependencies, Wrangler, curl, and SwiftPM.
# This starts a local Worker and runs a manual end-to-end check; it is not part of CI.

set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" || exit 1
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/peer-drop-group-e2e.XXXXXX")" || exit 1
PORT="${GROUP_E2E_PORT:-8787}"
WRANGLER_PID=""

cleanup() {
  local status=$?
  local file redacted
  trap - EXIT INT TERM
  if [[ -n "$WRANGLER_PID" ]]; then
    kill "$WRANGLER_PID" 2>/dev/null || true
    wait "$WRANGLER_PID" 2>/dev/null || true
  fi
  for file in "$LOG_DIR"/*.log; do
    [[ -f "$file" ]] || continue
    redacted="$file.redacted"
    sed \
      -e 's/local-dev-secret-0123456789/[redacted]/g' \
      -e 's/local-dev-api-key/[redacted]/g' \
      -e 's/local-dev-mac-key/[redacted]/g' \
      -e 's/local-analytics-key/[redacted]/g' \
      "$file" >"$redacted" && mv "$redacted" "$file"
  done
  printf 'Logs: %s\n' "$LOG_DIR"
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
  printf 'GROUP_E2E_PORT must be a number.\n' >&2
  exit 2
fi
PORT=$((10#$PORT))
if (( PORT < 1 || PORT > 65535 )); then
  printf 'GROUP_E2E_PORT must be between 1 and 65535.\n' >&2
  exit 2
fi

(cd "$REPO_ROOT/cloudflare-worker" && npx wrangler d1 migrations apply ACCOUNTS_DB --local --persist-to "$LOG_DIR/state") >"$LOG_DIR/d1-migrate-local.log" 2>&1
migration_status=$?
if [[ "$migration_status" -ne 0 ]]; then
  printf 'Local D1 migration failed (exit %s).\n' "$migration_status" >&2
  exit "$migration_status"
fi

(
  cd "$REPO_ROOT/cloudflare-worker" || exit 1
  exec npx wrangler dev --local --port "$PORT" --persist-to "$LOG_DIR/state" \
    --var APP_ATTEST_ALLOW_DEV:true \
    --var TOKEN_SECRET:local-dev-secret-0123456789 \
    --var API_KEY:local-dev-api-key \
    --var MAC_CLIENT_KEY:local-dev-mac-key \
    --var ANALYTICS_KEY:local-analytics-key
) >"$LOG_DIR/wrangler-dev.log" 2>&1 &
WRANGLER_PID=$!

ready=0
for ((attempt = 0; attempt < 60; attempt++)); do
  if curl --silent --show-error --fail --max-time 1 \
    "http://localhost:$PORT/v2/config/crypto-policy" \
    >/dev/null 2>>"$LOG_DIR/liveness.log"; then
    ready=1
    break
  fi
  if ! kill -0 "$WRANGLER_PID" 2>/dev/null; then
    break
  fi
  sleep 1
done

if [[ "$ready" -ne 1 ]]; then
  printf 'Local Wrangler did not become ready on port %s.\n' "$PORT" >&2
  exit 1
fi

(
  cd "$REPO_ROOT/PeerDropKit" || exit 1
  GROUP_E2E_BASE_URL="http://localhost:$PORT" swift test --filter GroupE2ETests
) >"$LOG_DIR/swift-test.log" 2>&1
test_status=$?
printf 'Group E2E test exit code: %s\n' "$test_status"
exit "$test_status"
