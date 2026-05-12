#!/usr/bin/env bash
#
# drop_v5_zip.sh — one-command landing for a fresh PixelLab v5 zip.
#
# Wraps the per-zip cadence described in `docs/release/v5.0.x-cadence.md`:
#   1. Normalize raw PixelLab export → v3.0 schema
#   2. Drop into the bundle directory
#   3. Tell the operator what line to add to `expectedV5Coverage`
#   4. Run the focused asset-coverage test to confirm everything wires up
#
# Does NOT commit or push — operator reviews the diff first. This script
# only mutates files; the git workflow is `git add … && git commit -m …`
# after running.
#
# Usage:
#   Scripts/drop_v5_zip.sh <raw-pixellab-export.zip> <species-stage>
#
# Examples:
#   Scripts/drop_v5_zip.sh ~/Downloads/raw.zip dog-shiba-adult
#   Scripts/drop_v5_zip.sh ./fox-elder-raw.zip fox-elder
#
# The <species-stage> argument is the bundled filename WITHOUT the `.zip`
# suffix — matches the format already in `expectedV5Coverage`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PETS_DIR="$REPO_ROOT/PeerDrop/Resources/Pets"
WHITELIST_FILE="$REPO_ROOT/PeerDropTests/Pet/MainBundleAssetCoverageTests.swift"
NORMALIZE_SCRIPT="$REPO_ROOT/Scripts/normalize-pixellab-zip.sh"

# ANSI helpers (no-op when output isn't a TTY).
if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'
    RED=$'\e[31m'; CYAN=$'\e[36m'; RESET=$'\e[0m'
else
    BOLD=; DIM=; GREEN=; YELLOW=; RED=; CYAN=; RESET=
fi

die() {
    echo "${RED}ERROR:${RESET} $*" >&2
    exit 1
}

step() {
    echo "${BOLD}${CYAN}▸${RESET} ${BOLD}$*${RESET}"
}

# ─── Args ───────────────────────────────────────────────────────────────

[[ $# -eq 2 ]] || die "Usage: $0 <raw-pixellab-export.zip> <species-stage>
Example:
    $0 ~/Downloads/raw.zip dog-shiba-adult"

RAW_ZIP="$1"
SPECIES_STAGE="$2"

# Validate the cheap thing first — bad species-stage format is a typo we
# can flag without touching the filesystem. (Operator commonly passes a
# trailing `.zip` or an absolute bundle path.)
if [[ ! "$SPECIES_STAGE" =~ ^[a-z][a-z0-9-]+$ ]]; then
    die "species-stage must be lowercase hyphenated (e.g. 'dog-shiba-adult'). Got: $SPECIES_STAGE"
fi

[[ -f "$RAW_ZIP" ]]              || die "Raw zip not found: $RAW_ZIP"
[[ -d "$PETS_DIR" ]]              || die "Pets dir not found: $PETS_DIR"
[[ -f "$WHITELIST_FILE" ]]        || die "Whitelist file not found: $WHITELIST_FILE"
[[ -x "$NORMALIZE_SCRIPT" ]]      || die "Normalize script not executable: $NORMALIZE_SCRIPT"

OUT_ZIP="$PETS_DIR/${SPECIES_STAGE}.zip"

# ─── Step 1: Normalize ──────────────────────────────────────────────────

step "1/4 Normalize $RAW_ZIP → $SPECIES_STAGE.zip"
TMP_ZIP="$(mktemp -t "drop_v5_${SPECIES_STAGE}.XXXXXX").zip"
trap 'rm -f "$TMP_ZIP"' EXIT

"$NORMALIZE_SCRIPT" "$RAW_ZIP" "$TMP_ZIP"
echo "   ${DIM}Normalized output: $TMP_ZIP${RESET}"

# ─── Step 2: Drop into bundle ───────────────────────────────────────────

step "2/4 Drop into $PETS_DIR/"
if [[ -e "$OUT_ZIP" ]]; then
    OVERWRITE="(overwriting existing — diff: $(stat -f%z "$OUT_ZIP") → $(stat -f%z "$TMP_ZIP") bytes)"
    echo "   ${YELLOW}$OVERWRITE${RESET}"
fi
mv "$TMP_ZIP" "$OUT_ZIP"
echo "   ${DIM}Bundled at: $OUT_ZIP${RESET}"
trap - EXIT  # successfully moved; nothing to clean up

# ─── Step 3: Whitelist guidance ─────────────────────────────────────────

step "3/4 Whitelist entry"
if grep -q "\"$SPECIES_STAGE\"" "$WHITELIST_FILE"; then
    echo "   ${GREEN}✓${RESET} '$SPECIES_STAGE' already in expectedV5Coverage"
else
    echo "   ${YELLOW}!${RESET} Add this line to ${BOLD}expectedV5Coverage${RESET} in $WHITELIST_FILE:"
    echo
    echo "        ${GREEN}\"$SPECIES_STAGE\",${RESET}"
    echo
    echo "   Then re-run this script (idempotent) to verify the test passes."
fi

# ─── Step 4: Focused test ───────────────────────────────────────────────

step "4/4 Run asset coverage test"
echo "   ${DIM}xcodebuild test -only-testing:PeerDropTests/Pet/MainBundleAssetCoverageTests${RESET}"
TEST_LOG="$(mktemp -t "drop_v5_test_${SPECIES_STAGE}.XXXXXX").log"
if xcodebuild test \
        -scheme PeerDrop \
        -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
        -only-testing:PeerDropTests/Pet/MainBundleAssetCoverageTests \
        > "$TEST_LOG" 2>&1
then
    echo "   ${GREEN}✓${RESET} MainBundleAssetCoverageTests passed"
    echo "   ${DIM}(log: $TEST_LOG)${RESET}"
else
    echo
    echo "${RED}✗ Test failed.${RESET} Last 30 lines of output:"
    echo
    tail -30 "$TEST_LOG"
    echo
    echo "${DIM}Full log: $TEST_LOG${RESET}"
    exit 1
fi

# ─── Done ───────────────────────────────────────────────────────────────

cat <<EOF

${BOLD}${GREEN}✓ All checks passed.${RESET} Next step (you choose to run):

    ${DIM}git add PeerDrop/Resources/Pets/${SPECIES_STAGE}.zip \\
        PeerDropTests/Pet/MainBundleAssetCoverageTests.swift${RESET}

    ${DIM}git commit -m "asset(v5): ${SPECIES_STAGE} — <details>"${RESET}

    ${DIM}git push origin main${RESET}

The asset-coverage-badge workflow will update the README badge automatically.
EOF
