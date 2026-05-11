#!/usr/bin/env bash
#
# Compute v5 asset-coverage stats for the README badge.
#
# - `covered`  = entries in `expectedV5Coverage` set inside MainBundleAssetCoverageTests.swift
# - `total`    = .zip files under PeerDrop/Resources/Pets/ (the v4 bundle minus anything
#                already removed; ground truth for "what's shipping in the app right now")
# - `percent`  = covered / total × 100, integer floor
# - `color`    = shields.io tier: red <10, orange <33, yellow <66, yellowgreen <90, green ≥90
#
# Output (single line, shields.io endpoint schema):
#   {"schemaVersion":1,"label":"v5 coverage","message":"1/324 (0%)","color":"red"}
#
# Usage:
#   Scripts/compute_v5_coverage.sh                # prints JSON to stdout
#   Scripts/compute_v5_coverage.sh > out.json     # write to file
#   Scripts/compute_v5_coverage.sh --human        # human-friendly summary instead of JSON
#
# Invoked locally for verification + by .github/workflows/asset-coverage-badge.yml.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COVERAGE_FILE="$REPO_ROOT/PeerDropTests/Pet/MainBundleAssetCoverageTests.swift"
PETS_DIR="$REPO_ROOT/PeerDrop/Resources/Pets"

if [[ ! -f "$COVERAGE_FILE" ]]; then
    echo "ERROR: not found: $COVERAGE_FILE" >&2
    exit 1
fi
if [[ ! -d "$PETS_DIR" ]]; then
    echo "ERROR: not found: $PETS_DIR" >&2
    exit 1
fi

# Extract the expectedV5Coverage block. We look for the literal set body — entries
# are double-quoted, hyphenated, lowercase like "cat-tabby-adult".
COVERED=$(awk '
    /expectedV5Coverage: Set<String> = \[/  { in_set = 1; next }
    in_set && /^[[:space:]]*\]/              { in_set = 0 }
    in_set && /"[a-z][a-z0-9-]+"/            { count++ }
    END                                      { print count + 0 }
' "$COVERAGE_FILE")

TOTAL=$(find "$PETS_DIR" -maxdepth 1 -name '*.zip' -type f | wc -l | tr -d ' ')

if [[ "$TOTAL" -eq 0 ]]; then
    PERCENT=0
else
    PERCENT=$(( COVERED * 100 / TOTAL ))
fi

# shields.io tier — keep stops conservative; this is a multi-month rollout meter.
if   [[ $PERCENT -ge 90 ]]; then COLOR="brightgreen"
elif [[ $PERCENT -ge 66 ]]; then COLOR="green"
elif [[ $PERCENT -ge 33 ]]; then COLOR="yellow"
elif [[ $PERCENT -ge 10 ]]; then COLOR="orange"
else                             COLOR="red"
fi

if [[ "${1:-}" == "--human" ]]; then
    echo "v5 schema coverage: $COVERED / $TOTAL ($PERCENT%) [$COLOR]"
    exit 0
fi

printf '{"schemaVersion":1,"label":"v5 coverage","message":"%d/%d (%d%%)","color":"%s"}\n' \
    "$COVERED" "$TOTAL" "$PERCENT" "$COLOR"
