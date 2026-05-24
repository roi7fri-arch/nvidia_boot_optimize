#!/usr/bin/env bash
# measure-boot-time.sh — Measure boot time by monitoring serial output
# Monitors the serial port for shell prompt and reports timing in JSON.

. "$(dirname "$0")/common.sh"

# ─── Defaults ────────────────────────────────────────────────────────────────

DEVICE="$SERIAL_PORT"
BAUD="$SERIAL_BAUD"
TIMEOUT=30
PROMPT="$SHELL_PROMPT"
OUTPUT=""
VERBOSE=false

# ─── Usage ───────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Measure boot time by monitoring serial output for shell prompt.

Options:
  --device SERIAL_PORT   Host serial port (default: $SERIAL_PORT)
  --baud RATE            Baud rate (default: $SERIAL_BAUD)
  --timeout SECONDS      Max wait time before declaring failure (default: 30)
  --prompt STRING        String that indicates shell is ready (default: "$SHELL_PROMPT")
  --output FILE          Write measurement JSON to file (default: stdout)
  --verbose              Print all serial output to stderr
  -h, --help             Show this help

Exit codes:
  0 - Measurement completed, target met (≤${TARGET_BOOT_MS}ms)
  1 - Measurement completed, target NOT met
  2 - Timeout: device did not boot within --timeout
  3 - Serial port error
EOF
}

# ─── Parse Arguments ─────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)  DEVICE="$2"; shift 2 ;;
        --baud)    BAUD="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --prompt)  PROMPT="$2"; shift 2 ;;
        --output)  OUTPUT="$2"; shift 2 ;;
        --verbose) VERBOSE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" "Run with --help for usage" ;;
    esac
done

# ─── Validation ──────────────────────────────────────────────────────────────

check_serial_port "$DEVICE"
require_cmd stty

# ─── Configure Serial Port ───────────────────────────────────────────────────

stty -F "$DEVICE" "$BAUD" raw -echo -echoe -echok -echoctl -echoke 2>/dev/null \
    || die "Failed to configure serial port $DEVICE" "Check permissions and baud rate"

# ─── Monitor Serial Output ───────────────────────────────────────────────────

log_info "Monitoring $DEVICE at ${BAUD} baud..."
log_info "Waiting for prompt: '$PROMPT' (timeout: ${TIMEOUT}s)"
log_info "Power on the device now (or trigger reboot)."

START_MS=$(millis_now)
FIRST_CHAR_MS=""
KERNEL_START_MS=""
SHELL_READY_MS=""
FOUND=false

# Read serial with timeout
while IFS= read -r -t "$TIMEOUT" line || { FOUND=false; break; }; do
    NOW_MS=$(millis_now)

    # Record first character received (firmware alive)
    if [[ -z "$FIRST_CHAR_MS" ]] && [[ -n "$line" ]]; then
        FIRST_CHAR_MS="$NOW_MS"
        log_info "First output received at +$(( NOW_MS - START_MS ))ms"
    fi

    # Record kernel start marker
    if [[ -z "$KERNEL_START_MS" ]] && [[ "$line" == *"$KERNEL_START_MARKER"* ]]; then
        KERNEL_START_MS="$NOW_MS"
        log_info "Kernel start detected at +$(( NOW_MS - START_MS ))ms"
    fi

    # Print to stderr if verbose
    if [[ "$VERBOSE" == true ]]; then
        printf "%s\n" "$line" >&2
    fi

    # Check for shell prompt
    if [[ "$line" == *"$PROMPT"* ]]; then
        SHELL_READY_MS="$NOW_MS"
        FOUND=true
        log_info "Shell prompt detected at +$(( NOW_MS - START_MS ))ms"
        break
    fi
done < "$DEVICE"

# ─── Calculate Results ───────────────────────────────────────────────────────

if [[ "$FOUND" != true ]]; then
    log_error "Timeout: shell prompt not detected within ${TIMEOUT}s"
    exit 2
fi

TOTAL_MS=$(( SHELL_READY_MS - START_MS ))
FIRMWARE_START_MS=0
UEFI_START_MS=""
KERNEL_MS=""

# Compute stage times relative to start
if [[ -n "$FIRST_CHAR_MS" ]]; then
    FIRMWARE_START_MS=$(( FIRST_CHAR_MS - START_MS ))
fi
if [[ -n "$KERNEL_START_MS" ]]; then
    KERNEL_MS=$(( KERNEL_START_MS - START_MS ))
fi

# Determine pass/fail
if [[ "$TOTAL_MS" -le "$TARGET_BOOT_MS" ]]; then
    STATUS="PASS"
    EXIT_CODE=0
else
    STATUS="FAIL"
    EXIT_CODE=1
fi

# ─── Output JSON ─────────────────────────────────────────────────────────────

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

JSON=$(cat <<EOF
{
  "total_ms": ${TOTAL_MS},
  "stages": {
    "firmware_start_ms": ${FIRMWARE_START_MS},
    "kernel_start_ms": ${KERNEL_MS:-null},
    "shell_ready_ms": ${TOTAL_MS}
  },
  "target_ms": ${TARGET_BOOT_MS},
  "status": "${STATUS}",
  "device": "${DEVICE}",
  "baud": ${BAUD},
  "timestamp": "${TIMESTAMP}"
}
EOF
)

if [[ -n "$OUTPUT" ]]; then
    mkdir -p "$(dirname "$OUTPUT")"
    printf "%s\n" "$JSON" > "$OUTPUT"
    log_info "Measurement written to: $OUTPUT"
else
    printf "%s\n" "$JSON"
fi

log_info "Total boot time: ${TOTAL_MS}ms (target: ${TARGET_BOOT_MS}ms) — ${STATUS}"
exit "$EXIT_CODE"
