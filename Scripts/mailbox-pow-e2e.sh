#!/usr/bin/env bash
# Runs the current Swift MailboxClient and the legacy wire format against a real local Worker, once with
# the legacy format still accepted and once with POW_LEGACY=off. Not part of CI.
# Prerequisites: Node.js, npm dependencies, Wrangler, curl, SwiftPM.

set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" || exit 1
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/peer-drop-mailbox-pow-e2e.XXXXXX")" || exit 1
BASE_PORT="${MAILBOX_E2E_PORT:-8791}"
WRANGLER_PID=""

stop_worker() {
  if [[ -n "$WRANGLER_PID" ]]; then
    kill "$WRANGLER_PID" 2>/dev/null || true
    wait "$WRANGLER_PID" 2>/dev/null || true
    WRANGLER_PID=""
  fi
}
trap 'stop_worker; printf "Logs: %s\n" "$LOG_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_phase() {
  local name="$1" port="$2" legacy_var="$3" legacy_expect="$4" status
  (
    cd "$REPO_ROOT/cloudflare-worker" || exit 1
    exec npx wrangler dev --local --port "$port" --persist-to "$LOG_DIR/state-$name" \
      --var TOKEN_SECRET:local-dev-secret-0123456789 \
      --var API_KEY:local-dev-api-key \
      --var POW_DIFFICULTY:10 \
      ${legacy_var:+--var "$legacy_var"}
  ) >"$LOG_DIR/wrangler-$name.log" 2>&1 &
  WRANGLER_PID=$!

  local ready=0 attempt
  for ((attempt = 0; attempt < 60; attempt++)); do
    if curl --silent --fail --max-time 1 "http://localhost:$port/v2/config/crypto-policy" >/dev/null 2>&1; then ready=1; break; fi
    kill -0 "$WRANGLER_PID" 2>/dev/null || break
    sleep 1
  done
  if [[ "$ready" -ne 1 ]]; then printf 'Local Wrangler did not become ready (%s).\n' "$name" >&2; return 1; fi

  (
    cd "$REPO_ROOT/PeerDropKit" || exit 1
    MAILBOX_E2E_URL="http://localhost:$port" MAILBOX_E2E_LEGACY="$legacy_expect" swift test --filter MailboxPoWE2ETests
  ) >"$LOG_DIR/swift-$name.log" 2>&1
  status=$?
  printf 'phase %-14s exit %s\n' "$name" "$status"
  stop_worker
  return "$status"
}

run_phase legacy-accepted "$BASE_PORT" "" accepted || exit 1
run_phase legacy-off "$((BASE_PORT + 1))" "POW_LEGACY:off" rejected || exit 1
printf 'Mailbox PoW E2E passed.\n'
