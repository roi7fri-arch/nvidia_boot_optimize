#!/usr/bin/env bash
# test_boot_time.sh — Integration test: measure boot time and verify target met
# Usage: ./tests/test_boot_time.sh [--device /dev/ttyUSB0] [--timeout 30]

. "$(dirname "$0")/../scripts/common.sh"

DEVICE="$SERIAL_PORT"
TIMEOUT=30
OUTPUT_DIR="${REPO_ROOT}/specs/001-fast-boot-orin/measurements"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)  DEVICE="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--device PORT] [--timeout SECS]"
            exit 0
            ;;
        *) die "Unknown option: $1" "Run with --help" ;;
    esac
done

log_info "=== Boot Time Integration Test ==="
log_info "Target: ≤${TARGET_BOOT_MS}ms"
log_info "Device: $DEVICE"

# Run measurement
RESULT_FILE="${OUTPUT_DIR}/test-$(date '+%Y%m%d-%H%M%S').json"

"${SCRIPTS_DIR}/measure-boot-time.sh" \
    --device "$DEVICE" \
    --timeout "$TIMEOUT" \
    --output "$RESULT_FILE"

EXIT=$?

if [[ $EXIT -eq 0 ]]; then
    log_info "✓ TEST PASSED: Boot time within target (≤${TARGET_BOOT_MS}ms)"
elif [[ $EXIT -eq 1 ]]; then
    log_error "✗ TEST FAILED: Boot time exceeded target (>${TARGET_BOOT_MS}ms)"
    log_error "  See: $RESULT_FILE"
elif [[ $EXIT -eq 2 ]]; then
    log_error "✗ TEST FAILED: Device did not boot within timeout (${TIMEOUT}s)"
else
    log_error "✗ TEST FAILED: Serial port error (exit code: $EXIT)"
fi

exit $EXIT
