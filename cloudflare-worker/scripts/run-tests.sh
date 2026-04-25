#!/usr/bin/env bash
# Run miniflare-based vitest suite for the Cloudflare Worker.
#
# Why this wrapper exists:
#   @cloudflare/vitest-pool-workers (workerd) currently mishandles module
#   resolution when the absolute path to node_modules contains spaces
#   (see: file:/Volumes/SATECHI%20DISK%20Media/... double-encoding bug).
#   This affects the local dev path on macOS when the repo lives on an
#   external volume with a space in its name. CI runs (no spaces in path)
#   are unaffected — `npx vitest run` in the cloudflare-worker dir is fine.
#
# What this does:
#   If $PWD contains spaces, create a shadow tree under /tmp with rsync,
#   install node_modules there (cached across runs via package-lock hash),
#   and exec vitest from that location. Otherwise, just run vitest in-place.

set -euo pipefail

WORKER_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "$WORKER_DIR" != *" "* ]]; then
  # No spaces in path — run directly.
  cd "$WORKER_DIR"
  exec npx vitest run "$@"
fi

# Shadow path needed.
HASH=$(shasum -a 1 "$WORKER_DIR/package-lock.json" | awk '{print $1}' | cut -c1-12)
SHADOW="/tmp/peerdrop-cf-$HASH"

mkdir -p "$SHADOW"
# rsync source files (skip node_modules / .wrangler — handled separately)
rsync -a --delete \
  --exclude=node_modules \
  --exclude=.wrangler \
  "$WORKER_DIR/" "$SHADOW/"

# Install node_modules in shadow if missing or out-of-date.
if [[ ! -d "$SHADOW/node_modules" ]]; then
  (cd "$SHADOW" && npm install --silent)
fi

cd "$SHADOW"
exec npx vitest run "$@"
