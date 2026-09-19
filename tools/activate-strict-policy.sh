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
# --min-snapshots MUST be a positive integer. `-lt` is arithmetic, so an
# empty/0/non-numeric value would silently make the populate guard pass
# (as few as a handful of snapshots) — defeating the whole point of the
# script. Enforce a hard floor too so `--min-snapshots 1` can't disable it.
[[ "$MIN_SNAPSHOTS" =~ ^[0-9]+$ ]] || { echo "error: --min-snapshots must be a non-negative integer, got '$MIN_SNAPSHOTS'" >&2; exit 64; }
if [[ "$MIN_SNAPSHOTS" -lt 100 ]]; then
  echo "error: --min-snapshots=$MIN_SNAPSHOTS is below the hard floor of 100." >&2
  echo "       A tiny threshold reintroduces the empty-bucket trap this guards against." >&2
  exit 64
fi

# --- Guard: the signing key must be the swapped PRODUCTION key. --------------
# Derive the public half of --prod-key and require it to (a) NOT be the
# committed dev key (whose private key is public in this repo → signing with
# it is security theater), and (b) actually be a trust root the shipped apps
# accept (present in project.yml CryptoPolicyPublicKeys) — otherwise every
# client rejects the blob with policy.signature_invalid, strict never
# activates, and the failed attempt poisons the NEXT soak's gate 2.
PROD_PUB=$(swift -e '
import Foundation; import CryptoKit
let d = try! JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let priv = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: d["private_key_base64"]!)!)
print(priv.publicKey.rawRepresentation.base64EncodedString())
' "$PROD_KEY") || { echo "error: could not derive public key from --prod-key" >&2; exit 65; }

DEV_PUB=$(python3 -c "import json;print(json.load(open('$REPO_ROOT/cloudflare-worker/dev-signing-key.json'))['public_key_base64'])" 2>/dev/null || echo "")
if [[ -n "$DEV_PUB" && "$PROD_PUB" == "$DEV_PUB" ]]; then
  echo "ABORT: --prod-key is the COMMITTED DEV KEY (public: $PROD_PUB)." >&2
  echo "       Its private key is public in this repo — signing with it is" >&2
  echo "       security theater. Generate an offline production keypair first" >&2
  echo "       (docs/plans/2026-07-05-strict-policy-activation.md §A)." >&2
  exit 1
fi
if ! grep -q "$PROD_PUB" "$REPO_ROOT/project.yml"; then
  echo "ABORT: the --prod-key's public key ($PROD_PUB) is NOT in project.yml" >&2
  echo "       CryptoPolicyPublicKeys. The shipped apps would reject a blob" >&2
  echo "       signed with it (policy.signature_invalid) and strict would" >&2
  echo "       never activate. Swap the trust root and ship it first." >&2
  exit 1
fi

echo "==> Reading soak stats ($RANGE) from $WORKER_URL"
STATS="$(curl -fsS "$WORKER_URL/debug/crypto-metrics/stats?range=$RANGE" -H "X-API-Key: $ANALYTICS_KEY")" \
  || { echo "error: could not fetch soak stats (check ANALYTICS_KEY / worker)" >&2; exit 70; }

# Single parse of the whole blob (one process, one parse-failure surface).
# Emits four space-separated ints; missing fields become sentinels that fail
# the gates closed. A malformed body (e.g. a 401 error object) → non-"0"
# sentinels for the counters → abort.
read -r SNAPSHOTS ISIG OFAIL PSIG TRUNCATED <<EOF2
$(echo "$STATS" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    s = d.get('soak', {})
    print(int(d.get('snapshots', 0)),
          s.get('spkInvalidSignature', -1),
          s.get('opkFailedInitiation', -1),
          s.get('policySignatureInvalid', -1),
          'true' if d.get('truncated') else 'false')
except Exception:
    print('-1 -1 -1 -1 true')  # unparseable → fail every gate
")
EOF2

echo "    snapshots=$SNAPSHOTS  spkInvalidSignature=$ISIG  opkFailedInitiation=$OFAIL  policySignatureInvalid=$PSIG  truncated=$TRUNCATED"

# --- Gate 0: the aggregation must be COMPLETE. ------------------------------
# The worker caps the scan at SNAPSHOT_CAP snapshots (newest-day-first) and
# returns truncated:true. A truncated sum is a LOWER BOUND — real failures in
# the unscanned older buckets would read as 0. Never activate on a partial
# aggregate.
if [[ "$TRUNCATED" != "false" ]]; then
  echo "ABORT: the stats aggregation was truncated (>SNAPSHOT_CAP snapshots in" >&2
  echo "       $RANGE). The soak counters are a partial sum and could hide real" >&2
  echo "       failures in older buckets. Narrow --range or raise the worker cap." >&2
  exit 1
fi

# --- Gate 1: the soak must actually contain data. ---------------------------
# This is the guard against the "empty bucket looked clean" trap. MIN_SNAPSHOTS
# is validated above as a positive integer >= 100, so this comparison is safe.
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
  # Post-deploy verification must not look like a failed activation: the
  # secret is already set, so a transient verify error (or an edge-cached
  # stale body — the endpoint sets s-maxage=86400) is informational, not
  # fatal. Assert the live value == reject and report clearly either way.
  set +e
  LIVE=$(curl -fsS "$WORKER_URL/v2/config/crypto-policy" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);p=d.get('policy',d);print(p.get('spkExpirationBehavior',''))" 2>/dev/null)
  set -e
  if [[ "$LIVE" == "reject" ]]; then
    echo "    CONFIRMED live spkExpirationBehavior = reject"
    echo "Done. Strict C1 (reject) is active. Devices pick it up within their 1h cache window."
  else
    echo "    WARNING: live read shows spkExpirationBehavior = '${LIVE:-<unreadable>}', not 'reject'." >&2
    echo "    The secret was deployed, but Cloudflare's edge cache (s-maxage=86400)" >&2
    echo "    can serve the previous body for up to a day. Re-check shortly:" >&2
    echo "      curl -s $WORKER_URL/v2/config/crypto-policy | jq .policy.spkExpirationBehavior" >&2
  fi
else
  echo ""
  echo "DRY RUN — not deployed. To activate, run:"
  echo "  cd cloudflare-worker && cat strict-policy.signed.json | npx wrangler secret put CRYPTO_POLICY_JSON"
  echo "  # then verify: curl $WORKER_URL/v2/config/crypto-policy | jq .policy.spkExpirationBehavior"
  echo ""
  echo "Or re-run this script with --deploy."
fi
