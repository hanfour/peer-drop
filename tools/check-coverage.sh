#!/usr/bin/env bash
# tools/check-coverage.sh
# Parses xccov JSON and fails if any crypto-layer file is below threshold.
#
# Usage:
#   xcodebuild test -scheme PeerDrop ... -enableCodeCoverage YES -resultBundlePath /tmp/peerdrop.xcresult
#   xcrun xccov view --report --json /tmp/peerdrop.xcresult > /tmp/cov.json
#   tools/check-coverage.sh /tmp/cov.json
#
# Exit code 0 if all targets meet their thresholds; non-zero otherwise.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <xccov-json-report>" >&2
  exit 64
fi

REPORT=$1

if [ ! -f "$REPORT" ]; then
  echo "❌ report file not found: $REPORT" >&2
  exit 65
fi

if ! command -v jq >/dev/null; then
  echo "❌ jq is required (brew install jq)" >&2
  exit 69
fi

# Files to enforce at 95% line coverage:
TARGETS_95=(
  "PreKeyStore.swift"
  "X3DH.swift"
  "DoubleRatchet.swift"
)

# Files to enforce at 100% line coverage (new code, no excuses):
TARGETS_100=(
  "SecurityPolicy.swift"
  "SecurityPolicyStore.swift"
)

fail=0

check_file() {
  local file=$1
  local threshold=$2
  # xccov JSON shape:
  #   { "targets": [ { "files": [ { "path": "...", "lineCoverage": 0.95 } ] } ] }
  local pct
  pct=$(jq -r --arg f "$file" \
    '[.targets[].files[] | select(.path | endswith($f)) | .lineCoverage] | first // empty' \
    "$REPORT")

  if [ -z "$pct" ]; then
    echo "⚠️  $file: not in report (skipped)"
    return 0
  fi

  local pct_int
  pct_int=$(awk -v p="$pct" 'BEGIN { printf "%d", p * 100 }')

  if [ "$pct_int" -lt "$threshold" ]; then
    echo "❌ $file: ${pct_int}% (< ${threshold}%)"
    fail=1
  else
    echo "✅ $file: ${pct_int}% (≥ ${threshold}%)"
  fi
}

echo "--- Crypto-layer coverage gate ---"
for f in "${TARGETS_95[@]}"; do check_file "$f" 95; done
for f in "${TARGETS_100[@]}"; do check_file "$f" 100; done

if [ $fail -ne 0 ]; then
  echo ""
  echo "❌ Coverage gate FAILED"
  exit 1
fi

echo ""
echo "✅ Coverage gate PASSED"
