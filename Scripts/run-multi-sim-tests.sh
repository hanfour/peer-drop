#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# PeerDrop Multi-Simulator E2E Test Runner
# ═══════════════════════════════════════════════════════════════════════════
#
# USAGE:
#   ./Scripts/run-multi-sim-tests.sh setup       # Setup simulators and install app
#   ./Scripts/run-multi-sim-tests.sh run smoke   # Run smoke tests (core scenarios)
#   ./Scripts/run-multi-sim-tests.sh run full    # Run full test suite
#   ./Scripts/run-multi-sim-tests.sh run perf    # Run performance tests
#   ./Scripts/run-multi-sim-tests.sh single CONN-01  # Run a specific test
#   ./Scripts/run-multi-sim-tests.sh baseline    # Run perf tests and set baseline
#   ./Scripts/run-multi-sim-tests.sh compare     # Run perf tests and compare to baseline
#   ./Scripts/run-multi-sim-tests.sh clean       # Clean sync files and derived data
#
# ═══════════════════════════════════════════════════════════════════════════

set -e

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_FILE="$PROJECT_DIR/PeerDrop.xcodeproj"
SCHEME="PeerDrop"

# Simulator names (used for auto-detection)
SIM1_NAME="iPhone 17 Pro"
SIM2_NAME="iPhone 17 Pro Max"

# Auto-detect simulator UUIDs from names
get_simulator_uuid() {
    local name=$1
    # Get UUID for the first available simulator matching the name
    xcrun simctl list devices available -j | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    for d in devices:
        if d.get('name') == '$name' and d.get('isAvailable', False):
            print(d['udid'])
            sys.exit(0)
" 2>/dev/null
}

# Initialize UUIDs (will be set in init_simulators)
SIM1_UUID=""
SIM2_UUID=""

# Unique run ID for test isolation
RUN_ID=$(date +%s%3N)
export PEERDROP_TEST_RUN_ID="$RUN_ID"

# Build paths
DERIVED_DATA="$PROJECT_DIR/DerivedData-MultiSim"
XCTESTRUN_PATH=""

# Sync directory (shared via filesystem between simulators)
SYNC_DIR="/tmp/peerdrop-test-sync"

# Output directory for test results
OUTPUT_DIR="$PROJECT_DIR/TestResults/E2E"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ─────────────────────────────────────────────────────────────────────────────
# Helper Functions
# ─────────────────────────────────────────────────────────────────────────────

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

init_simulators() {
    if [ -z "$SIM1_UUID" ]; then
        SIM1_UUID=$(get_simulator_uuid "$SIM1_NAME")
        if [ -z "$SIM1_UUID" ]; then
            log_error "Could not find simulator: $SIM1_NAME"
            log_info "Available simulators:"
            xcrun simctl list devices available | grep "iPhone"
            exit 1
        fi
        log_info "Detected $SIM1_NAME: $SIM1_UUID"
    fi

    if [ -z "$SIM2_UUID" ]; then
        SIM2_UUID=$(get_simulator_uuid "$SIM2_NAME")
        if [ -z "$SIM2_UUID" ]; then
            log_error "Could not find simulator: $SIM2_NAME"
            exit 1
        fi
        log_info "Detected $SIM2_NAME: $SIM2_UUID"
    fi
}

check_simulator_exists() {
    local uuid=$1
    xcrun simctl list devices | grep -q "$uuid"
}

get_simulator_state() {
    local uuid=$1
    xcrun simctl list devices | grep "$uuid" | grep -oE '\(Booted\)|\(Shutdown\)' | tr -d '()'
}

