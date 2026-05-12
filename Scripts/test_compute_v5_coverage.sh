#!/usr/bin/env bash
#
# test_compute_v5_coverage.sh — fixture-driven tests for compute_v5_coverage.sh.
#
# Validates the awk parser against the layouts we want to support
# (multi-line set body, single-line set body, mixed) plus the failure
# modes that could matter (empty whitelist, malformed file, multiple
# unrelated quoted strings elsewhere in the file).
#
# Drives the production script via env-var overrides so we don't have
# to duplicate parsing logic in the test harness.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPUTE="$REPO_ROOT/Scripts/compute_v5_coverage.sh"

PASS=0
FAIL=0

# ─── helpers ────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    GREEN=$'\e[32m'; RED=$'\e[31m'; DIM=$'\e[2m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
    GREEN=; RED=; DIM=; BOLD=; RESET=
fi

run_case() {
    local name="$1" expected_covered="$2" expected_total="$3"
    local swift_fixture="$4" pets_fixture="$5"
    local out covered total

    out=$(COVERAGE_FILE_OVERRIDE="$swift_fixture" \
          PETS_DIR_OVERRIDE="$pets_fixture" \
          "$COMPUTE" --human)

    covered=$(awk '{print $4}' <<<"$out")
    total=$(awk '{print $6}' <<<"$out")

    if [[ "$covered" == "$expected_covered" && "$total" == "$expected_total" ]]; then
        echo "${GREEN}✓${RESET} $name (covered=$covered, total=$total)"
        PASS=$((PASS + 1))
    else
        echo "${RED}✗${RESET} $name"
        echo "    expected covered=$expected_covered, total=$expected_total"
        echo "    got      covered=$covered, total=$total"
        echo "    full output: ${DIM}$out${RESET}"
        FAIL=$((FAIL + 1))
    fi
}

# Pets-dir fixtures: simple temp dirs with N empty `.zip` files for `find` to count.
make_pets_dir() {
    local count="$1"
    local dir
    dir=$(mktemp -d -t "compute_v5_cov_pets.XXXXXX")
    for ((i = 0; i < count; i++)); do
        touch "$dir/fake-$i.zip"
    done
    echo "$dir"
}

# Swift fixtures live in a per-test scratch file written via heredoc.
make_swift_fixture() {
    local body="$1"
    local f
    f=$(mktemp -t "compute_v5_cov_swift.XXXXXX")
    printf '%s' "$body" > "$f"
    echo "$f"
}

# Track temp dirs for trap cleanup.
TRACK_DIRS=()
track() { TRACK_DIRS+=("$1"); echo "$1"; }
cleanup() { rm -rf "${TRACK_DIRS[@]:-}"; }
trap cleanup EXIT

# ─── cases ──────────────────────────────────────────────────────────────

echo "${BOLD}compute_v5_coverage.sh fixture tests${RESET}"
echo

# Case 1: canonical multi-line set body, single entry.
SWIFT_1=$(track $(make_swift_fixture '
private static let expectedV5Coverage: Set<String> = [
    "cat-tabby-adult",  // commit 54f0f69
]
'))
PETS_10=$(track $(make_pets_dir 10))
run_case "1 entry, 10 zips" 1 10 "$SWIFT_1" "$PETS_10"

# Case 2: multi-line set body with three entries + a comment.
SWIFT_2=$(track $(make_swift_fixture '
private static let expectedV5Coverage: Set<String> = [
    "cat-tabby-adult",
    "dog-shiba-adult",
    "fox-elder",
    // Trailing comment that mentions "fake-id" should NOT count
]
'))
run_case "3 entries with comment" 3 10 "$SWIFT_2" "$PETS_10"

# Case 3: empty set body.
SWIFT_3=$(track $(make_swift_fixture '
private static let expectedV5Coverage: Set<String> = [
]
'))
run_case "empty whitelist" 0 10 "$SWIFT_3" "$PETS_10"

# Case 4: single-line set body, two entries.
SWIFT_4=$(track $(make_swift_fixture '
private static let expectedV5Coverage: Set<String> = ["foo-bar", "baz-qux"]
'))
run_case "single-line set body, 2 entries" 2 10 "$SWIFT_4" "$PETS_10"

# Case 5: empty single-line set body.
SWIFT_5=$(track $(make_swift_fixture '
private static let expectedV5Coverage: Set<String> = []
'))
run_case "single-line empty" 0 10 "$SWIFT_5" "$PETS_10"

# Case 6: file contains unrelated quoted IDs that look like zip names
# OUTSIDE the expectedV5Coverage block. Must not be counted.
SWIFT_6=$(track $(make_swift_fixture '
let unrelatedFixture: [String] = ["fake-decoy-one", "fake-decoy-two"]
private static let expectedV5Coverage: Set<String> = [
    "cat-tabby-adult",
]
let moreDecoy: [String] = ["fake-decoy-three"]
'))
run_case "ignores decoy quoted IDs outside set" 1 10 "$SWIFT_6" "$PETS_10"

# Case 7: huge bundle (many zips), small whitelist — exercises the percent
# computation tier (1/324 = 0%).
SWIFT_7=$(track $(make_swift_fixture '
private static let expectedV5Coverage: Set<String> = [
    "cat-tabby-adult",
]
'))
PETS_324=$(track $(make_pets_dir 324))
run_case "1/324 → red tier" 1 324 "$SWIFT_7" "$PETS_324"

# Case 8: many entries, exercises color tier change.
SWIFT_8_BODY="private static let expectedV5Coverage: Set<String> = ["$'\n'
for i in $(seq 1 50); do SWIFT_8_BODY+="    \"sp-${i}-adult\","$'\n'; done
SWIFT_8_BODY+="]"
SWIFT_8=$(track $(make_swift_fixture "$SWIFT_8_BODY"))
run_case "50/100 → green tier" 50 100 "$SWIFT_8" "$(track $(make_pets_dir 100))"

# ─── summary ────────────────────────────────────────────────────────────

echo
echo "${BOLD}$PASS passed, $FAIL failed${RESET}"
[[ $FAIL -eq 0 ]] || exit 1
