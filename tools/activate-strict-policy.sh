#!/usr/bin/env bash
#
# activate-strict-policy.sh — gate + sign + (optionally) deploy the strict
# crypto policy that flips C1 to spkExpirationBehavior=reject.
#
# This automates the post-soak activation sequence from
# docs/security/crypto-policy-format.md §"First-ship activation strategy"
# and docs/plans/2026-07-05-strict-policy-activation.md.
#
# It refuses to activate unless the production soak is BOTH healthy AND
# actually populated — the 2026-07-03 audit found the original soak read
# an empty bucket (no telemetry pipeline) and "looked clean". The
# --min-snapshots gate exists specifically so that mistake can't repeat:
# a near-empty soak is treated as "not enough data", never as "clean".
#
# Usage:
#   tools/activate-strict-policy.sh \
#       --prod-key /path/to/prod-signing-key.json \
#       --analytics-key <ANALYTICS_KEY> \
#       [--min-snapshots 500] \
#       [--range 7d] \
#       [--deploy]
#
#   Without --deploy it does everything EXCEPT the production
#   `wrangler secret put`, printing the exact command to run manually.
#
set -euo pipefail

WORKER_URL="${PEERDROP_WORKER_URL:-https://peerdrop-signal.hanfourhuang.workers.dev}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRICT_POLICY="$REPO_ROOT/cloudflare-worker/strict-policy.json"

PROD_KEY=""
ANALYTICS_KEY=""
MIN_SNAPSHOTS=500
RANGE="7d"
DEPLOY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prod-key)       PROD_KEY="$2"; shift 2 ;;
    --analytics-key)  ANALYTICS_KEY="$2"; shift 2 ;;
    --min-snapshots)  MIN_SNAPSHOTS="$2"; shift 2 ;;
    --range)          RANGE="$2"; shift 2 ;;
    --deploy)         DEPLOY=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

[[ -n "$PROD_KEY" ]]       || { echo "error: --prod-key is required (the OFFLINE production signing key)" >&2; exit 64; }
[[ -n "$ANALYTICS_KEY" ]]  || { echo "error: --analytics-key is required (to read the soak)" >&2; exit 64; }
[[ -f "$PROD_KEY" ]]       || { echo "error: prod key not found at $PROD_KEY" >&2; exit 65; }
[[ -f "$STRICT_POLICY" ]]  || { echo "error: strict policy template missing at $STRICT_POLICY" >&2; exit 65; }

echo "==> Reading soak stats ($RANGE) from $WORKER_URL"
STATS="$(curl -fsS "$WORKER_URL/debug/crypto-metrics/stats?range=$RANGE" -H "X-API-Key: $ANALYTICS_KEY")" \
  || { echo "error: could not fetch soak stats (check ANALYTICS_KEY / worker)" >&2; exit 70; }

SNAPSHOTS=$(echo "$STATS" | python3 -c "import sys,json;print(json.load(sys.stdin).get('snapshots',0))")
ISIG=$(echo "$STATS"      | python3 -c "import sys,json;print(json.load(sys.stdin).get('soak',{}).get('spkInvalidSignature',-1))")
OFAIL=$(echo "$STATS"     | python3 -c "import sys,json;print(json.load(sys.stdin).get('soak',{}).get('opkFailedInitiation',-1))")
PSIG=$(echo "$STATS"      | python3 -c "import sys,json;print(json.load(sys.stdin).get('soak',{}).get('policySignatureInvalid',-1))")

echo "    snapshots=$SNAPSHOTS  spkInvalidSignature=$ISIG  opkFailedInitiation=$OFAIL  policySignatureInvalid=$PSIG"

# --- Gate 1: the soak must actually contain data. ---------------------------
# This is the guard against the "empty bucket looked clean" trap.
if [[ "$SNAPSHOTS" -lt "$MIN_SNAPSHOTS" ]]; then
  echo "ABORT: only $SNAPSHOTS snapshots in the last $RANGE (need >= $MIN_SNAPSHOTS)." >&2
  echo "       The soak has not accumulated enough real device data yet — a" >&2
  echo "       near-empty soak reads 'clean' for the wrong reason. Wait until" >&2
  echo "       the metrics-uploading build has propagated, then retry." >&2
  exit 1
fi

# --- Gate 2: signature-invalid MUST be exactly zero (tampering/bug signal). --
if [[ "$PSIG" != "0" ]]; then
  echo "ABORT: policy.signature_invalid = $PSIG (must be 0). A non-zero value" >&2
  echo "       means clients rejected a policy signature — investigate before" >&2
  echo "       activating anything." >&2
  exit 1
fi

# --- Gate 3: the C1/C2 error counters must be ~0. ---------------------------
if [[ "$ISIG" != "0" || "$OFAIL" != "0" ]]; then
  echo "ABORT: soak-gate error counters are non-zero" >&2
  echo "       (spkInvalidSignature=$ISIG, opkFailedInitiation=$OFAIL)." >&2
  echo "       Real C1/C2 failures exist in production — do NOT flip to reject." >&2
  exit 1
fi

echo "==> Soak is healthy AND populated. Proceeding to sign the strict policy."

# --- Sign with fresh timestamps ---------------------------------------------
# Regenerate issuedAt=now, expiresAt=now+180d so the blob isn't stale.
SIGNED_INPUT="$(mktemp)"
SIGNED_OUTPUT="$REPO_ROOT/cloudflare-worker/strict-policy.signed.json"
trap 'rm -f "$SIGNED_INPUT"' EXIT

python3 - "$STRICT_POLICY" "$SIGNED_INPUT" <<'PY'
import sys, json, time
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
now = int(time.time())
d["issuedAt"] = now
d["expiresAt"] = now + 180 * 86400
json.dump(d, open(dst, "w"))
PY

echo "==> Signing $STRICT_POLICY with the production key"
swift "$REPO_ROOT/tools/sign-crypto-policy.swift" "$SIGNED_INPUT" "$PROD_KEY" > "$SIGNED_OUTPUT"
echo "    wrote $SIGNED_OUTPUT"
echo "    policy.spkExpirationBehavior = $(python3 -c "import json;print(json.load(open('$SIGNED_OUTPUT'))['policy']['spkExpirationBehavior'])")"

if [[ "$DEPLOY" -eq 1 ]]; then
  echo "==> Deploying to the worker (CRYPTO_POLICY_JSON secret)"
  ( cd "$REPO_ROOT/cloudflare-worker" && cat "$SIGNED_OUTPUT" | npx wrangler secret put CRYPTO_POLICY_JSON )
  echo "==> Verifying rollout"
  curl -fsS "$WORKER_URL/v2/config/crypto-policy" | python3 -c "import sys,json;d=json.load(sys.stdin);p=d.get('policy',d);print('LIVE spkExpirationBehavior =', p.get('spkExpirationBehavior'))"
  echo "Done. Strict C1 (reject) is now active. Devices pick it up within their 1h cache window."
else
  echo ""
  echo "DRY RUN — not deployed. To activate, run:"
  echo "  cd cloudflare-worker && cat strict-policy.signed.json | npx wrangler secret put CRYPTO_POLICY_JSON"
  echo "  # then verify: curl $WORKER_URL/v2/config/crypto-policy | jq .policy.spkExpirationBehavior"
  echo ""
  echo "Or re-run this script with --deploy."
fi