wait_for_simulator_boot() {
    local uuid=$1
    local max_wait=60
    local waited=0

    while [ $waited -lt $max_wait ]; do
        if [ "$(get_simulator_state "$uuid")" = "Booted" ]; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Setup Command
# ─────────────────────────────────────────────────────────────────────────────

cmd_setup() {
    log_step "Setting up Multi-Simulator Test Environment"

    # Auto-detect simulator UUIDs
    log_info "Detecting simulators..."
    init_simulators
    log_success "Both simulators found"

    # Boot simulators in parallel
    log_info "Booting simulators..."
    local sim1_state=$(get_simulator_state "$SIM1_UUID")
    local sim2_state=$(get_simulator_state "$SIM2_UUID")

    if [ "$sim1_state" != "Booted" ]; then
        log_info "Booting $SIM1_NAME..."
        xcrun simctl boot "$SIM1_UUID" 2>/dev/null || true
    else
        log_info "$SIM1_NAME already booted"
    fi

    if [ "$sim2_state" != "Booted" ]; then
        log_info "Booting $SIM2_NAME..."
        xcrun simctl boot "$SIM2_UUID" 2>/dev/null || true
    else
        log_info "$SIM2_NAME already booted"
    fi

    # Wait for both to be ready
    log_info "Waiting for simulators to be ready..."
    if ! wait_for_simulator_boot "$SIM1_UUID"; then
        log_error "Timeout waiting for $SIM1_NAME to boot"
        exit 1
    fi
    if ! wait_for_simulator_boot "$SIM2_UUID"; then
        log_error "Timeout waiting for $SIM2_NAME to boot"
        exit 1
    fi
    log_success "Both simulators are booted"

    # Open Simulator app to show them
    log_info "Opening Simulator app..."
    open -a Simulator
    sleep 2

    # Create sync directory
    log_info "Creating sync directory: $SYNC_DIR"
    mkdir -p "$SYNC_DIR"
    chmod 777 "$SYNC_DIR"

    # Create output directory
    mkdir -p "$OUTPUT_DIR"

    # Build for testing
    log_step "Building Application for Testing"
    log_info "Building $SCHEME..."

    xcodebuild build-for-testing \
        -project "$PROJECT_FILE" \
        -scheme "$SCHEME" \
        -destination "platform=iOS Simulator,id=$SIM1_UUID" \
        -derivedDataPath "$DERIVED_DATA" \
        -quiet \
        2>&1 | while read line; do
            if [[ "$line" == *"error:"* ]]; then
                echo -e "${RED}$line${NC}"
            elif [[ "$line" == *"warning:"* ]]; then
                echo -e "${YELLOW}$line${NC}"
            fi
        done

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "Build failed"
        exit 1
    fi
    log_success "Build completed"

    # Find xctestrun file
    XCTESTRUN_PATH=$(find "$DERIVED_DATA" -name "*.xctestrun" -type f | head -1)
    if [ -z "$XCTESTRUN_PATH" ]; then
        log_error "Could not find .xctestrun file"
        exit 1
    fi
    log_info "Found xctestrun: $(basename "$XCTESTRUN_PATH")"

    # Save xctestrun path for later
    echo "$XCTESTRUN_PATH" > "$DERIVED_DATA/.xctestrun_path"

    log_success "Setup complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Run smoke tests:  ./Scripts/run-multi-sim-tests.sh run smoke"
    echo "  2. Run full suite:   ./Scripts/run-multi-sim-tests.sh run full"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Run Tests Command
# ─────────────────────────────────────────────────────────────────────────────

cmd_run() {
    local suite=${1:-smoke}

    log_step "Running E2E Tests: $suite"

    # Auto-detect simulator UUIDs
    init_simulators

    # Load xctestrun path
    if [ ! -f "$DERIVED_DATA/.xctestrun_path" ]; then
        log_error "No build found. Run 'setup' first."
        exit 1
    fi
    XCTESTRUN_PATH=$(cat "$DERIVED_DATA/.xctestrun_path")

    if [ ! -f "$XCTESTRUN_PATH" ]; then
        log_error "xctestrun file not found. Run 'setup' first."
        exit 1
    fi

    # Verify simulators are booted
    if [ "$(get_simulator_state "$SIM1_UUID")" != "Booted" ]; then
        log_error "$SIM1_NAME is not booted. Run 'setup' first."
        exit 1
    fi
    if [ "$(get_simulator_state "$SIM2_UUID")" != "Booted" ]; then
        log_error "$SIM2_NAME is not booted. Run 'setup' first."
        exit 1
    fi

    # Clean sync directory
    log_info "Cleaning sync directory..."
    rm -rf "$SYNC_DIR"/*
    mkdir -p "$SYNC_DIR"
    chmod 777 "$SYNC_DIR"

    # Write shared run ID to file for both simulators to read
    echo "$RUN_ID" > "$SYNC_DIR/run_id"
    chmod 644 "$SYNC_DIR/run_id"
    log_info "Shared Run ID: $RUN_ID"

    # Determine which tests to run
    local initiator_tests=""
    local acceptor_tests=""

    case $suite in
        smoke)
            initiator_tests="DISC_01,CONN_01,CHAT_01,FILE_01"
            acceptor_tests="DISC_01,CONN_01,CHAT_01,FILE_01"
            ;;
        full)
            initiator_tests="DISC_01,DISC_02,CONN_01,CONN_02,CONN_03,CHAT_01,CHAT_02,CHAT_03,FILE_01,FILE_02,LIB_01,UI_01,CALL_01,CALL_02,VOICE_01,VOICE_02,REACT_01,REPLY_01"
            acceptor_tests="DISC_01,DISC_02,CONN_01,CONN_02,CONN_03,CHAT_01,CHAT_02,CHAT_03,FILE_01,FILE_02,LIB_01,UI_01,CALL_01,CALL_02,VOICE_01,VOICE_02,REACT_01,REPLY_01"
            ;;
        perf)
            initiator_tests="PERF_01,PERF_02,PERF_03,PERF_04"
            acceptor_tests="PERF_01,PERF_02,PERF_03,PERF_04"
            ;;
        *)
            log_error "Unknown suite: $suite. Use 'smoke', 'full', or 'perf'."
            exit 1
            ;;
    esac

    # Create result directories
    local result_dir="$OUTPUT_DIR/$TIMESTAMP"
    mkdir -p "$result_dir/initiator" "$result_dir/acceptor"

    log_info "Results will be saved to: $result_dir"
    log_info "Test Run ID: $RUN_ID"

    # Write suite info to sync dir
    echo "$suite" > "$SYNC_DIR/test_suite"
    echo "$initiator_tests" > "$SYNC_DIR/initiator_tests"
    echo "$acceptor_tests" > "$SYNC_DIR/acceptor_tests"

    # Build -only-testing parameters for specific tests
    local initiator_only_testing=""
    local acceptor_only_testing=""

    IFS=',' read -ra INIT_TESTS <<< "$initiator_tests"
    for test_id in "${INIT_TESTS[@]}"; do
        initiator_only_testing="$initiator_only_testing -only-testing:PeerDropUITests/E2EInitiatorTests/test_$test_id"
    done

    IFS=',' read -ra ACPT_TESTS <<< "$acceptor_tests"
    for test_id in "${ACPT_TESTS[@]}"; do
        acceptor_only_testing="$acceptor_only_testing -only-testing:PeerDropUITests/E2EAcceptorTests/test_$test_id"
    done

    log_info "Initiator tests: ${INIT_TESTS[*]}"
    log_info "Acceptor tests: ${ACPT_TESTS[*]}"

    # Start Acceptor tests first (in background)
    log_info "Starting Acceptor ($SIM2_NAME)..."
    xcodebuild test-without-building \
        -xctestrun "$XCTESTRUN_PATH" \
        -destination "platform=iOS Simulator,id=$SIM2_UUID" \
        $acceptor_only_testing \
        -resultBundlePath "$result_dir/acceptor/Results.xcresult" \
        2>&1 | tee "$result_dir/acceptor/output.log" | sed 's/^/[ACCEPTOR] /' &
    local acceptor_pid=$!

    # Wait a moment for acceptor to start
    sleep 2

    # Start Initiator tests
    log_info "Starting Initiator ($SIM1_NAME)..."
    xcodebuild test-without-building \
        -xctestrun "$XCTESTRUN_PATH" \
        -destination "platform=iOS Simulator,id=$SIM1_UUID" \
        $initiator_only_testing \
        -resultBundlePath "$result_dir/initiator/Results.xcresult" \
        2>&1 | tee "$result_dir/initiator/output.log" | sed 's/^/[INITIATOR] /' &
    local initiator_pid=$!

    # Wait for both to complete
    log_info "Waiting for tests to complete..."
    local initiator_status=0
    local acceptor_status=0

    wait $initiator_pid || initiator_status=$?
    wait $acceptor_pid || acceptor_status=$?

    echo ""
    log_step "Test Results Summary"

    # Parse results
    local initiator_passed=0
    local initiator_failed=0
    local acceptor_passed=0
    local acceptor_failed=0

    if [ -f "$result_dir/initiator/output.log" ]; then
        initiator_passed=$(grep -c "Test Case.*passed" "$result_dir/initiator/output.log" 2>/dev/null || echo 0)
        initiator_failed=$(grep -c "Test Case.*failed" "$result_dir/initiator/output.log" 2>/dev/null || echo 0)
    fi

    if [ -f "$result_dir/acceptor/output.log" ]; then
        acceptor_passed=$(grep -c "Test Case.*passed" "$result_dir/acceptor/output.log" 2>/dev/null || echo 0)
        acceptor_failed=$(grep -c "Test Case.*failed" "$result_dir/acceptor/output.log" 2>/dev/null || echo 0)
    fi

    echo "┌─────────────────────────────────────────────────────────┐"
    echo "│  INITIATOR ($SIM1_NAME)                               │"
    echo "│    Passed: $initiator_passed                                           │"
    echo "│    Failed: $initiator_failed                                           │"
    echo "│    Status: $([ $initiator_status -eq 0 ] && echo "✅ SUCCESS" || echo "❌ FAILED ")                               │"
    echo "├─────────────────────────────────────────────────────────┤"
    echo "│  ACCEPTOR ($SIM2_NAME)                            │"
    echo "│    Passed: $acceptor_passed                                           │"
    echo "│    Failed: $acceptor_failed                                           │"
    echo "│    Status: $([ $acceptor_status -eq 0 ] && echo "✅ SUCCESS" || echo "❌ FAILED ")                               │"
    echo "└─────────────────────────────────────────────────────────┘"

    # Generate HTML report
    generate_html_report "$result_dir" "$suite"

    # Aggregate performance metrics if this is a perf suite
    if [ "$suite" = "perf" ]; then
        aggregate_performance_metrics "$result_dir"
    fi

    # Final status
    echo ""
    if [ $initiator_status -eq 0 ] && [ $acceptor_status -eq 0 ]; then
        log_success "All tests passed!"
        return 0
    else
        log_error "Some tests failed. Check results at: $result_dir"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Performance Metrics Aggregation
# ─────────────────────────────────────────────────────────────────────────────

aggregate_performance_metrics() {
    local result_dir=$1
    local metrics_file="$result_dir/metrics.json"

    log_info "Aggregating performance metrics..."

    # Find all metrics files from the sync directory
    local all_metrics=""
    local run_dirs=$(find "$SYNC_DIR/$RUN_ID" -type d -name "PERF*" 2>/dev/null)

    python3 << PYEOF
import json
import os
from datetime import datetime
from pathlib import Path

sync_dir = "$SYNC_DIR/$RUN_ID"
output_file = "$metrics_file"

all_metrics = {}

# Walk through all PERF test directories
for test_dir in Path(sync_dir).glob("PERF*"):
    for metrics_file in test_dir.glob("metrics-*.json"):
        try:
            with open(metrics_file) as f:
                data = json.load(f)
                for metric in data.get("metrics", []):
                    name = metric["name"]
                    value = metric["value"]
                    if name not in all_metrics:
                        all_metrics[name] = []
                    all_metrics[name].append(value)
        except Exception as e:
            print(f"Warning: Could not parse {metrics_file}: {e}")

# Calculate aggregated values
aggregated = []
for name, values in sorted(all_metrics.items()):
    if values:
        avg = sum(values) / len(values)
        aggregated.append({
            "name": name,
            "value": round(avg, 4),
            "unit": "seconds",
            "samples": len(values)
        })

# Write output
output = {
    "runId": "$RUN_ID",
    "timestamp": datetime.now().isoformat(),
    "metrics": aggregated
}

os.makedirs(os.path.dirname(output_file), exist_ok=True)
with open(output_file, 'w') as f:
    json.dump(output, f, indent=2)

print(f"Aggregated {len(aggregated)} metrics to {output_file}")

# Print summary
if aggregated:
    print("\n📊 Performance Metrics Summary:")
    print("┌────────────────────────────────┬──────────────┬──────────┐")
    print("│ Metric                         │ Value        │ Target   │")
    print("├────────────────────────────────┼──────────────┼──────────┤")

    targets = {
        "discovery-time": 5.0,
        "connection-time": 10.0,
        "message-rtt-avg": 10.0,  # Includes UI automation overhead
        "message-rtt-p95": 15.0,  # Includes UI automation overhead
    }

    for m in aggregated:
        name = m["name"][:30]
        value = m["value"]
        target = targets.get(m["name"], None)
        target_str = f"< {target}s" if target else "-"
        status = ""
        if target:
            status = "✅" if value < target else "❌"
        print(f"│ {name:<30} │ {value:>8.3f}s {status:<2} │ {target_str:<8} │")

    print("└────────────────────────────────┴──────────────┴──────────┘")
PYEOF

    if [ -f "$metrics_file" ]; then
        log_success "Metrics written to: $metrics_file"
    else
        log_warning "No metrics collected"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Baseline Command
# ─────────────────────────────────────────────────────────────────────────────

cmd_baseline() {
    log_step "Setting Performance Baseline"

    # Run perf tests first
    cmd_run "perf"
    local perf_status=$?

    if [ $perf_status -ne 0 ]; then
        log_error "Performance tests failed. Cannot set baseline."
        return 1
    fi

    # Find the latest metrics file
    local latest_result=$(ls -td "$OUTPUT_DIR"/*/ 2>/dev/null | head -1)
    local metrics_file="$latest_result/metrics.json"

    if [ ! -f "$metrics_file" ]; then
        log_error "No metrics file found at: $metrics_file"
        return 1
    fi

    # Copy to baseline
    local baseline_file="$OUTPUT_DIR/baseline.json"
    cp "$metrics_file" "$baseline_file"

    log_success "Baseline saved to: $baseline_file"

    # Show baseline values
    echo ""
    echo "Baseline values:"
    python3 << PYEOF
import json

with open("$baseline_file") as f:
    data = json.load(f)

for m in data.get("metrics", []):
    print(f"  {m['name']}: {m['value']:.4f}s")
PYEOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Compare Command
# ─────────────────────────────────────────────────────────────────────────────

cmd_compare() {
    log_step "Comparing Performance to Baseline"

    local baseline_file="$OUTPUT_DIR/baseline.json"

    if [ ! -f "$baseline_file" ]; then
        log_error "No baseline found. Run 'baseline' first."
        return 1
    fi

    # Run perf tests
    cmd_run "perf"
    local perf_status=$?

    if [ $perf_status -ne 0 ]; then
        log_error "Performance tests failed."
        return 1
    fi

    # Find the latest metrics file
    local latest_result=$(ls -td "$OUTPUT_DIR"/*/ 2>/dev/null | head -1)
    local metrics_file="$latest_result/metrics.json"

    if [ ! -f "$metrics_file" ]; then
        log_error "No metrics file found at: $metrics_file"
        return 1
    fi

    # Compare with baseline
    python3 << PYEOF
import json
import sys

with open("$baseline_file") as f:
    baseline = json.load(f)

with open("$metrics_file") as f:
    current = json.load(f)

baseline_metrics = {m["name"]: m["value"] for m in baseline.get("metrics", [])}
current_metrics = {m["name"]: m["value"] for m in current.get("metrics", [])}

THRESHOLD = 0.20  # 20% regression threshold

print("\n📊 Performance Comparison (vs Baseline):")
print("┌────────────────────────────────┬──────────────┬──────────────┬──────────┬────────┐")
print("│ Metric                         │ Baseline     │ Current      │ Delta    │ Status │")
print("├────────────────────────────────┼──────────────┼──────────────┼──────────┼────────┤")

regressions = []
for name in sorted(set(baseline_metrics.keys()) | set(current_metrics.keys())):
    base_val = baseline_metrics.get(name, 0)
    curr_val = current_metrics.get(name, 0)

    if base_val > 0:
        delta_pct = ((curr_val - base_val) / base_val) * 100
        delta_str = f"{delta_pct:+.1f}%"

        if delta_pct > THRESHOLD * 100:
            status = "❌ REGR"
            regressions.append(name)
        elif delta_pct < -THRESHOLD * 100:
            status = "🚀 IMPR"
        else:
            status = "✅ OK"
    else:
        delta_str = "N/A"
        status = "➖ NEW"

    print(f"│ {name[:30]:<30} │ {base_val:>10.3f}s │ {curr_val:>10.3f}s │ {delta_str:>8} │ {status:<6} │")

print("└────────────────────────────────┴──────────────┴──────────────┴──────────┴────────┘")

if regressions:
    print(f"\n⚠️  WARNING: {len(regressions)} metric(s) regressed beyond {THRESHOLD*100:.0f}% threshold!")
    for r in regressions:
        print(f"   - {r}")
    sys.exit(1)
else:
    print("\n✅ All metrics within acceptable range.")
    sys.exit(0)
PYEOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Single Test Command
# ─────────────────────────────────────────────────────────────────────────────

cmd_single() {
    local test_id=$1

    if [ -z "$test_id" ]; then
        echo "Usage: $0 single <test-id>"
        echo ""
        echo "Available test IDs:"
        echo "  DISC-01  - Mutual Discovery"
        echo "  DISC-02  - Online/Offline Discovery"
        echo "  CONN-01  - Full Connection Flow"
        echo "  CONN-02  - Reject and Retry"
        echo "  CONN-03  - Reconnection"
        echo "  CHAT-01  - Bidirectional Messages"
        echo "  CHAT-02  - Rapid Message Burst"
        echo "  CHAT-03  - Read Receipts"
        echo "  FILE-01  - File Picker UI"
        echo "  FILE-02  - Transfer Progress"
        echo "  PERF-01  - Discovery Performance"
        echo "  PERF-02  - Connection Performance"
        echo "  PERF-03  - Message RTT"
        echo "  PERF-04  - UI Responsiveness"
        exit 1
    fi

    log_step "Running Single Test: $test_id"

    # Auto-detect simulator UUIDs
    init_simulators

    # Convert test ID to test method name (e.g., DISC-01 -> test_DISC_01)
    local method_name="test_${test_id//-/_}"

    # Load xctestrun path
    if [ ! -f "$DERIVED_DATA/.xctestrun_path" ]; then
        log_error "No build found. Run 'setup' first."
        exit 1
    fi
    XCTESTRUN_PATH=$(cat "$DERIVED_DATA/.xctestrun_path")

    # Clean sync directory
    rm -rf "$SYNC_DIR"/*
    mkdir -p "$SYNC_DIR"
    chmod 777 "$SYNC_DIR"

    # Write shared run ID to file for both simulators to read
    echo "$RUN_ID" > "$SYNC_DIR/run_id"
    chmod 644 "$SYNC_DIR/run_id"

    # Write test info
    echo "single" > "$SYNC_DIR/test_suite"
    echo "$test_id" > "$SYNC_DIR/single_test"

    # Result directory
    local result_dir="$OUTPUT_DIR/single_${test_id}_$TIMESTAMP"
    mkdir -p "$result_dir/initiator" "$result_dir/acceptor"

    # Start both tests
    log_info "Starting Acceptor..."
    xcodebuild test-without-building \
        -xctestrun "$XCTESTRUN_PATH" \
        -destination "platform=iOS Simulator,id=$SIM2_UUID" \
        -only-testing:"PeerDropUITests/E2EAcceptorTests/$method_name" \
        -resultBundlePath "$result_dir/acceptor/Results.xcresult" \
        2>&1 | tee "$result_dir/acceptor/output.log" | sed 's/^/[ACCEPTOR] /' &
    local acceptor_pid=$!

    sleep 2

    log_info "Starting Initiator..."
    xcodebuild test-without-building \
        -xctestrun "$XCTESTRUN_PATH" \
        -destination "platform=iOS Simulator,id=$SIM1_UUID" \
        -only-testing:"PeerDropUITests/E2EInitiatorTests/$method_name" \
        -resultBundlePath "$result_dir/initiator/Results.xcresult" \
        2>&1 | tee "$result_dir/initiator/output.log" | sed 's/^/[INITIATOR] /' &
    local initiator_pid=$!

    # Wait for both
    wait $initiator_pid
    local init_status=$?
    wait $acceptor_pid
    local accept_status=$?

    echo ""
    if [ $init_status -eq 0 ] && [ $accept_status -eq 0 ]; then
        log_success "Test $test_id passed!"
    else
        log_error "Test $test_id failed. Check results at: $result_dir"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Clean Command
# ─────────────────────────────────────────────────────────────────────────────

cmd_clean() {
    log_step "Cleaning Test Artifacts"

    log_info "Removing sync directory..."
    rm -rf "$SYNC_DIR"

    log_info "Removing derived data..."
    rm -rf "$DERIVED_DATA"

    log_info "Removing old test results (keeping last 5)..."
    if [ -d "$OUTPUT_DIR" ]; then
        ls -t "$OUTPUT_DIR" | tail -n +6 | xargs -I {} rm -rf "$OUTPUT_DIR/{}"
    fi

    log_success "Clean complete"
}

# ─────────────────────────────────────────────────────────────────────────────
# HTML Report Generator
# ─────────────────────────────────────────────────────────────────────────────

generate_html_report() {
    local result_dir=$1
    local suite=$2
    local report_file="$result_dir/report.html"

    log_info "Generating HTML report..."

    cat > "$report_file" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PeerDrop E2E Test Report</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            color: #fff;
            min-height: 100vh;
            padding: 40px 20px;
        }
        .container { max-width: 1200px; margin: 0 auto; }
        h1 {
            text-align: center;
            font-size: 2.5rem;
            margin-bottom: 10px;
            background: linear-gradient(45deg, #667eea, #764ba2);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        .subtitle { text-align: center; color: #8b8b9e; margin-bottom: 40px; }
        .summary {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-bottom: 40px;
        }
        .card {
            background: rgba(255, 255, 255, 0.05);
            border-radius: 16px;
            padding: 24px;
            backdrop-filter: blur(10px);
            border: 1px solid rgba(255, 255, 255, 0.1);
        }
        .card h3 { color: #8b8b9e; font-size: 0.9rem; margin-bottom: 8px; }
        .card .value { font-size: 2.5rem; font-weight: bold; }
        .passed { color: #4ade80; }
        .failed { color: #f87171; }
        .device-section {
            background: rgba(255, 255, 255, 0.03);
            border-radius: 16px;
            padding: 24px;
            margin-bottom: 24px;
        }
        .device-header {
            display: flex;
            align-items: center;
            gap: 12px;
            margin-bottom: 20px;
        }
        .device-icon {
            width: 48px;
            height: 48px;
            background: linear-gradient(45deg, #667eea, #764ba2);
            border-radius: 12px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 24px;
        }
        .test-list { list-style: none; }
        .test-item {
            display: flex;
            align-items: center;
            gap: 12px;
            padding: 12px 16px;
            background: rgba(255, 255, 255, 0.02);
            border-radius: 8px;
            margin-bottom: 8px;
        }
        .test-status {
            width: 24px;
            height: 24px;
            border-radius: 50%;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 14px;
        }
        .status-pass { background: rgba(74, 222, 128, 0.2); color: #4ade80; }
        .status-fail { background: rgba(248, 113, 113, 0.2); color: #f87171; }
        .test-name { flex: 1; }
        .test-duration { color: #8b8b9e; font-size: 0.9rem; }
        .perf-section {
            background: rgba(255, 255, 255, 0.03);
            border-radius: 16px;
            padding: 24px;
            margin-bottom: 24px;
        }
        .perf-header {
            display: flex;
            align-items: center;
            gap: 12px;
            margin-bottom: 20px;
        }
        .perf-icon {
            width: 48px;
            height: 48px;
            background: linear-gradient(45deg, #f59e0b, #ef4444);
            border-radius: 12px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 24px;
        }
        .perf-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 16px;
        }
        .perf-metric {
            background: rgba(255, 255, 255, 0.02);
            border-radius: 12px;
            padding: 16px;
            border-left: 4px solid #667eea;
        }
        .perf-metric.good { border-left-color: #4ade80; }
        .perf-metric.bad { border-left-color: #f87171; }
        .perf-metric-name { color: #8b8b9e; font-size: 0.85rem; margin-bottom: 4px; }
        .perf-metric-value { font-size: 1.5rem; font-weight: bold; }
        .perf-metric-target { color: #8b8b9e; font-size: 0.8rem; margin-top: 4px; }
        footer {
            text-align: center;
            color: #8b8b9e;
            margin-top: 40px;
            font-size: 0.9rem;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔗 PeerDrop E2E Test Report</h1>
        <p class="subtitle">Multi-Simulator Integration Tests • TIMESTAMP_PLACEHOLDER</p>

        <div class="summary">
            <div class="card">
                <h3>SUITE</h3>
                <div class="value">SUITE_PLACEHOLDER</div>
            </div>
            <div class="card">
                <h3>TOTAL TESTS</h3>
                <div class="value">TOTAL_PLACEHOLDER</div>
            </div>
            <div class="card">
                <h3>PASSED</h3>
                <div class="value passed">PASSED_PLACEHOLDER</div>
            </div>
            <div class="card">
                <h3>FAILED</h3>
                <div class="value failed">FAILED_PLACEHOLDER</div>
            </div>
        </div>

        <div class="device-section">
            <div class="device-header">
                <div class="device-icon">📱</div>
                <div>
                    <h2>Initiator (iPhone 17 Pro)</h2>
                    <p style="color: #8b8b9e">Primary test driver</p>
                </div>
            </div>
            <ul class="test-list">
                INITIATOR_TESTS_PLACEHOLDER
            </ul>
        </div>

        <div class="device-section">
            <div class="device-header">
                <div class="device-icon">📱</div>
                <div>
                    <h2>Acceptor (iPhone 17 Pro Max)</h2>
                    <p style="color: #8b8b9e">Secondary test participant</p>
                </div>
            </div>
            <ul class="test-list">
                ACCEPTOR_TESTS_PLACEHOLDER
            </ul>
        </div>

        PERF_SECTION_PLACEHOLDER

        <footer>
            Generated by PeerDrop Multi-Simulator Test Runner
        </footer>
    </div>
</body>
</html>
HTMLEOF

    # Parse logs and replace placeholders
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local total=0
    local passed=0
    local failed=0

    # Parse initiator log
    local init_tests=""
    if [ -f "$result_dir/initiator/output.log" ]; then
        while IFS= read -r line; do
            if [[ "$line" == *"Test Case"*"passed"* ]]; then
                test_name=$(echo "$line" | grep -oE "test_[A-Z]+_[0-9]+" | head -1)
                init_tests="$init_tests<li class=\"test-item\"><span class=\"test-status status-pass\">✓</span><span class=\"test-name\">$test_name</span></li>"
                ((passed++))
                ((total++))
            elif [[ "$line" == *"Test Case"*"failed"* ]]; then
                test_name=$(echo "$line" | grep -oE "test_[A-Z]+_[0-9]+" | head -1)
                init_tests="$init_tests<li class=\"test-item\"><span class=\"test-status status-fail\">✗</span><span class=\"test-name\">$test_name</span></li>"
                ((failed++))
                ((total++))
            fi
        done < "$result_dir/initiator/output.log"
    fi

    # Parse acceptor log
    local accept_tests=""
    if [ -f "$result_dir/acceptor/output.log" ]; then
        while IFS= read -r line; do
            if [[ "$line" == *"Test Case"*"passed"* ]]; then
                test_name=$(echo "$line" | grep -oE "test_[A-Z]+_[0-9]+" | head -1)
                accept_tests="$accept_tests<li class=\"test-item\"><span class=\"test-status status-pass\">✓</span><span class=\"test-name\">$test_name</span></li>"
                ((passed++))
                ((total++))
            elif [[ "$line" == *"Test Case"*"failed"* ]]; then
                test_name=$(echo "$line" | grep -oE "test_[A-Z]+_[0-9]+" | head -1)
                accept_tests="$accept_tests<li class=\"test-item\"><span class=\"test-status status-fail\">✗</span><span class=\"test-name\">$test_name</span></li>"
                ((failed++))
                ((total++))
            fi
        done < "$result_dir/acceptor/output.log"
    fi

    # Generate performance section if metrics exist
    local perf_section=""
    local metrics_file="$result_dir/metrics.json"

    if [ -f "$metrics_file" ]; then
        perf_section=$(python3 << PYEOF
import json

with open("$metrics_file") as f:
    data = json.load(f)

metrics = data.get("metrics", [])
if not metrics:
    print("")
else:
    targets = {
        "discovery-time": 5.0,
        "connection-time": 10.0,
        "message-rtt-avg": 10.0,  # Includes UI automation overhead
        "message-rtt-p95": 15.0,  # Includes UI automation overhead
        "accept-time": 5.0,
        "tab-switch-avg": 3.0,
        "rapid-input-avg": 8.0,
    }

    html = '''
        <div class="perf-section">
            <div class="perf-header">
                <div class="perf-icon">⚡</div>
                <div>
                    <h2>Performance Metrics</h2>
                    <p style="color: #8b8b9e">Measured during test execution</p>
                </div>
            </div>
            <div class="perf-grid">
    '''

    for m in metrics:
        name = m["name"]
        value = m["value"]
        target = targets.get(name)

        if target:
            status_class = "good" if value < target else "bad"
            target_html = f'<div class="perf-metric-target">Target: &lt; {target}s</div>'
        else:
            status_class = ""
            target_html = ""

        html += f'''
                <div class="perf-metric {status_class}">
                    <div class="perf-metric-name">{name}</div>
                    <div class="perf-metric-value">{value:.3f}s</div>
                    {target_html}
                </div>
        '''

    html += '''
            </div>
        </div>
    '''

    print(html)
PYEOF
)
    fi

    # Replace placeholders
    sed -i '' "s|TIMESTAMP_PLACEHOLDER|$timestamp|g" "$report_file"
    sed -i '' "s|SUITE_PLACEHOLDER|$suite|g" "$report_file"
    sed -i '' "s|TOTAL_PLACEHOLDER|$total|g" "$report_file"
    sed -i '' "s|PASSED_PLACEHOLDER|$passed|g" "$report_file"
    sed -i '' "s|FAILED_PLACEHOLDER|$failed|g" "$report_file"
    sed -i '' "s|INITIATOR_TESTS_PLACEHOLDER|$init_tests|g" "$report_file"
    sed -i '' "s|ACCEPTOR_TESTS_PLACEHOLDER|$accept_tests|g" "$report_file"

    # Replace performance section (need to use temp file for multiline)
    if [ -n "$perf_section" ]; then
        # Write perf section to temp file
        echo "$perf_section" > "$result_dir/perf_section.tmp"
        # Use python to replace placeholder with multiline content
        python3 << PYEOF
with open("$result_dir/perf_section.tmp") as f:
    perf_html = f.read()

with open("$report_file") as f:
    content = f.read()

content = content.replace("PERF_SECTION_PLACEHOLDER", perf_html)

with open("$report_file", "w") as f:
    f.write(content)
PYEOF
        rm -f "$result_dir/perf_section.tmp"
    else
        sed -i '' "s|PERF_SECTION_PLACEHOLDER||g" "$report_file"
    fi

    log_success "Report generated: $report_file"

    # Open report in browser
    open "$report_file" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Status Command
# ─────────────────────────────────────────────────────────────────────────────

cmd_status() {
    log_step "System Status"

    # Auto-detect simulator UUIDs
    init_simulators

    echo "Simulators:"
    echo "  $SIM1_NAME ($SIM1_UUID): $(get_simulator_state "$SIM1_UUID")"
    echo "  $SIM2_NAME ($SIM2_UUID): $(get_simulator_state "$SIM2_UUID")"
    echo ""

    echo "Build:"
    if [ -f "$DERIVED_DATA/.xctestrun_path" ]; then
        echo "  ✅ Build available"
        echo "  $(cat "$DERIVED_DATA/.xctestrun_path")"
    else
        echo "  ❌ No build found (run 'setup' first)"
    fi
    echo ""

    echo "Sync Directory:"
    if [ -d "$SYNC_DIR" ]; then
        echo "  ✅ $SYNC_DIR"
        ls -la "$SYNC_DIR" 2>/dev/null | head -10
    else
        echo "  ❌ Not created"
    fi
    echo ""

    echo "Recent Results:"
    if [ -d "$OUTPUT_DIR" ]; then
        ls -lt "$OUTPUT_DIR" | head -6
    else
        echo "  No results yet"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main Entry Point
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    echo "PeerDrop Multi-Simulator E2E Test Runner"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  setup         Boot simulators and build app for testing"
    echo "  run <suite>   Run test suite (smoke|full|perf)"
    echo "  single <id>   Run a single test by ID (e.g., CONN-01)"
    echo "  baseline      Run performance tests and save as baseline"
    echo "  compare       Run performance tests and compare to baseline"
    echo "  status        Show system status"
    echo "  clean         Clean sync files and derived data"
    echo ""
    echo "Examples:"
    echo "  $0 setup                   # First-time setup"
    echo "  $0 run smoke               # Run smoke tests"
    echo "  $0 run full                # Run full suite"
    echo "  $0 run perf                # Run performance tests"
    echo "  $0 single CONN-01          # Run connection test"
    echo "  $0 baseline                # Set performance baseline"
    echo "  $0 compare                 # Compare to baseline"
    echo ""
}

case ${1:-} in
    setup)
        cmd_setup
        ;;
    run)
        cmd_run "${2:-smoke}"
        ;;
    single)
        cmd_single "${2:-}"
        ;;
    baseline)
        cmd_baseline
        ;;
    compare)
        cmd_compare
        ;;
    status)
        cmd_status
        ;;
    clean)
        cmd_clean
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
